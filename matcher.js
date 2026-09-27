// Outline matcher: figures out which outline item a speaker is currently on.
(function (root) {
  const STOP = new Set(('a an the and or but if then so of to in on at by for with from as is are was were be been ' +
    'it its this that these those i you he she we they me my our your their them us do does did have has had ' +
    'not no yes just about into over out up down very really can will would should could what which who how ' +
    'when where why all any some more most other such than too also there here now um uh like okay ok well right').split(' '));

  function stem(w) {
    if (w.length > 5 && w.endsWith('ing')) return w.slice(0, -3);
    if (w.length > 4 && w.endsWith('ed')) return w.slice(0, -2);
    if (w.length > 4 && w.endsWith('ies')) return w.slice(0, -3) + 'y';
    if (w.length > 3 && w.endsWith('s') && !w.endsWith('ss')) return w.slice(0, -1);
    return w;
  }

  function tokenize(text) {
    return (text || '').toLowerCase().replace(/[^a-z0-9\s']/g, ' ').replace(/'/g, '')
      .split(/\s+/).filter(w => w && !STOP.has(w)).map(stem);
  }

  // Parse indented text. Lines may include "[cues: a, b]".
  function parseOutline(text) {
    const items = [];
    for (const raw of (text || '').split('\n')) {
      if (!raw.trim()) continue;
      const indent = raw.match(/^\s*/)[0].replace(/\t/g, '  ').length;
      let line = raw.trim().replace(/^([-*•]|\d+[.)])\s+/, '');
      let cues = '';
      line = line.replace(/\[cues?:([^\]]*)\]/i, (_, c) => { cues = c; return ''; }).trim();
      items.push({ text: line, cues: cues.split(',').map(s => s.trim()).filter(Boolean), indent });
    }
    const levels = [...new Set(items.map(i => i.indent))].sort((a, b) => a - b);
    items.forEach(i => { i.level = levels.indexOf(i.indent); delete i.indent; });
    return items;
  }

  class Matcher {
    constructor(items, opts = {}) {
      this.opts = Object.assign({ window: 25, margin: 0.15, confirm: 2 }, opts);
      this.items = items.map(it => {
        const kws = new Set([...tokenize(it.text), ...it.cues.flatMap(tokenize)]);
        return Object.assign({}, it, { keywords: kws });
      });
      this.learned = this.items.map(() => new Set());
      this.df = new Map();
      this.items.forEach(it => it.keywords.forEach(k => this.df.set(k, (this.df.get(k) || 0) + 1)));
      const n = this.items.length || 1;
      this.idf = k => Math.log(1 + n / (this.df.get(k) || 1));
      this.current = this.items.length ? 0 : -1;
      this.words = [];
      this.pending = null;
      this.pendingCount = 0;
    }

    // Adds hint words ('hint') or words the speaker was heard using ('learned') to one item.
    addKeywords(i, words, source = 'hint') {
      const it = this.items[i];
      if (!it) return 0;
      let added = 0;
      for (const k of tokenize((words || []).join(' '))) {
        if (source === 'learned') this.learned[i].add(k);
        if (it.keywords.has(k)) continue;
        it.keywords.add(k);
        this.df.set(k, (this.df.get(k) || 0) + 1);
        added++;
      }
      return added;
    }

    // How many words in `text` belong to item i (e.g. "is the newest speech still about this point?").
    hits(i, text) {
      const it = this.items[i];
      return it ? tokenize(text).filter(w => it.keywords.has(w)).length : 0;
    }

    setCurrent(i) { this.current = i; this.pending = null; this.pendingCount = 0; this.words = []; }

    score(i) {
      const it = this.items[i];
      if (!it.keywords.size) return 0;
      // Each keyword counts once, weighted by how recently it was said (older words fade).
      const best = new Map(); const n = this.words.length;
      this.words.forEach((w, idx) => {
        if (it.keywords.has(w)) best.set(w, Math.pow(0.85, n - 1 - idx));
      });
      let s = 0;
      best.forEach((wt, w) => { s += this.idf(w) * wt * (this.learned[i].has(w) ? 1.25 : 1); });
      // Hint lists can be long, so dampen length less than plain line text would.
      s /= Math.pow(it.keywords.size, 0.35);
      const d = i - this.current;
      if (d === 0 || d === 1) s *= 1.3;
      else if (d < 0) s *= 0.6;
      else s *= Math.max(0.4, 1 - 0.1 * (d - 1));
      return s;
    }

    // Feed newly finalized words; returns current index.
    feed(text) {
      this.words.push(...tokenize(text));
      if (this.words.length > this.opts.window) this.words = this.words.slice(-this.opts.window);
      if (!this.items.length) return -1;
      let best = this.current, bestScore = -1;
      for (let i = 0; i < this.items.length; i++) {
        const s = this.score(i);
        if (s > bestScore) { bestScore = s; best = i; }
      }
      const cur = this.score(this.current);
      if (best !== this.current && bestScore > 0 && bestScore > cur * (1 + this.opts.margin) + 0.05) {
        if (this.pending === best) this.pendingCount++; else { this.pending = best; this.pendingCount = 1; }
        if (this.pendingCount >= this.opts.confirm) this.setCurrent(best);
      } else { this.pending = null; this.pendingCount = 0; }
      return this.current;
    }
  }

  // Speech results grow word by word. This hands out only the new, settled words
  // in small groups so the highlight can react mid-sentence.
  class WordFeeder {
    constructor(minWords = 3) { this.minWords = minWords; this.fed = new Map(); }
    reset() { this.fed.clear(); }
    // key identifies one recognition result; text is its full transcript so far.
    update(key, text, isFinal) {
      const words = (text || '').trim().split(/\s+/).filter(Boolean);
      let done = this.fed.get(key) || 0;
      if (words.length < done) done = 0; // the recognizer rewrote this result
      const settled = isFinal ? words.length : Math.max(words.length - 1, 0);
      let chunk = '';
      if (settled - done >= this.minWords || (isFinal && settled > done)) {
        chunk = words.slice(done, settled).join(' ');
        done = settled;
      }
      if (isFinal) this.fed.delete(key); else this.fed.set(key, done);
      return chunk;
    }
  }

  // Remembers hint words and learned words per outline line, across talks.
  class LearnedLibrary {
    constructor(storage, key = 'liveOutline.library', cap = 60) {
      this.storage = storage; this.key = key; this.cap = cap;
      let data = null;
      try { data = JSON.parse(storage && storage.getItem(key)); } catch (e) {}
      this.data = data && typeof data === 'object' ? data : {};
    }
    static lineKey(text) { return tokenize(text).join(' ') || String(text).toLowerCase().trim(); }
    entry(text) {
      const k = LearnedLibrary.lineKey(text);
      return this.data[k] || (this.data[k] = { hints: [], learned: {} });
    }
    has(text) { const e = this.data[LearnedLibrary.lineKey(text)]; return !!(e && e.hints.length); }
    words(text) {
      const e = this.data[LearnedLibrary.lineKey(text)];
      return e ? { hints: e.hints.slice(), learned: Object.keys(e.learned) } : { hints: [], learned: [] };
    }
    setHints(text, words) { this.entry(text).hints = [...new Set(words)].slice(0, 40); }
    // Returns how many words were new.
    addLearned(text, words, now = Date.now()) {
      const e = this.entry(text);
      let added = 0;
      for (const w of words) {
        const k = String(w).toLowerCase().trim();
        if (!k) continue;
        if (!(k in e.learned)) added++;
        e.learned[k] = now;
      }
      const keys = Object.keys(e.learned);
      if (keys.length > this.cap) {
        keys.sort((a, b) => e.learned[b] - e.learned[a]).slice(this.cap).forEach(k => delete e.learned[k]);
      }
      return added;
    }
    learnedCount() { return Object.values(this.data).reduce((n, e) => n + Object.keys(e.learned).length, 0); }
    reset() { this.data = {}; this.save(); }
    save() { try { this.storage && this.storage.setItem(this.key, JSON.stringify(this.data)); } catch (e) {} }
  }

  // Decides when to ask Claude where the speaker is: only when the local matcher seems unsure,
  // plus an occasional check, and never while a request is already running.
  function shouldLocate(s, o = {}) {
    const unsureAfter = o.unsureAfter || 6000, every = o.every || 10000, minGap = o.minGap || 3000, minWords = o.minWords || 8;
    if (s.inFlight || s.newWords < minWords) return false;
    if (s.now - s.lastCallAt < minGap) return false;
    return s.now - s.lastConfidentAt >= unsureAfter || s.now - s.lastCallAt >= every;
  }

  const api = { tokenize, parseOutline, Matcher, WordFeeder, LearnedLibrary, shouldLocate };
  if (typeof module !== 'undefined' && module.exports) module.exports = api; else root.OutlineMatcher = api;
})(this);
