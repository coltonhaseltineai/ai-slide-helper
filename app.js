(() => {
  const { parseOutline, Matcher, WordFeeder } = window.OutlineMatcher;
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

  function select(i) {
    if (!matcher || !matcher.items.length) return;
    matcher.setCurrent(Math.max(0, Math.min(i, matcher.items.length - 1)));
    highlight();
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
      renderOutline();
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
    const before = matcher.current;
    matcher.feed(text);
    if (matcher.current !== before) highlight();
  };

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
    if (listening) {
      feeder.reset();
      try { recognition.start(); } catch (e) {}
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

  renderPreview();
  showTicker('');

  if ('serviceWorker' in navigator && location.protocol !== 'file:') {
    navigator.serviceWorker.register('sw.js').catch(() => {});
  }
})();
