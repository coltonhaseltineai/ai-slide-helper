// The commit policy that turns judge verdicts into highlight moves, plus the "when to ask" scheduler.
// JavaScript twin of mac/Sources/MatcherCore/Follower.swift and JudgeScheduler.swift — keep them in step.
'use strict';

const POLICY = {
  live: { mediumAgreeWithin: 6, voteWindow: 10, keywordVetoWithin: 5, allowKeywordMoves: true, highOnly: false },
  // Before on-device following: only a high-confidence answer moved the highlight.
  statusQuo: { mediumAgreeWithin: 0, voteWindow: 0, keywordVetoWithin: 0, allowKeywordMoves: true, highOnly: true },
};

const CADENCE = {
  onDevice: { minNewWords: 5, pauseWords: 2, pauseAfter: 0.8, minGap: 1.0, timeout: 2.5 },
  claude: { minNewWords: 5, pauseWords: 2, pauseAfter: 0.8, minGap: 2.0, timeout: 4.0 },
};

const RANK = { low: 0, medium: 1, high: 2 };

class Follower {
  constructor(count, policy = POLICY.live, current = 0) {
    this.count = count; this.policy = policy; this.current = current;
    this.lastSeq = {}; this.lastManualAt = -Infinity; this.lastHoldAt = -Infinity; this.votes = [];
  }

  manual(point, at) {
    this.current = point; this.lastManualAt = at; this.votes = [];
    return { moved: true };
  }

  // The keyword matcher proposes a point. Returns true if the highlight moved.
  keyword(point, at) {
    if (point === this.current) return false;
    if (!this.policy.allowKeywordMoves) return false;
    if (at - this.lastHoldAt < this.policy.keywordVetoWithin) return false;
    this.current = point; this.votes = [];
    return true;
  }

  // v: {state, point, confidence}. Returns {moved, from, to} or {moved:false, reason}.
  // `source` separates sequence numbers of different verdict streams (e.g. tiny model vs judge).
  verdict(v, { seq, askedAt, askedCurrent, at, localSupport = false, source = 'judge' }) {
    if (seq <= (this.lastSeq[source] ?? -1)) return { moved: false, reason: 'stale' };
    this.lastSeq[source] = seq;
    if (askedAt < this.lastManualAt) return { moved: false, reason: 'manual' };
    if (askedCurrent !== this.current) return { moved: false, reason: 'outdated' };
    if (!(Number.isInteger(v.point) && v.point >= 0 && v.point < this.count)) return { moved: false, reason: 'invalid' };
    const p = this.policy;
    if (v.state !== 'moved' || v.point === this.current) {
      if (v.state === 'same' || v.state === 'tangent' || v.point === this.current) { this.lastHoldAt = at; this.votes = []; }
      return { moved: false, reason: v.state === 'moved' ? 'same' : v.state };
    }
    if (p.highOnly) {
      if (v.confidence !== 'high') return { moved: false, reason: 'low' };
      return this._move(v.point);
    }
    this.votes = this.votes.filter(x => at - x.at <= p.voteWindow);
    const agreeing = this.votes.filter(x => x.point === v.point && RANK[x.confidence] >= RANK.medium);
    this.votes.push({ point: v.point, confidence: v.confidence, at });
    if (v.confidence === 'low') return { moved: false, reason: 'low' };
    const d = v.point - this.current;
    if (d === 1) {
      if (v.confidence === 'high') return this._move(v.point);
      const recent = agreeing.some(x => at - x.at <= p.mediumAgreeWithin);
      return recent || localSupport ? this._move(v.point) : { moved: false, reason: 'needs-agreement' };
    }
    // Going back or skipping ahead needs two votes.
    return agreeing.length >= 1 ? this._move(v.point) : { moved: false, reason: 'needs-second-vote' };
  }

  _move(point) {
    const from = this.current;
    this.current = point; this.votes = [];
    return { moved: true, from, to: point };
  }
}

function shouldJudge({ now, lastAskAt, lastWordAt, newWords, inFlight }, c) {
  if (inFlight) return false;
  if (now - lastAskAt < c.minGap) return false;
  if (newWords >= c.minNewWords) return true;
  return newWords >= c.pauseWords && now - lastWordAt >= c.pauseAfter;
}

// The old "smart following" trigger (kept as the status-quo baseline).
function shouldLocateOld({ now, lastCallAt, lastConfidentAt, newWords, inFlight }) {
  if (inFlight || newWords < 8) return false;
  if (now - lastCallAt < 3) return false;
  return now - lastConfidentAt >= 6 || now - lastCallAt >= 10;
}

module.exports = { POLICY, CADENCE, Follower, shouldJudge, shouldLocateOld };
