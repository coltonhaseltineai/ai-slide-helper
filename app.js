(() => {
  const { parseOutline, Matcher, WordFeeder, LearnedLibrary, shouldLocate } = window.OutlineMatcher;
  const $ = id => document.getElementById(id);
  const SAMPLE = `Welcome and introductions
Why sleep matters
  Memory consolidation [cues: remember, learning]
  Immune health
Tips for better sleep
  Keep a consistent schedule
  Avoid screens before bed
Questions`;

  const store = {
    get(k) { try { return localStorage.getItem(k); } catch (e) { return null; } },
    set(k, v) { try { localStorage.setItem(k, v); } catch (e) {} },
  };

  let matcher = null;
  let listening = false;
  let recognition = null;
  let restartTimer = null;
  let transcript = '';
  let wakeLock = null;
  const feeder = new WordFeeder(3);

  // ---------- Smart following (Claude) ----------
  let localStore = null;
  try { localStore = window.localStorage; } catch (e) {}
  const library = new LearnedLibrary(localStore);
  const RECENT_MS = 25000;        // how much recent speech Claude sees
  const ai = { enabled: store.get('aiEnabled') !== '0', disabledReason: '', inFlight: null,
    lastCallAt: 0, lastConfidentAt: 0, newWords: 0, lastTeachAt: 0 };
  let chunks = [];                // [{ t, text }] recent transcript pieces
  let aiTimer = null;
  let teachTimer = null;

  $('outlineInput').value = store.get('outline') || SAMPLE;

  // ---------- Edit ----------
  function renderPreview() {
    const ul = $('preview');
    ul.innerHTML = '';
    for (const it of parseOutline($('outlineInput').value)) {
      const li = document.createElement('li');
      li.className = it.level === 0 ? 'top' : '';
      li.style.paddingLeft = (it.level * 20) + 'px';
      li.append(it.text);
      if (it.cues.length) {
        const cue = document.createElement('span');
        cue.className = 'cue';
        cue.textContent = it.cues.join(' · ');
        li.append(cue);
      }
      ul.append(li);
    }
  }
  $('outlineInput').addEventListener('input', () => {
    store.set('outline', $('outlineInput').value);
    renderPreview();
  });

  // ---------- Present ----------
  function renderOutline() {
    const ol = $('outline');
    ol.innerHTML = '';
    matcher.items.forEach((it, i) => {
      const li = document.createElement('li');
      li.textContent = it.text;
      li.className = it.level === 0 ? 'top' : 'sub';
      li.style.paddingLeft = (16 + it.level * 28) + 'px';
      li.addEventListener('click', () => select(i));
      ol.append(li);
    });
    highlight(false);
  }

  function highlight(scroll = true) {
    const lis = [...$('outline').children];
    lis.forEach((li, i) => {
      li.classList.toggle('active', i === matcher.current);
      li.classList.toggle('past', i < matcher.current);
    });
    const active = lis[matcher.current];
    const hl = $('highlight');
    if (active) {
      hl.style.transform = `translateY(${active.offsetTop}px)`;
      hl.style.height = active.offsetHeight + 'px';
      if (scroll) active.scrollIntoView({ block: 'center', behavior: 'smooth' });
    }
    const n = matcher.items.length;
    $('progressFill').style.width = n ? ((matcher.current + 1) / n * 100) + '%' : '0';
    $('progressText').textContent = n ? `${matcher.current + 1} of ${n}` : 'Your outline is empty';
  }

  // Moves the highlight by hand; Claude learns from the correction.
  function select(i) {
    if (!matcher || !matcher.items.length) return;
    const target = Math.max(0, Math.min(i, matcher.items.length - 1));
    if (target === matcher.current) return;
    matcher.setCurrent(target);
    highlight();
    ai.lastConfidentAt = Date.now();
    teachSoon();
  }

  function setMode(present) {
    $('edit').hidden = present;
    $('present').hidden = !present;
    $('dock').hidden = !present;
    $('tabEdit').setAttribute('aria-selected', String(!present));
    $('tabPresent').setAttribute('aria-selected', String(present));
    if (present) {
      $('outlineInput').blur();
      matcher = new Matcher(parseOutline($('outlineInput').value));
      chunks = [];
      Object.assign(ai, { lastCallAt: Date.now(), lastConfidentAt: Date.now(), newWords: 0 });
      if (ai.inFlight) ai.inFlight.abort();
      renderOutline();
      loadLibrary();
      window.scrollTo({ top: 0 });
      keepAwake(true);
    } else {
      if (listening) toggleMic();
      keepAwake(false);
      renderPreview();
    }
  }

  // Hook for tests and other transcript sources.
  window.feedTranscript = text => {
    if (!matcher || !text) return;
    transcript = (transcript + ' ' + text).trim().slice(-300);
    showTicker(transcript);
    const now = Date.now();
    chunks.push({ t: now, text });
    chunks = chunks.filter(c => now - c.t < 60000);
    ai.newWords += text.split(/\s+/).length;
    const before = matcher.current;
    matcher.feed(text);
    if (matcher.current !== before) highlight();
    if (matcher.current !== before || matcher.hits(matcher.current, text) > 0) ai.lastConfidentAt = now;
    maybeLocate();
  };

  function recentTranscript(ms = RECENT_MS) {
    const now = Date.now();
    return chunks.filter(c => now - c.t < ms).map(c => c.text).join(' ');
  }

  async function api(path, body, signal) {
    const res = await fetch(path, {
      method: 'POST', signal,
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ ...body, code: store.get('accessCode') || '' }),
    });
    const data = await res.json().catch(() => ({}));
    if (!res.ok) {
      const err = new Error(data.error || `Request failed (${res.status})`);
      err.status = res.status;
      throw err;
    }
    return data;
  }

  // Stop calling Claude for this session after a setup problem, and say why once.
  function aiFailed(err) {
    if (err.name === 'AbortError') return;
    if (err.status === 401 || err.status === 400 || err.status === 404 || err.status === 500) {
      ai.disabledReason = err.status === 404 ? 'Smart following isn\'t available on this copy of the app.' : err.message;
      showNotice('Smart following is off: ' + ai.disabledReason + ' You can change this in ⚙︎ Settings.');
    }
  }
  const aiOn = () => ai.enabled && !ai.disabledReason && navigator.onLine !== false;

  // Put saved hint and learned words onto the outline, then fetch hints for any new lines.
  async function loadLibrary() {
    const items = matcher.items;
    items.forEach((it, i) => {
      const w = library.words(it.text);
      matcher.addKeywords(i, w.hints, 'hint');
      matcher.addKeywords(i, w.learned, 'learned');
    });
    updateBrain();
    if (!aiOn() || items.every(it => library.has(it.text))) return;
    const m = matcher;
    try {
      const { hints } = await api('/api/expand', { items: items.map(it => it.text) });
      hints.forEach((words, i) => {
        if (!words.length || library.has(items[i].text)) return;
        library.setHints(items[i].text, words);
        m.addKeywords(i, words, 'hint');
      });
      library.save();
    } catch (err) { aiFailed(err); }
  }

  function learn(index, words) {
    if (!words || !words.length || !matcher.items[index]) return;
    matcher.addKeywords(index, words, 'learned');
    if (library.addLearned(matcher.items[index].text, words)) {
      library.save();
      updateBrain(true);
    }
  }

  function updateBrain(pulse) {
    const n = library.learnedCount();
    const el = $('brain');
    el.hidden = n === 0;
    el.textContent = `🧠 ${n} learned`;
    if (pulse) { el.classList.remove('pulse'); void el.offsetWidth; el.classList.add('pulse'); }
  }

  async function maybeLocate() {
    if (!matcher || !aiOn() || $('present').hidden) return;
    const now = Date.now();
    if (!shouldLocate({ now, lastCallAt: ai.lastCallAt, lastConfidentAt: ai.lastConfidentAt,
      newWords: ai.newWords, inFlight: !!ai.inFlight })) return;
    const transcript = recentTranscript();
    if (!transcript) return;
    ai.lastCallAt = now;
    ai.newWords = 0;
    const m = matcher, asked = matcher.current;
    const ctrl = new AbortController();
    ai.inFlight = ctrl;
    try {
      const r = await api('/api/locate', { items: m.items.map(it => it.text), current: asked, transcript }, ctrl.signal);
      if (m !== matcher) return; // outline changed while waiting
      // Don't override a correction the user made while Claude was thinking.
      if (r.confidence === 'high' && r.index !== m.current && m.current === asked) {
        m.setCurrent(r.index);
        highlight();
      }
      if (r.confidence === 'high' || (r.confidence === 'medium' && r.index === m.current)) {
        learn(r.index, r.learned);
        ai.lastConfidentAt = Date.now();
      }
    } catch (err) { aiFailed(err); }
    finally { if (ai.inFlight === ctrl) ai.inFlight = null; }
  }

  // When the user corrects the highlight, teach the words they just said for that point.
  // Waits for taps to settle so several quick taps teach only the final point.
  function teachSoon() {
    clearTimeout(teachTimer);
    teachTimer = setTimeout(() => teach(matcher.current), 1500);
  }

  async function teach(index) {
    if (!aiOn() || Date.now() - ai.lastTeachAt < 4000) return;
    const transcript = recentTranscript(15000);
    if (transcript.split(/\s+/).length < 6) return;
    ai.lastTeachAt = Date.now();
    const m = matcher;
    try {
      const r = await api('/api/locate', { items: m.items.map(it => it.text), current: index, known: index, transcript });
      if (m === matcher) learn(index, r.learned);
    } catch (err) { aiFailed(err); }
  }

  function showTicker(text) {
    const bdi = document.createElement('bdi');
    bdi.textContent = text || (listening ? 'Listening…' : 'Tap Listen, or swipe to move between points');
    $('ticker').replaceChildren(bdi);
  }

  // ---------- Speech ----------
  const SR = window.SpeechRecognition || window.webkitSpeechRecognition;
  const standalone = window.navigator.standalone === true || matchMedia('(display-mode: standalone)').matches;

  if (SR) {
    recognition = new SR();
    recognition.continuous = true;
    recognition.interimResults = true;
    recognition.lang = navigator.language || 'en-US';
    recognition.onresult = e => {
      let interim = '';
      for (let i = e.resultIndex; i < e.results.length; i++) {
        const r = e.results[i];
        const text = r[0].transcript;
        const chunk = feeder.update(i, text, r.isFinal);
        if (chunk) window.feedTranscript(chunk);
        if (!r.isFinal) interim = text;
      }
      if (interim) showTicker((transcript + ' ' + interim).slice(-300));
    };
    // Safari and Chrome stop after pauses; quietly start again while the user wants to listen.
    recognition.onend = () => {
      feeder.reset();
      if (!listening) return;
      clearTimeout(restartTimer);
      restartTimer = setTimeout(() => { if (listening) try { recognition.start(); } catch (e) {} }, 250);
    };
    recognition.onerror = e => {
      if (e.error === 'not-allowed' || e.error === 'service-not-allowed') {
        listening = false;
        updateMic();
        showNotice(standalone
          ? 'Listening isn\'t allowed in the home-screen app on this iPhone. Open Live Outline in Safari to use your voice. Swipes and taps still work here.'
          : 'Microphone access was blocked. Allow it in your browser settings (on iPhone: Settings → Apps → Safari → Microphone) and try again.');
      }
    };
  }

  function showNotice(msg) {
    $('notice').textContent = msg;
    $('notice').hidden = false;
  }

  function updateMic() {
    $('micBtn').classList.toggle('live', listening);
    $('micLabel').textContent = listening ? 'Stop' : 'Listen';
    $('micBtn').setAttribute('aria-label', listening ? 'Stop listening' : 'Start listening');
    if (!transcript) showTicker('');
  }

  function toggleMic() {
    if (!recognition) {
      showNotice(standalone
        ? 'Voice following isn\'t available in the home-screen app on this iPhone. Open this page in Safari to use it. Swipes and taps still work here.'
        : 'Voice following needs Safari on iPhone, or Chrome or Edge on a computer. Swipes, taps and arrow keys still work.');
      return;
    }
    listening = !listening;
    clearTimeout(restartTimer);
    clearInterval(aiTimer);
    if (listening) {
      feeder.reset();
      try { recognition.start(); } catch (e) {}
      aiTimer = setInterval(maybeLocate, 2000); // "unsure for a while" can happen between words
    } else {
      recognition.stop();
    }
    updateMic();
  }

  // ---------- Keep the screen on ----------
  async function keepAwake(on) {
    try {
      if (on && 'wakeLock' in navigator && !wakeLock) {
        wakeLock = await navigator.wakeLock.request('screen');
        wakeLock.addEventListener('release', () => { wakeLock = null; });
      } else if (!on && wakeLock) {
        await wakeLock.release();
        wakeLock = null;
      }
    } catch (e) {}
  }
  document.addEventListener('visibilitychange', () => {
    if (document.visibilityState === 'visible' && !$('present').hidden) keepAwake(true);
  });

  // ---------- Gestures and keys ----------
  let touch = null;
  $('present').addEventListener('touchstart', e => {
    const t = e.touches[0];
    touch = { x: t.clientX, y: t.clientY };
  }, { passive: true });
  $('present').addEventListener('touchend', e => {
    if (!touch) return;
    const t = e.changedTouches[0];
    const dx = t.clientX - touch.x, dy = t.clientY - touch.y;
    touch = null;
    if (Math.abs(dx) > 60 && Math.abs(dx) > Math.abs(dy) * 1.5) select(matcher.current + (dx < 0 ? 1 : -1));
  }, { passive: true });

  document.addEventListener('keydown', e => {
    if ($('present').hidden || !matcher) return;
    if (e.key === 'ArrowRight' || e.key === 'ArrowDown') select(matcher.current + 1);
    else if (e.key === 'ArrowLeft' || e.key === 'ArrowUp') select(matcher.current - 1);
    else if (e.key === ' ') toggleMic();
    else return;
    e.preventDefault();
  });

  $('tabEdit').onclick = () => setMode(false);
  $('tabPresent').onclick = () => setMode(true);
  $('presentBtn').onclick = () => setMode(true);
  $('micBtn').onclick = toggleMic;
  $('prevBtn').onclick = () => select(matcher.current - 1);
  $('nextBtn').onclick = () => select(matcher.current + 1);
  window.addEventListener('resize', () => { if (matcher && !$('present').hidden) highlight(false); });

  // ---------- Settings ----------
  function renderSettings() {
    $('aiToggle').checked = ai.enabled;
    $('codeInput').value = store.get('accessCode') || '';
    const n = library.learnedCount();
    $('libStats').textContent = n ? `Learned so far: ${n} words across your outlines.` : 'Nothing learned yet.';
  }
  $('settingsBtn').onclick = () => { renderSettings(); $('settings').showModal(); };
  $('aiToggle').onchange = () => { ai.enabled = $('aiToggle').checked; store.set('aiEnabled', ai.enabled ? '1' : '0'); ai.disabledReason = ''; };
  $('codeInput').onchange = () => { store.set('accessCode', $('codeInput').value.trim()); ai.disabledReason = ''; $('notice').hidden = true; };
  $('resetLib').onclick = () => { library.reset(); renderSettings(); if (matcher) updateBrain(); };
  $('settings').addEventListener('close', () => {
    store.set('accessCode', $('codeInput').value.trim());
    if (matcher && !$('present').hidden && aiOn()) loadLibrary();
  });

  renderPreview();
  showTicker('');

  if ('serviceWorker' in navigator && location.protocol !== 'file:') {
    navigator.serviceWorker.register('sw.js').catch(() => {});
  }
})();
