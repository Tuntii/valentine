// ---- search (Ctrl+Shift+K) --------------------------------------------------

const findInput = $('#findInput');
let found = [], pick = 0;

function searchItems() {
  return [
    ...panes.map(p => ({ text: tabName(p), hint: 'Pane', run: () => pickPane(p) })),
    ...shortcuts.map(s => ({ text: s.name, hint: s.command, run: () => runShortcut(s) })),
    { text: 'Split right', hint: 'Alt+Shift+=', run: () => splitPane(active, 'row') },
    { text: 'Split down', hint: 'Alt+Shift+-', run: () => splitPane(active, 'col') },
    ...closed.slice(-1).map(r => ({ text: `Reopen ${r.title}`, hint: 'Ctrl+Shift+T', run: reopenPane })),
    { text: 'Notes', hint: 'Sidebar', run: () => toggleSide(true, 'notes') },
    { text: 'Shortcuts', hint: 'Sidebar', run: () => toggleSide(true, 'shortcuts') },
    { text: 'Passwords', hint: 'Sidebar', run: () => toggleSide(true, 'vault') },
    { text: 'Feeds', hint: 'Sidebar', run: () => toggleSide(true, 'feeds') },
    { text: 'worf', hint: 'Sidebar', run: () => toggleSide(true, 'worf') },
    { text: 'Webhooks', hint: 'Sidebar', run: () => toggleSide(true, 'hooks') },
    { text: 'Ports', hint: 'Sidebar', run: () => toggleSide(true, 'ports') },
    { text: 'HTTP request', hint: 'Sidebar', run: () => toggleSide(true, 'http') },
    { text: 'Settings', hint: 'Sidebar', run: () => toggleSide(true, 'look') },
    ...panes.flatMap(p => [...p.servers].map(url => ({ text: `Open ${url}`, hint: tabName(p), run: () => openUrl(url) }))),
    ...Object.keys(PRESETS).map(n => ({ text: `Layout ${n}`, hint: 'Layout', run: () => applyPreset(n) })),
    ...Object.keys(THEMES).map(n => ({ text: `Theme: ${n}`, hint: 'Settings', run: () => pickTheme(n) })),
  ];
}

function showResults() {
  const q = findInput.value.trim().toLowerCase();
  found = searchItems().filter(it => `${it.text} ${it.hint}`.toLowerCase().includes(q));
  pick = Math.min(pick, Math.max(0, found.length - 1));
  $('#results').replaceChildren(...found.map((it, i) => {
    const row = el('div', i === pick ? 'on' : '', { role: 'option', onmousedown: e => { e.preventDefault(); runFound(i); } });
    row.append(el('span', '', { textContent: it.text }), el('small', '', { textContent: it.hint }));
    return row;
  }));
  $('#results').hidden = !found.length;
  $('#results .on')?.scrollIntoView({ block: 'nearest' });
}

function runFound(i) {
  const it = found[i];
  findInput.blur(); // closes the list
  active?.term?.focus();
  it?.run();
}

findInput.onfocus = findInput.oninput = () => { pick = 0; showResults(); };
findInput.onblur = () => {
  findInput.value = '';
  $('#results').hidden = true;
};
findInput.onkeydown = e => {
  if (e.key === 'ArrowDown' || e.key === 'ArrowUp') {
    pick = (pick + (e.key === 'ArrowDown' ? 1 : -1) + found.length) % Math.max(1, found.length);
    showResults();
  } else if (e.key === 'Enter') runFound(pick);
  else if (e.key === 'Escape') { findInput.blur(); active?.term?.focus(); }
  else return;
  e.preventDefault();
};

// ---- keys -------------------------------------------------------------------

function keys(e) {
  if (e.key === 'Escape' && menu) return closeMenu(), true;
  if (editing && editing.box.contains(e.target)) return false; // the editor owns its keys
  if (e.key === 'Escape' && $('#side').contains(e.target)) return toggleSide(false), true;
  if (e.key === 'Escape' && panes.some(p => p.countdown)) return panes.forEach(cancelCountdown), true;
  const k = e.key, code = e.code;
  if (e.ctrlKey && e.shiftKey && !e.altKey) {
    if (k === 'Enter') return toggleMax(active), true;
    if (code === 'KeyW') return closePane(active), true;
    if (code === 'KeyT') return reopenPane(), true;
    if (code === 'KeyK') return findInput.focus(), true;
    if (code === 'KeyB') return toggleSide(), true;
    return false;
  }
  if (!e.altKey || e.ctrlKey) return false;
  const arrows = { ArrowLeft: [-1, 0], ArrowRight: [1, 0], ArrowUp: [0, -1], ArrowDown: [0, 1] };
  if (arrows[k]) {
    const [dx, dy] = arrows[k];
    if (e.shiftKey) nudge(dx ? 'row' : 'col', (dx || dy) * 0.04); else moveFocus(dx, dy);
    return true;
  }
  if (!e.shiftKey) return false;
  // Keys by character and by numpad, so Turkish-Q and US layouts both work.
  if (k === '+' || k === '=' || code === 'NumpadAdd') return splitPane(active, 'row'), true;
  if (k === '-' || k === '_' || code === 'NumpadSubtract') return splitPane(active, 'col'), true;
  if (code === 'KeyD') return splitPane(active, null), true;
  return false;
}

// ---- boot -----------------------------------------------------------------

// Capture phase, so these win over the focused terminal (and over Alt+Left = "Back").
addEventListener('keydown', e => {
  if (keys(e)) { e.preventDefault(); e.stopPropagation(); }
}, true);
addEventListener('mousedown', e => { if (menu && !menu.contains(e.target)) closeMenu(); }, true);
addEventListener('blur', closeMenu);
$('#sideBtn').onclick = () => toggleSide();
$('#newBtn').onclick = () => splitPane(active || panes[0], null);
$('#startDir').onchange = e => send({ type: 'config', name: 'start_dir', value: e.target.value.trim() });
$('#colorReset').onclick = () => pickTheme(theme);
$('#side nav').onclick = e => { const tab = e.target.closest('button')?.dataset.tab; if (tab) showSideTab(tab); };
showSideTab('notes');
$('#notes').oninput = () => { clearTimeout(notesTimer); notesTimer = setTimeout(saveNotes, 500); };
$('#shortcutForm').onsubmit = e => {
  e.preventDefault();
  const f = e.target.elements, name = f.namedItem('name').value.trim(), command = f.namedItem('command').value.trim();
  if (!name || !command) return;
  shortcuts.push({ name, command, cwd: f.namedItem('cwd').value.trim() });
  e.target.reset();
  saveShortcuts();
};
if (nativeWindow) { // our own window: its caption is gone, so the bar does the caption's job
  $('#winctl').hidden = false;
  $('#winctl').onclick = e => { const op = e.target.closest('button')?.dataset.op; if (op) winOp(+op); };
  $('#bar').onmousedown = barDown;
  for (const g of document.querySelectorAll('.grip')) {
    g.hidden = false;
    g.onmousedown = e => { if (e.button === 0) { e.preventDefault(); winOp(+g.dataset.op); } };
  }
  addEventListener('resize', () => winOp(0));
  winOp(0);
}
setInterval(() => {
  const now = Date.now();
  panes.forEach(p => p.dirty && (now - p.lastOutputAt > SAVE_IDLE_MS || now - p.savedAt > SAVE_MAX_MS) && save(p));
}, SAVE_EVERY_MS);
addEventListener('beforeunload', () => {
  panes.forEach(p => p.term && save(p));
  if (notesTimer) saveNotes();
});
connect();
