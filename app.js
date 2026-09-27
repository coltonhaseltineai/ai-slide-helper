(() => {
  const { parseOutline, Matcher } = window.OutlineMatcher;
  const $ = id => document.getElementById(id);
  const SAMPLE = `Welcome and introductions
Why sleep matters
  Memory consolidation [cues: remember, learning]
  Immune health
Tips for better sleep
  Keep a consistent schedule
  Avoid screens before bed
Questions`;

  let stored = null;
  try { stored = localStorage.getItem('outline'); } catch (e) {}
  $('outlineInput').value = stored || SAMPLE;

  let matcher = null, listening = false, recognition = null, transcript = '';

  function render() {
    const ol = $('outline');
    ol.innerHTML = '';
    matcher.items.forEach((it, i) => {
      const li = document.createElement('li');
      li.textContent = it.text;
      li.style.marginLeft = (it.level * 1.5) + 'em';
      li.onclick = () => { matcher.setCurrent(i); highlight(); };
      ol.appendChild(li);
    });
    highlight();
  }

  function highlight() {
    [...$('outline').children].forEach((li, i) => {
      li.classList.toggle('active', i === matcher.current);
      li.classList.toggle('past', i < matcher.current);
    });
    const a = $('outline').children[matcher.current];
    if (a) a.scrollIntoView({ block: 'center', behavior: 'smooth' });
  }

  function setMode(present) {
    $('edit').hidden = present;
    $('present').hidden = !present;
    $('modeBtn').textContent = present ? 'Edit' : 'Present';
    $('micBtn').disabled = !present || !recognition;
    if (present) {
      const text = $('outlineInput').value;
      try { localStorage.setItem('outline', text); } catch (e) {}
      matcher = new Matcher(parseOutline(text));
      render();
    } else if (listening) toggleMic();
  }

  // Exposed so transcripts can be fed from tests or other sources.
  window.feedTranscript = text => {
    transcript = (transcript + ' ' + text).slice(-300);
    $('ticker').textContent = transcript;
    const before = matcher.current;
    matcher.feed(text);
    if (matcher.current !== before) highlight();
  };

  const SR = window.SpeechRecognition || window.webkitSpeechRecognition;
  if (SR) {
    recognition = new SR();
    recognition.continuous = true;
    recognition.interimResults = true;
    recognition.lang = navigator.language || 'en-US';
    recognition.onresult = e => {
      for (let i = e.resultIndex; i < e.results.length; i++) {
        const r = e.results[i];
        if (r.isFinal) window.feedTranscript(r[0].transcript);
        else $('ticker').textContent = transcript + ' ' + r[0].transcript;
      }
    };
    recognition.onend = () => { if (listening) recognition.start(); }; // keep listening through pauses
    recognition.onerror = e => {
      if (e.error === 'not-allowed') { listening = false; updateMic(); showNotice('Microphone access was blocked.'); }
    };
  } else {
    showNotice('Live listening needs Chrome or Edge. You can still present and move through the outline with the arrow keys.');
  }

  function showNotice(msg) { $('notice').textContent = msg; $('notice').hidden = false; }
  function updateMic() {
    $('micBtn').textContent = listening ? '■ Stop listening' : '🎤 Start listening';
    $('micBtn').classList.toggle('live', listening);
  }
  function toggleMic() {
    listening = !listening;
    if (listening) recognition.start(); else recognition.stop();
    updateMic();
  }

  $('modeBtn').onclick = () => setMode($('present').hidden);
  $('micBtn').onclick = toggleMic;
  $('fsBtn').onclick = () => document.fullscreenElement ? document.exitFullscreen() : document.documentElement.requestFullscreen();
  document.addEventListener('keydown', e => {
    if ($('present').hidden || !matcher) return;
    if (e.key === 'ArrowRight' || e.key === 'ArrowDown') matcher.setCurrent(Math.min(matcher.current + 1, matcher.items.length - 1));
    else if (e.key === 'ArrowLeft' || e.key === 'ArrowUp') matcher.setCurrent(Math.max(matcher.current - 1, 0));
    else return;
    e.preventDefault(); highlight();
  });
})();
