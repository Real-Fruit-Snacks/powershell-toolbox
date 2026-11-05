// powershell-toolbox page: theme switch, copy buttons, and the console that replays each script's
// recorded run (window.RUNS, from runs.js). The review replay answers D, A, K, O and Q the way
// Invoke-RepoReview.ps1 -WhatIf does, from the lines it printed. Without JS the page shows the
// recordings as text; with reduced motion nothing types, everything prints at once.
(function () {
  var root = document.documentElement, R = window.RUNS;
  var still = matchMedia('(prefers-reduced-motion: reduce)');
  var light = matchMedia('(prefers-color-scheme: light)');
  var $ = function (s, el) { return (el || document).querySelector(s); };
  var $$ = function (s, el) { return [].slice.call((el || document).querySelectorAll(s)); };

  // ---- theme ----
  function theme() { return root.dataset.theme || (light.matches ? 'dayshift' : 'nightshift'); }
  function paint() {
    var night = theme() === 'nightshift';
    $('meta[name="theme-color"]').content = night ? '#0C0D10' : '#F6F5F2';
    $('#theme').setAttribute('aria-label', 'Theme: ' + (night ? 'Nightshift' : 'Dayshift') + '. Switch to ' + (night ? 'Dayshift' : 'Nightshift'));
  }
  $('#theme').addEventListener('click', function () {
    root.dataset.theme = theme() === 'nightshift' ? 'dayshift' : 'nightshift';
    try { localStorage.setItem('rfs-theme', root.dataset.theme); } catch (e) {}
    paint();
  });
  light.addEventListener('change', paint);
  paint();

  // ---- copy ----
  $$('[data-copy]').forEach(function (b) {
    var label = b.textContent;
    b.addEventListener('click', function () {
      var done = function (ok) { b.textContent = ok ? 'Copied' : 'Select it'; clearTimeout(b._t); b._t = setTimeout(function () { b.textContent = label; }, 1600); };
      if (navigator.clipboard) navigator.clipboard.writeText(b.dataset.copy).then(function () { done(true); }, function () { done(false); });
      else done(false);
    });
  });
  if (!R) return;

  // ---- console output ----
  var run = 0, screen, cur;                 // run: bumps to cancel whatever is playing
  function wait(ms) { var my = run; return new Promise(function (ok, no) { setTimeout(function () { my === run ? ok() : no('cancelled'); }, still.matches ? 0 : ms); }); }
  function put(line, into) {                // line: [[ink, text], ...]
    var el = into || document.createElement('span');
    line.forEach(function (seg) {
      var s = document.createElement('span');
      if (seg[0] !== 'text') s.className = 'i-' + seg[0];
      s.textContent = seg[1];
      el.appendChild(s);
    });
    if (!into) { screen.appendChild(el); screen.appendChild(document.createTextNode('\n')); cur = el; }
    screen.scrollTop = screen.scrollHeight;
    return el;
  }
  function caret(on) { var c = $('.caret', screen); if (c) c.remove(); if (on && cur) cur.appendChild(Object.assign(document.createElement('span'), { className: 'caret' })); }
  function typed(cmd) {
    var el = put([['mute', 'PS> ']]), t = document.createElement('span');
    el.appendChild(t);
    var i = 0, step = function () { if (i >= cmd.length) return Promise.resolve(); t.textContent += cmd[i++]; return wait(28).then(step); };
    return still.matches ? (t.textContent = cmd, Promise.resolve()) : step();
  }
  function lines(list, ms) { return list.reduce(function (p, l) { return p.then(function () { put(l); return wait(ms); }); }, Promise.resolve()); }
  function play(name) {
    if (name !== 'review' && !R[name]) return;   // a script with no recording keeps its static panel
    run++; screen = $('#run-' + name + ' .screen'); screen.textContent = ''; cur = null;
    if (name === 'review') return review();
    var cmds = R[name];
    return cmds.reduce(function (p, c, n) {
      return p.then(function () { return wait(n ? 500 : 250); }).then(function () { return typed(c.cmd); }).then(function () { return wait(450); })
        .then(function () { return lines(c.lines, /\d+\/\d+\]/.test(JSON.stringify(c.lines)) ? 110 : 14); })
        .then(function () { put([]); });
    }, Promise.resolve()).catch(function () {});
  }

  // ---- the review replay ----
  var V = R.review, st = {}, keyBtns = $$('.keys button'), form = $('.confirm'), input = $('#confirm-name');
  function block(i) { V.blocks[i].lines.forEach(function (l) { put(l); }); put(V.prompt); caret(true); }
  function echo(s) { caret(false); put([['text', s]], cur); }
  function setMode(m) {
    st.mode = m;
    keyBtns.forEach(function (b) { b.setAttribute('aria-disabled', m !== 'key'); });
    form.hidden = m !== 'confirm';
    if (m === 'confirm') { input.value = ''; input.focus(); }
  }
  function next() {
    put([]); st.i++;
    if (st.i < V.blocks.length) return block(st.i);
    put([['mute', V.rule]]); put([['text', V.done.replace('{kept}', st.kept)]]); put([['mute', V.log]]); setMode('done');
  }
  function press(k, auto) {
    if (st.mode !== 'key' && !auto) return;
    var b = V.blocks[st.i];
    echo(k);
    if (k === 'k') { st.kept++; next(); }
    else if (k === 'a') { put([['text', V.whatifArchive.replace('{repo}', b.repo)]]); next(); }
    else if (k === 'o') { window.open(b.url, '_blank', 'noopener'); put(V.prompt); caret(true); }
    else if (k === 'd') { put([['amber', V.confirm.replace('{name}', b.repo.split('/')[1])]]); setMode('confirm'); }
    else if (k === 'q') {
      put([]); put([['text', V.stopped.replace('{kept}', st.kept).replace('{remaining}', V.blocks.length - st.i)]]); put([['mute', V.log]]); setMode('done');
    } else { put([['mute', V.invalid]]); put(V.prompt); caret(true); }
  }
  function flash(k) { var b = $('.keys [data-key="' + k + '"]'); b.classList.add('hit'); return wait(220).then(function () { b.classList.remove('hit'); press(k, true); }); }
  function review(auto) {
    st = { i: 0, kept: 0 }; setMode('busy');
    return wait(250).then(function () { return typed(V.cmd); }).then(function () { return wait(400); })
      .then(function () { return lines(V.head, 60); }).then(function () { block(0); })
      .then(function () { if (!auto) return; return wait(1100).then(function () { return flash('k'); }).then(function () { return wait(1100); }).then(function () { return flash('a'); }); })
      .then(function () { setMode('key'); }).catch(function () {});
  }
  keyBtns.forEach(function (b) { b.addEventListener('click', function () { press(b.dataset.key); }); });
  $('#run-review .screen').addEventListener('keydown', function (e) {
    if (/^[a-z]$/i.test(e.key) && !e.ctrlKey && !e.metaKey && !e.altKey && st.mode === 'key') { e.preventDefault(); press(e.key.toLowerCase()); }
  });
  form.addEventListener('submit', function (e) {
    e.preventDefault();
    var b = V.blocks[st.i], name = b.repo.split('/')[1], got = input.value.trim();
    echo(got); setMode('key');
    if (got === name) { put([['text', V.whatifDelete.replace('{repo}', b.repo)]]); next(); }
    else { put([['mute', V.mismatch]]); put(V.prompt); caret(true); }
    screen.focus();
  });

  // ---- the index: rows are tabs ----
  var tabs = $$('.index [role="tab"]'), one = $('#one'), oneCopy = $('#one-copy');
  function select(tab, go) {
    tabs.forEach(function (t) { var on = t === tab; t.setAttribute('aria-selected', on); t.tabIndex = on ? 0 : -1; });
    $$('.panel').forEach(function (p) { p.classList.toggle('on', p.id === tab.getAttribute('aria-controls')); });
    var file = tab.querySelector('.nm').textContent.replace(/\s/g, '');
    var line = 'iwr https://raw.githubusercontent.com/Real-Fruit-Snacks/powershell-toolbox/main/' + file + ' -OutFile ' + file;
    one.textContent = line; oneCopy.dataset.copy = line;
    if (go) play(tab.dataset.run);
  }
  tabs.forEach(function (t, i) {
    t.addEventListener('click', function () { select(t, true); });
    t.addEventListener('keydown', function (e) {
      var to = { ArrowDown: i + 1, ArrowUp: i - 1, Home: 0, End: tabs.length - 1 }[e.key];
      if (to === undefined) return;
      e.preventDefault(); to = (to + tabs.length) % tabs.length; tabs[to].focus(); select(tabs[to], true);
    });
  });
  $('#replay').addEventListener('click', function () { var t = $('.index [aria-selected="true"]'); if (t.dataset.run !== 'review') return play(t.dataset.run); run++; screen = $('#run-review .screen'); screen.textContent = ''; review(true); });

  // on load: the review plays its first two answers, then waits for yours
  select($('#tab-review'), false);
  run++; screen = $('#run-review .screen'); screen.textContent = '';
  review(true);
})();
