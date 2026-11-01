// Terminal colour schemes; accent tints the UI. The first is the default.
const ANSI = ['black', 'red', 'green', 'yellow', 'blue', 'magenta', 'cyan', 'white'];
const scheme = (background, foreground, accent, normal, bright) => ({
  accent,
  term: {
    background, foreground, cursor: foreground, cursorAccent: background, selectionBackground: '#ffffff40',
    ...Object.fromEntries(ANSI.map((c, i) => [c, normal[i]])),
    ...Object.fromEntries(ANSI.map((c, i) => ['bright' + c[0].toUpperCase() + c.slice(1), bright[i]])),
  },
});
const THEMES = {
  Campbell: scheme('#0c0c0c', '#cccccc', '#4cc2ff',
    ['#0c0c0c', '#c50f1f', '#13a10e', '#c19c00', '#0037da', '#881798', '#3a96dd', '#cccccc'],
    ['#767676', '#e74856', '#16c60c', '#f9f1a5', '#3b78ff', '#b4009e', '#61d6d6', '#f2f2f2']),
  'One Half Dark': scheme('#282c34', '#dcdfe4', '#61afef',
    ['#282c34', '#e06c75', '#98c379', '#e5c07b', '#61afef', '#c678dd', '#56b6c2', '#dcdfe4'],
    ['#5a6374', '#e06c75', '#98c379', '#e5c07b', '#61afef', '#c678dd', '#56b6c2', '#dcdfe4']),
  Dracula: scheme('#282a36', '#f8f8f2', '#bd93f9',
    ['#21222c', '#ff5555', '#50fa7b', '#f1fa8c', '#bd93f9', '#ff79c6', '#8be9fd', '#f8f8f2'],
    ['#6272a4', '#ff6e6e', '#69ff94', '#ffffa5', '#d6acff', '#ff92df', '#a4ffff', '#ffffff']),
  'Tokyo Night': scheme('#1a1b26', '#c0caf5', '#7aa2f7',
    ['#15161e', '#f7768e', '#9ece6a', '#e0af68', '#7aa2f7', '#bb9af7', '#7dcfff', '#a9b1d6'],
    ['#414868', '#f7768e', '#9ece6a', '#e0af68', '#7aa2f7', '#bb9af7', '#7dcfff', '#c0caf5']),
  'Gruvbox Dark': scheme('#282828', '#ebdbb2', '#fabd2f',
    ['#282828', '#cc241d', '#98971a', '#d79921', '#458588', '#b16286', '#689d6a', '#a89984'],
    ['#928374', '#fb4934', '#b8bb26', '#fabd2f', '#83a598', '#d3869b', '#8ec07c', '#ebdbb2']),
};
const DIVIDER = {
  crash: '\r\n\x1b[1;33m--- [VALENTINE: RESTORED AFTER UNEXPECTED SHUTDOWN] ---\x1b[0m\r\n',
  clean: '\r\n\x1b[90m--- [VALENTINE: SESSION RESTORED] ---\x1b[0m\r\n',
};
// Main screen, default attributes, visible cursor, normal cursor keys and keypad,
// no bracketed paste, no mouse tracking.
const RESET_MODES = '\x1b[?1049l\x1b[0m\x1b[?25h\x1b[?1l\x1b>\x1b[?2004l\x1b[?1000l\x1b[?1002l\x1b[?1003l\x1b[?1006l';
const SAVE_EVERY_MS = 1500;
// A pane is saved once its output has been quiet SAVE_IDLE_MS, and at least every
// SAVE_MAX_MS while it keeps printing: serializing scrollback is the costly part.
const SAVE_IDLE_MS = 2000;
const SAVE_MAX_MS = 30000;
const MAX_WEBGL = 12;
const SHOW_RUNNING_AFTER_MS = 2000; // quick commands never flash a badge
const NOTIFY_AFTER_MS = 3000;       // background commands at least this long get "done"
const AGENT_QUIET_MS = 5000;        // ask_agent: an agent silent this long has finished answering
const SHELL_NAMES = { powershell: 'PowerShell', cmd: 'cmd', gitbash: 'Git Bash', wsl: 'WSL', zsh: 'zsh', bash: 'bash', fish: 'fish' };
const SAVED_SCROLLBACK = 5000;
const FLOW_HIGH = 512 * 1024, FLOW_LOW = 64 * 1024; // bytes xterm has queued but not parsed
const CLOSED_KEPT = 10;                             // closed panes Ctrl+Shift+T can bring back

// ---- state ------------------------------------------------------------------

const params = new URLSearchParams(location.search);
const idDecoder = new TextDecoder();
const panes = [];
let ws, tree, active, menu, editing, layoutTimer, unclean = false, winBuild = 0, disconnectedAt = 0;
const closed = []; // most recent last, see reopenPane
let autostart = false, shells = ['powershell'];
let theme = 'Campbell', colors = {}, termTheme, shortcuts = [], zoomed = false;
const nativeWindow = window.valentine_window; // absent in the Edge app-window fallback

const $ = s => document.querySelector(s);
const byId = id => panes.find(p => p.id === id);
function el(tag, cls, props) {
  const e = document.createElement(tag);
  if (cls) e.className = cls;
  return Object.assign(e, props);
}
function send(msg) {
  if (ws?.readyState === WebSocket.OPEN) ws.send(JSON.stringify(msg));
}
function toast(text) {
  $('#toast').textContent = text;
  $('#toast').hidden = !text;
}
// flash is the one way to tell the user about an outcome or error: a toast that goes away.
let flashTimer = 0;
function flash(text, ms = 4000) {
  toast(text);
  clearTimeout(flashTimer);
  flashTimer = setTimeout(() => { if ($('#toast').textContent === text) toast(''); }, ms);
}

// logLine writes to valentine.log through the backend; capped so a loop cannot flood it.
let logged = 0;
function logLine(text) {
  if (logged++ < 200) send({ type: 'log', data: String(text) });
}
addEventListener('error', e => logLine(`${e.message} (${String(e.filename).split('/').pop()}:${e.lineno})`));
addEventListener('unhandledrejection', e => logLine(`unhandled rejection: ${e.reason?.stack || e.reason}`));

// ---- connection -----------------------------------------------------------

function connect() {
  ws = new WebSocket(`ws://127.0.0.1:${params.get('ws')}/?t=${params.get('t')}`);
  ws.binaryType = 'arraybuffer';
  ws.onopen = () => { toast(''); send({ type: 'hello' }); };
  ws.onmessage = e => {
    if (e.data instanceof ArrayBuffer) { // PTY output: [id length][id][bytes]
      const b = new Uint8Array(e.data), n = b[0], p = byId(idDecoder.decode(b.subarray(1, 1 + n)));
      if (p?.term) {
        // Flow control: xterm queues what it has not parsed yet. Past FLOW_HIGH the backend
        // stops reading this pty until the queue is back under FLOW_LOW.
        const data = b.subarray(1 + n);
        p.queued += data.length;
        p.term.write(data, () => {
          p.queued -= data.length;
          if (p.paused && p.queued < FLOW_LOW) { p.paused = false; send({ type: 'resume', pane_id: p.id }); }
        });
        if (!p.paused && p.queued > FLOW_HIGH) { p.paused = true; send({ type: 'pause', pane_id: p.id }); }
        p.dirty = true;
        p.lastOutputAt = Date.now();
        if (p.scanUntil > p.lastOutputAt) scanServers(p);
      }
      return;
    }
    const m = JSON.parse(e.data);
    if (m.type === 'state') restore(m);
    else if (m.type === 'exit') exited(byId(m.pane_id), m.code);
    else if (m.type === 'claude') onClaude(byId(m.pane_id), m);
    else if (m.type === 'mcp') onMcp(m);
    else if (m.type === 'fetched') onFetched(m);
  };
  // Reconnect in place: the terminals stay on screen (a reload would rebuild them from the
  // last save), and the backend's state on hello tells us what changed meanwhile.
  ws.onclose = () => {
    disconnectedAt ||= Date.now();
    toast('Reconnecting…');
    setTimeout(connect, 1500);
  };
}

// resync catches up after a reconnect: messages sent while the socket was down are lost.
function resync(m) {
  logLine(`reconnected after ${Math.round((Date.now() - disconnectedAt) / 1000)} s`);
  disconnectedAt = 0;
  const live = new Set((m.panes || []).filter(r => r.running).map(r => r.id));
  for (const p of panes) {
    p.paused = false; // the backend dropped every pause when this window attached
    meta(p); // first: it creates the row a split made while offline, which save needs
    if (p.term) save(p);
    if (p.running && !live.has(p.id)) exited(p, '?'); // its exit message never arrived
  }
  saveLayout();
}

function restore(m) {
  if (panes.length) return resync(m);
  unclean = m.unclean;
  winBuild = m.win_build;
  autostart = m.autostart;
  shells = m.shells || shells;
  const cfg = m.config || {};
  try { shortcuts = JSON.parse(cfg.shortcuts || '[]'); } catch { /* start over */ }
  if (!Array.isArray(shortcuts)) shortcuts = [];
  $('#notes').value = cfg.notes || '';
  renderShortcuts();
  feeds = parseList(cfg.feeds, DEFAULT_FEEDS);
  renderFeedPick();
  vault.stored = parseList(cfg.vault, null);
  renderVault();
  worf = { url: 'https://worf.rustapi.cloud', token: '', ...parseList(cfg.worf, {}) };
  $('#worfForm').elements.namedItem('url').value = worf.url;
  $('#worfForm').elements.namedItem('token').value = worf.token;
  pollWorf();
  relay = { url: 'https://valentine.rustapi.cloud', token: '', forward: '', ...parseList(cfg.relay, {}) };
  for (const k of ['url', 'token', 'forward']) $('#hookForm').elements.namedItem(k).value = relay[k];
  pollRelay();
  colors = parseList(cfg.colors, {});
  applyTheme(THEMES[cfg.theme] ? cfg.theme : 'Campbell', false); // before any terminal opens
  renderLook();
  $('#startDir').value = cfg.start_dir || '';
  const http = parseList(cfg.http, {});
  for (const k of ['method', 'url', 'headers', 'body']) if (typeof http[k] === 'string') $('#httpForm').elements.namedItem(k).value = http[k];
  const rows = m.panes || [];
  if (!rows.length) {
    for (let i = 0; i < 4; i++) panes.push(createPane({}));
    tree = PRESETS['2×2'].build(panes.map(p => p.id));
  } else {
    rows.forEach(r => panes.push(createPane(r)));
    let saved = null;
    try { saved = JSON.parse(m.layout || 'null'); } catch { /* fall back to a default grid */ }
    tree = sanitize(saved, panes.map(p => p.id));
  }
  relayout(); // creates the pane rows before any spawn asks for their cwd
  panes.forEach(start);
  setActive(panes[0]);
  panes[0].term.focus();
}

// ---- panes ----------------------------------------------------------------

function createPane(r) {
  const p = {
    id: r.id || 'p' + crypto.randomUUID().slice(0, 8),
    title: r.title || `Terminal ${panes.length + 1}`,
    cwd: r.cwd || '', cmd: r.startup_cmd || '', autorun: !!r.autorun, shell: r.shell || '',
    running: !!r.running, buffer: r.buffer || '', savedAt: Date.now(),
    claude: r.claude || '',              // Claude Code session to resume on the next spawn
    inClaude: !!(r.running && r.claude),
    pendingCommand: r.pendingCommand || '', // typed once the new shell shows its first prompt
    reopened: !!r.reopened, queued: 0, paused: false,
    branch: '', servers: new Set(),       // local URLs its running command printed
  };
  p.el = el('div', 'pane');
  p.termEl = el('div', 'term');
  p.label = el('div', 'label', { title: 'Double-click to rename · right-click for options' });
  p.badge = el('span', 'badge');
  p.labelText = el('span');
  p.label.append(p.badge, p.labelText);
  p.overlay = el('div', 'countdown', { hidden: true, title: 'Click to cancel', onclick: () => cancelCountdown(p) });
  p.el.append(p.termEl, p.label, p.overlay);
  p.el.addEventListener('mousedown', () => setActive(p));
  p.el.addEventListener('contextmenu', e => { e.preventDefault(); setActive(p); openMenu(p, e.clientX, e.clientY); });
  p.label.ondblclick = () => rename(p);
  if (p.inClaude) setStatus(p, 'claude');
  showLabel(p);
  return p;
}

// start opens the terminal (the pane must already be in the DOM), replays saved
// scrollback, then spawns a shell or, after a page reload, re-attaches to the live one.
function start(p) {
  const term = p.term = new Terminal({
    fontFamily: "'Cascadia Mono', 'Cascadia Code', Consolas, Menlo, 'DejaVu Sans Mono', monospace", fontSize: 13,
    cursorBlink: true, scrollback: 10000, theme: termTheme, allowProposedApi: true,
    // ConPTY before build 21376 does not reflow on resize; xterm must not either or
    // the two screens drift apart.
    windowsPty: winBuild ? { backend: 'conpty', buildNumber: winBuild } : {}, // 0: a real Unix pty
  });
  p.fit = new FitAddon.FitAddon();
  p.ser = new SerializeAddon.SerializeAddon();
  term.loadAddon(p.fit);
  term.loadAddon(p.ser);
  term.open(p.termEl);
  // Chromium keeps ~16 WebGL contexts per page and drops the oldest beyond that, so
  // panes past MAX_WEBGL use the slower DOM renderer instead of losing their canvas.
  if (panes.filter(q => q.gl).length < MAX_WEBGL) try {
    const gl = new WebglAddon.WebglAddon();
    gl.onContextLoss(() => { gl.dispose(); p.gl = null; });
    term.loadAddon(gl);
    p.gl = gl;
  } catch { /* the DOM renderer still works */ }
  p.fit.fit();
  // OSC 9;9;"<path>" comes from the prompt hook the backend injects into PowerShell.
  term.parser.registerOscHandler(9, data => {
    if (!data.startsWith('9;')) return false;
    setCwd(p, data.slice(2).replace(/^"|"$/g, ''));
    return true;
  });
  // OSC 133;D[;code]: the shell is back at its prompt (sent by every shell's prompt hook).
  term.parser.registerOscHandler(133, data => {
    if (data[0] === 'D') commandFinished(p, parseInt(data.split(';')[1], 10) || 0);
    return true;
  });
  term.loadAddon(new WebLinksAddon.WebLinksAddon((e, uri) => {
    if (e.ctrlKey || e.metaKey) send({ type: 'open', url: uri });
  }, {
    hover: () => { p.termEl.title = 'Ctrl+click to open'; },
    leave: () => { p.termEl.title = ''; },
  }));
  term.onTitleChange(t => {
    p.appTitle = t;
    if (p.inClaude) showLabel(p);
  });
  term.onData(d => input(p, d));
  term.attachCustomKeyEventHandler(e => clipboardKeys(p, e));
  term.textarea.addEventListener('focus', () => setActive(p));
  p.ro = new ResizeObserver(() => scheduleFit(p));
  p.ro.observe(p.termEl);

  const saved = p.buffer;
  p.buffer = '';
  const go = () => (p.running ? sendResize(p) : spawn(p));
  if (!saved) return go();
  term.write(saved, () => {
    if (p.running) return go(); // re-attach: the live screen is already right
    // A snapshot taken mid-TUI can leave alt screen, mouse or app-cursor modes on and
    // the cursor mid-screen; reset them and start below the last line with content.
    term.write(RESET_MODES, () => term.write(belowContent(term) + (unclean && !p.reopened ? DIVIDER.crash : DIVIDER.clean), go));
  });
}

function belowContent(term) {
  const b = term.buffer.active;
  for (let y = b.baseY + term.rows - 1; y > b.baseY + b.cursorY; y--) {
    if (b.getLine(y)?.translateToString(true)) return `\x1b[${y - b.baseY + 1};1H`;
  }
  return '';
}

function spawn(p) {
  p.running = true;
  p.sentCols = p.term.cols;
  p.sentRows = p.term.rows;
  send({ type: 'spawn', pane_id: p.id, cols: p.term.cols, rows: p.term.rows });
  // The id comes from Claude's own hook; still, only plain ids are typed into a shell.
  if (/^[\w-]{1,64}$/.test(p.claude)) countdown(p, `claude --resume ${p.claude}`, 'Resume Claude Code session');
  else if (p.autorun && p.cmd) countdown(p, p.cmd, 'Auto-run');
  // Shells that never report a prompt (no OSC 133) still get the command, a bit later.
  if (p.pendingCommand) setTimeout(() => runPending(p), 4000);
}

function typeCommand(p, cmd) {
  send({ type: 'input', pane_id: p.id, data: cmd + '\r' });
  commandStarted(p);
}

function runPending(p) {
  if (!p.pendingCommand || !p.running) return;
  send({ type: 'input', pane_id: p.id, data: p.pendingCommand + '\r' });
  p.pendingCommand = '';
  commandStarted(p);
}

function input(p, d) {
  if (!p.running) {
    if (d.includes('\r')) { p.term.write('\r\n'); spawn(p); }
    return;
  }
  send({ type: 'input', pane_id: p.id, data: d });
  if (d.includes('\r')) {
    save(p);
    commandStarted(p);
  }
}

function exited(p, code) {
  if (!p?.term) return;
  p.running = false;
  p.integrated = false;
  p.inClaude = false;
  p.busySince = 0;
  p.servers.clear();
  setStatus(p, '');
  cancelCountdown(p);
  if (p.respawn) { // killed on purpose, e.g. to switch shells
    p.respawn = false;
    p.term.write('\r\n');
    return spawn(p);
  }
  p.term.write(`\r\n\x1b[90m[process exited with code ${code}; press Enter to restart]\x1b[0m\r\n`);
  save(p);
}

function save(p) {
  p.dirty = false;
  p.savedAt = Date.now();
  send({ type: 'save_buffer', pane_id: p.id, data: p.ser.serialize({ scrollback: SAVED_SCROLLBACK }) });
}

function meta(p) {
  send({ type: 'pane_meta', pane_id: p.id, title: p.title, startup_cmd: p.cmd, autorun: p.autorun, shell: p.shell, slot: panes.indexOf(p) });
}

// ---- command status (from OSC 133) ------------------------------------------
// Only panes whose shell has reported at least once are tracked, so a shell without
// the hook (custom PROMPT_COMMAND, plain WSL) never gets stuck on "running".

function commandStarted(p) {
  if (!p.integrated || p.busySince || p.inClaude) return;
  p.busySince = Date.now();
  p.scanUntil = p.busySince + SCAN_FOR_MS;
  setStatus(p, '');
  clearTimeout(p.busyTimer);
  p.busyTimer = setTimeout(() => p.busySince && setStatus(p, 'running'), SHOW_RUNNING_AFTER_MS);
}

function commandFinished(p, code) {
  p.integrated = true;
  refreshBranch(p); // the command may have been a checkout or a git init
  p.servers.clear(); // back at the prompt: whatever it started has stopped
  p.scanUntil = 0;
  if (!p.busySince) return runPending(p); // first prompt of a new shell
  const took = Date.now() - p.busySince;
  p.busySince = 0;
  clearTimeout(p.busyTimer);
  p.onFinish?.(code);
  const wasClaude = p.claudeRan;
  p.claudeRan = false;
  if (p.inClaude || wasClaude) return;
  if (code) setStatus(p, 'fail', code);
  else setStatus(p, p !== active && took >= NOTIFY_AFTER_MS ? 'done' : '');
}

function setStatus(p, status, detail) {
  p.badge.className = 'badge ' + status;
  p.badge.title = status === 'claude-ask' ? detail || '' : '';
  p.badge.textContent = {
    running: '● running', done: '✓ done', fail: `✕ exit ${detail}`,
    claude: '✳ Claude', 'claude-busy': '✳ working', 'claude-wait': '✳ your turn', 'claude-ask': '✳ needs you',
  }[status] || '';
  renderTabs();
}

// ---- Claude Code (events from its hooks, see claude.v) -----------------------

function onClaude(p, m) {
  if (!p) return;
  switch (m.event) {
    case 'SessionStart':
      p.inClaude = p.claudeRan = true;
      p.claude = m.session_id;
      clearTimeout(p.busyTimer); // hooks own the badge from here
      setStatus(p, 'claude');
      break;
    case 'UserPromptSubmit':
      setStatus(p, 'claude-busy');
      break;
    case 'Stop':
      p.stopCount = (p.stopCount || 0) + 1;
      setStatus(p, p === active ? 'claude' : 'claude-wait');
      break;
    case 'Notification':
      setStatus(p, 'claude-ask', m.message);
      break;
    case 'SessionEnd':
      p.inClaude = false;
      p.claude = '';
      setStatus(p, '');
      break;
  }
  showLabel(p);
}

function setShell(p, shell) {
  if (shell === (p.shell || shells[0])) return;
  p.shell = shell;
  changed(p); // the backend reads the new shell from the row on the next spawn
  if (p.running) {
    p.respawn = true;
    send({ type: 'kill', pane_id: p.id });
  }
}

function setCwd(p, cwd) {
  if (!cwd || cwd === p.cwd) return;
  p.cwd = cwd;
  showLabel(p);
  send({ type: 'cwd_update', pane_id: p.id, cwd });
  refreshBranch(p);
}

// refreshBranch reads the checked-out branch (the backend reads .git/HEAD, no git process).
function refreshBranch(p) {
  if (!p.cwd) return;
  ask({ type: 'git_branch', cwd: p.cwd }).then(r => {
    if (!r || r.error || r.body === p.branch) return;
    p.branch = r.body;
    showLabel(p);
  });
}

// Dev servers print where they listen once, early: the screen is scanned for local URLs
// for SCAN_FOR_MS after a command starts, at most every SCAN_EVERY_MS, never otherwise.
const SCAN_FOR_MS = 30000, SCAN_EVERY_MS = 400;
function scanServers(p) {
  if (p.scanTimer) return;
  p.scanTimer = setTimeout(() => {
    p.scanTimer = 0;
    for (const u of localServers(screenText(p, 40))) p.servers.add(u);
  }, SCAN_EVERY_MS);
}

function showLabel(p) {
  const slash = p.cwd.includes('\\') ? '\\' : '/';
  const parts = p.cwd.split(slash).filter(Boolean);
  const head = slash === '/' ? '' : parts[0];
  const cwd = parts.length > 3 ? `${head}${slash}…${slash}${parts.slice(-2).join(slash)}` : p.cwd;
  const shell = p.shell && p.shell !== shells[0] ? SHELL_NAMES[p.shell] || p.shell : '';
  const app = p.inClaude ? p.appTitle : '';
  p.labelText.textContent = [p.title, shell, app, cwd, p.branch && `⎇ ${p.branch}`, p.autorun && p.cmd ? `⟳ ${p.cmd}` : ''].filter(Boolean).join('  ·  ');
  renderTabs();
}

function scheduleFit(p) {
  if (p.fitPending) return;
  p.fitPending = true;
  requestAnimationFrame(() => {
    p.fitPending = false;
    if (!p.term || !p.termEl.offsetWidth || !p.termEl.offsetHeight) return;
    p.fit.fit();
    if (p.running && (p.term.cols !== p.sentCols || p.term.rows !== p.sentRows)) sendResize(p);
  });
}

function sendResize(p) {
  p.sentCols = p.term.cols;
  p.sentRows = p.term.rows;
  send({ type: 'resize', pane_id: p.id, cols: p.term.cols, rows: p.term.rows });
}

function setActive(p) {
  if (!p || active === p) return;
  active?.el.classList.remove('active');
  active = p;
  p.el.classList.add('active');
  if (p.badge.classList.contains('done')) setStatus(p, '');
  if (p.badge.classList.contains('claude-wait')) setStatus(p, 'claude');
  renderTabs();
}

function focusPane(p) {
  setActive(p);
  p?.term?.focus();
}

function countdown(p, cmd, caption) {
  let n = 3;
  p.countdown = true;
  const tick = () => {
    if (!p.countdown) return;
    if (n === 0) {
      cancelCountdown(p);
      send({ type: 'input', pane_id: p.id, data: cmd + '\r' });
      commandStarted(p);
      return;
    }
    p.overlay.replaceChildren(`${caption} in ${n}s: `, el('code', '', { textContent: cmd }), '  ·  Press Esc to cancel');
    p.overlay.hidden = false;
    n--;
    p.timer = setTimeout(tick, 1000);
  };
  tick();
}

function cancelCountdown(p) {
  p.countdown = false;
  clearTimeout(p.timer);
  p.overlay.hidden = true;
}

function clipboardKeys(p, e) {
  if (p.inClaude && e.type === 'keydown' && e.key === 'Enter' && e.shiftKey && !e.ctrlKey && !e.altKey) {
    send({ type: 'input', pane_id: p.id, data: '\n' });
    e.preventDefault();
    return false;
  }
  if (e.type !== 'keydown' || !(e.ctrlKey || e.metaKey) || e.altKey) return true; // metaKey: Cmd on macOS
  const k = e.key.toLowerCase();
  if (k === 'c' && p.term.hasSelection()) {
    navigator.clipboard.writeText(p.term.getSelection()).catch(() => {});
    p.term.clearSelection();
    e.preventDefault();
    return false;
  }
  // false without preventDefault: xterm skips the key and the browser fires a native paste.
  if (k === 'v') return false;
  return true;
}

// ---- tree operations --------------------------------------------------------

function render() {
  const build = (n, f) => {
    if (n.pane) {
      const p = byId(n.pane);
      p.el.style.setProperty('--f', f);
      return p.el;
    }
    const box = el('div', 'split ' + n.split);
    box.style.setProperty('--f', f);
    const a = build(n.a, n.ratio), b = build(n.b, 1 - n.ratio);
    box.append(a, divider(n, a, b), b);
    return box;
  };
  const hadFocus = active?.el.contains(document.activeElement);
  $('#root').replaceChildren(build(tree, 1));
  if (hadFocus) active.term?.focus(); // moving a node in the DOM drops its focus
}

function divider(node, a, b) {
  const g = el('div', 'divider');
  g.onpointerdown = e => {
    const horiz = node.split === 'row', box = g.parentElement.getBoundingClientRect();
    const from = horiz ? box.left : box.top, size = horiz ? box.width : box.height;
    g.setPointerCapture(e.pointerId);
    g.onpointermove = ev => {
      node.ratio = clampRatio(((horiz ? ev.clientX : ev.clientY) - from) / size);
      a.style.setProperty('--f', node.ratio);
      b.style.setProperty('--f', 1 - node.ratio);
    };
    g.onpointerup = () => { g.onpointermove = g.onpointerup = null; saveLayout(); };
    e.preventDefault();
  };
  return g;
}

// relayout redraws the tree and keeps pane order (= saved slot) in tree order.
function relayout() {
  render();
  const order = leaves(tree);
  panes.sort((x, y) => order.indexOf(x.id) - order.indexOf(y.id));
  panes.forEach(meta);
  saveLayout();
  renderTabs();
}

function saveLayout() {
  clearTimeout(layoutTimer);
  layoutTimer = setTimeout(() => send({ type: 'layout', layout: JSON.stringify(tree) }), 300);
}

function splitPane(p, split, settings = {}, focus = true) {
  if (!p) return;
  unmaximize();
  split ||= 'row'; // no direction given: the new pane goes right beside p
  const q = createPane(settings);
  panes.push(q);
  tree = replaceLeaf(tree, p.id, n => ({ split, ratio: 0.5, a: n, b: leaf(q.id) }));
  relayout(); // creates q's row
  if (q.cwd) send({ type: 'cwd_update', pane_id: q.id, cwd: q.cwd }); // read by the spawn
  start(q);
  if (focus) focusPane(q);
  return q;
}

// ---- MCP tools (requests from `valentine mcp`, see claude.v) -------------------

async function onMcp(m) {
  let res;
  try {
    const { tool, args, from } = JSON.parse(m.payload);
    if (!Object.hasOwn(MCP_TOOLS, tool)) throw new Error(`unknown tool ${tool}`);
    res = { text: await MCP_TOOLS[tool](args || {}, from ? byId(from) : null), is_error: false };
  } catch (e) {
    res = { text: String(e?.message || e), is_error: true };
  }
  send({ type: 'mcp_result', req_id: m.req_id, result: JSON.stringify(res) });
}

function findPane(ref) {
  if (!ref) {
    if (!active) throw new Error('no pane is focused; pass a pane id or name');
    return active;
  }
  const want = String(ref).toLowerCase();
  const hits = panes.filter(p => p.id === ref || p.title.toLowerCase() === want);
  if (hits.length === 1) return hits[0];
  throw new Error(hits.length ? `several panes are named "${ref}"; use its id` : `no pane "${ref}"; call list_panes`);
}

// paneText returns buffer lines [from, to) as text, joining soft-wrapped lines.
function paneText(p, from, to) {
  const b = p.term.buffer.active, out = [];
  for (let y = Math.max(0, from); y < to; y++) {
    const line = b.getLine(y);
    if (!line) continue;
    const text = line.translateToString(true);
    if (line.isWrapped && out.length) out[out.length - 1] += text; else out.push(text);
  }
  while (out.length && !out.at(-1).trim()) out.pop();
  return out.join('\n');
}

const MCP_TOOLS = {
  list_panes: () => JSON.stringify(panes.map(p => ({
    id: p.id, name: p.title, cwd: p.cwd, shell: p.shell || shells[0], focused: p === active,
    terminal_title: p.appTitle || '', // e.g. what Claude Code, OpenCode or Grok call themselves
    shell_running: p.running, command_running: !!p.busySince, claude_code: !!p.inClaude,
    status: p.badge.textContent || 'idle',
  })), null, 1),

  read_pane: ({ pane, lines = 80 }) => {
    const p = findPane(pane), end = p.term.buffer.active.baseY + p.term.rows;
    return paneText(p, end - Math.min(Math.max(1, lines | 0), 2000), end) || '(empty)';
  },

  run_command: async ({ pane, command, timeout_seconds = 60 }) => {
    const p = findPane(pane);
    if (!command) throw new Error('command is required');
    if (!p.running) throw new Error('that pane has no running shell');
    if (p.inClaude) throw new Error('Claude Code is running in that pane');
    if (p.busySince) throw new Error('a command is already running in that pane');
    if (!p.integrated) throw new Error('that shell does not report when commands finish; use send_text and read_pane');
    const secs = Math.min(Math.max(1, timeout_seconds | 0), 120);
    const mark = p.term.registerMarker(0); // the prompt line the command is typed on
    const finished = new Promise(resolve => { p.onFinish = resolve; });
    send({ type: 'input', pane_id: p.id, data: command + '\r' });
    commandStarted(p);
    const code = await Promise.race([finished, new Promise(r => setTimeout(() => r(null), secs * 1000))]);
    p.onFinish = null;
    const b = p.term.buffer.active, cursor = b.baseY + b.cursorY;
    // Finished: stop before the fresh prompt. Still running: include the cursor line.
    const out = paneText(p, mark.line, code === null ? cursor + 1 : cursor);
    mark.dispose();
    return code === null ? `still running after ${secs}s (left running)\n${out}` : `exit code ${code}\n${out}`;
  },

  send_text: ({ pane, text, enter = true }) => {
    const p = findPane(pane);
    if (!p.running) throw new Error('that pane has no running shell');
    send({ type: 'input', pane_id: p.id, data: String(text ?? '') + (enter ? '\r' : '') });
    if (enter) commandStarted(p);
    return 'sent';
  },

  open_pane: ({ name, cwd, shell, command, split_from, direction }) => {
    if (shell && !shells.includes(shell)) throw new Error(`shell must be one of: ${shells.join(', ')}`);
    const split = direction === 'right' ? 'row' : direction === 'down' ? 'col' : null;
    const q = splitPane(findPane(split_from), split, { title: name, cwd, shell, pendingCommand: command }, false);
    return JSON.stringify({ id: q.id, name: q.title });
  },

  close_pane: ({ pane }) => {
    closePane(findPane(pane));
    return 'closed';
  },

  ask_agent: async ({ pane, message, timeout_seconds = 300 }, from) => {
    const p = findPane(pane);
    if (from === p) throw new Error('that is your own pane');
    if (!p.running) throw new Error('that pane has no running shell');
    if (!message) throw new Error('message is required');
    // A waits on B while B asks A would hang both until their timeouts.
    if (p.asking) throw new Error(`${p.title} is waiting on another agent itself; read_pane it or try later`);
    const secs = Math.min(Math.max(5, timeout_seconds | 0), 600);
    // In Claude a raw LF is a newline in the prompt; elsewhere a newline could submit early.
    const body = p.inClaude ? String(message).replace(/\r\n?/g, '\n') : String(message).replace(/\s*[\r\n]+\s*/g, ' ');
    if (from) from.asking = true;
    try {
      const stops = p.stopCount || 0, sentAt = Date.now();
      send({ type: 'input', pane_id: p.id, data: `[Valentine message from ${from ? from.title : 'an agent'}] ${body}` });
      await sleep(300); // some TUIs treat text and Enter arriving together as a paste
      send({ type: 'input', pane_id: p.id, data: '\r' });
      const deadline = sentAt + secs * 1000;
      for (;;) {
        await sleep(500);
        // Claude says when it is done; for other agents, output going quiet means done.
        const done = p.inClaude ? (p.stopCount || 0) > stops
          : p.lastOutputAt > sentAt + 1000 && Date.now() - p.lastOutputAt > AGENT_QUIET_MS;
        if (done) return screenText(p);
        if (!p.running) throw new Error('the shell in that pane exited');
        if (Date.now() > deadline) return `no answer within ${secs}s; current screen:\n${screenText(p)}`;
      }
    } finally {
      if (from) from.asking = false;
    }
  },
};

const sleep = ms => new Promise(r => setTimeout(r, ms));

function screenText(p, lines = 80) {
  const end = p.term.buffer.active.baseY + p.term.rows;
  return paneText(p, end - lines, end) || '(empty)';
}

// closePane keeps what reopenPane needs; the backend keeps the shell history until restart.
function closePane(p) {
  if (!p) return;
  cancelCountdown(p);
  closed.push({
    id: p.id, title: p.title, cwd: p.cwd, startup_cmd: p.cmd, autorun: p.autorun, shell: p.shell, claude: p.claude,
    buffer: p.ser ? p.ser.serialize({ scrollback: SAVED_SCROLLBACK }) : '', reopened: true,
  });
  if (closed.length > CLOSED_KEPT) closed.shift();
  flash(`Closed ${tabName(p)}  ·  Ctrl+Shift+T reopens it`);
  const at = panes.indexOf(p);
  send({ type: 'close', pane_id: p.id });
  p.ro?.disconnect();
  p.term?.dispose();
  p.el.remove();
  panes.splice(panes.indexOf(p), 1);
  tree = removeLeaf(tree, p.id);
  if (active === p) active = null;
  if (!tree) { // never leave the valentine empty
    const q = createPane({});
    panes.push(q);
    tree = leaf(q.id);
    relayout();
    start(q);
    return focusPane(q);
  }
  relayout();
  focusPane(panes[Math.min(at, panes.length - 1)]); // the neighbour, not wherever pane 1 is
}

// reopenPane brings back the last closed pane beside the active one: same id (so its shell
// history), name, folder, shell, scrollback and Claude session, with a fresh shell.
function reopenPane() {
  const r = closed.pop();
  if (r) splitPane(active || panes[0], 'row', r);
}

function applyPreset(name) {
  const pr = PRESETS[name], fresh = [];
  while (panes.length < pr.n) {
    const p = createPane({});
    panes.push(p);
    fresh.push(p);
  }
  unmaximize();
  tree = pr.build([...leaves(tree || leaf(panes[0].id)), ...fresh.map(p => p.id)].filter((id, i, a) => a.indexOf(id) === i));
  relayout();
  fresh.forEach(start);
}

// moveFocus picks the nearest pane whose box lies wholly in direction (dx, dy).
function moveFocus(dx, dy) {
  if (!active || active.el.classList.contains('max')) return;
  const r = active.el.getBoundingClientRect(), cx = r.left + r.width / 2, cy = r.top + r.height / 2;
  let best = null, bestD = Infinity;
  for (const p of panes) {
    if (p === active) continue;
    const q = p.el.getBoundingClientRect();
    const inDir = dx > 0 ? q.left >= r.right - 2 : dx < 0 ? q.right <= r.left + 2
      : dy > 0 ? q.top >= r.bottom - 2 : q.bottom <= r.top + 2;
    const d = Math.hypot(q.left + q.width / 2 - cx, q.top + q.height / 2 - cy);
    if (inDir && d < bestD) { best = p; bestD = d; }
  }
  if (best) focusPane(best);
}

// nudge moves the nearest divider of the given orientation around the active pane.
function nudge(split, delta) {
  const node = active && pathTo(tree, active.id)?.reverse().find(n => n.split === split);
  if (!node) return;
  node.ratio = clampRatio(node.ratio + delta);
  render();
  saveLayout();
}

function toggleMax(p) {
  if (!p) return;
  const on = !p.el.classList.contains('max');
  unmaximize();
  p.el.classList.toggle('max', on);
  p.term?.focus();
}
function unmaximize() {
  panes.forEach(p => p.el.classList.remove('max'));
}

// ---- menu and inline editor -------------------------------------------------

function openMenu(p, x, y) {
  // Git commands are typed into the shell, so only a shell idle at its prompt gets them.
  const git = p.branch && p.running && p.integrated && !p.busySince && !p.inClaude;
  closeMenu();
  const item = (text, kbd, fn) => {
    const b = el('button', '', { onclick: () => { closeMenu(); fn(); } });
    b.append(el('span', '', { textContent: text }), el('span', 'kbd', { textContent: kbd }));
    return b;
  };
  const sep = () => el('hr');
  const chips = (caption, options, current, pick) => {
    const row = el('div', 'chips');
    row.append(el('span', '', { textContent: caption }));
    for (const [value, text] of options) {
      row.append(el('button', value === current ? 'on' : '', { textContent: text, onclick: () => { closeMenu(); pick(value); } }));
    }
    return row;
  };
  menu = el('div', 'menu', { role: 'menu' });
  menu.append(
    item('Split right', 'Alt+Shift+=', () => splitPane(p, 'row')),
    item('Split down', 'Alt+Shift+-', () => splitPane(p, 'col')),
    sep(),
    ...(p.term.hasSelection() ? [item('Copy', 'Ctrl+C', () => navigator.clipboard.writeText(p.term.getSelection()))] : []),
    item('Paste', 'Ctrl+V', () => navigator.clipboard.readText().then(t => p.term.paste(t)).catch(() => {})),
    sep(),
    ...[...p.servers].map(url => item(`Open ${url.replace(/^https?:\/\//, '')}`, '', () => openUrl(url))),
    ...(p.servers.size ? [sep()] : []),
    ...(git ? [
      item('Git pull', '', () => typeCommand(p, 'git pull')),
      item('Git merge…', '', () => editField(p, 'Branch to merge into the current one, e.g. origin/main', '',
        v => v && typeCommand(p, `git merge ${v}`), false)),
      sep(),
    ] : []),
    item('Rename…', 'Double-click', () => rename(p)),
    item('Startup command…', '', () => editStartup(p)),
    item(`${p.autorun ? '✓ ' : ''}Auto-run after restore`, '', () => { p.autorun = !p.autorun; changed(p); }),
    chips('Shell', shells.map(s => [s, SHELL_NAMES[s] || s]), p.shell || shells[0], s => setShell(p, s)),
    sep(),
    item(p.el.classList.contains('max') ? 'Restore size' : 'Maximize', 'Ctrl+Shift+Enter', () => toggleMax(p)),
    chips('Layout', Object.keys(PRESETS).map(n => [n, n]), null, applyPreset),
    sep(),
    item(`${autostart ? '✓ ' : ''}Start at login`, '', () => {
      autostart = !autostart;
      send({ type: 'autostart', enabled: autostart });
    }),
    ...(closed.length ? [item('Reopen closed pane', 'Ctrl+Shift+T', reopenPane)] : []),
    item('Close pane', 'Ctrl+Shift+W', () => closePane(p)),
  );
  document.body.append(menu);
  const r = menu.getBoundingClientRect();
  menu.style.left = Math.min(x, innerWidth - r.width - 8) + 'px';
  menu.style.top = Math.min(y, innerHeight - r.height - 8) + 'px';
  menu.querySelector('button').focus();
  menu.onkeydown = e => {
    const items = [...menu.querySelectorAll('button')], i = items.indexOf(document.activeElement);
    if (e.key === 'ArrowDown') items[(i + 1) % items.length].focus();
    else if (e.key === 'ArrowUp') items[(i - 1 + items.length) % items.length].focus();
    else return;
    e.preventDefault();
  };
}
function closeMenu() {
  menu?.remove();
  menu = null;
}

function changed(p) {
  showLabel(p);
  meta(p);
}

function rename(p) {
  editField(p, 'Pane name', p.title, v => { p.title = v || p.title; changed(p); });
}
function editStartup(p) {
  editField(p, 'Startup command, runs after a restore when auto-run is on', p.cmd, v => {
    if (v && !p.cmd) p.autorun = true; // a newly set command is wanted on restore
    p.cmd = v;
    changed(p);
  });
}

// saveOnBlur false: clicking away cancels, for fields that run something.
function editField(p, caption, value, onSave, saveOnBlur = true) {
  editing?.cancel();
  const box = el('div', 'edit');
  const input = el('input', '', { type: 'text', value, spellcheck: false });
  box.append(el('label', '', { textContent: caption }), input);
  p.el.append(box);
  const finish = ok => {
    if (editing?.box !== box) return;
    editing = null;
    box.remove();
    if (ok) onSave(input.value.trim());
    p.term.focus();
  };
  editing = { box, cancel: () => finish(false) };
  input.onkeydown = e => {
    if (e.key === 'Enter') finish(true);
    else if (e.key === 'Escape') finish(false);
  };
  input.onblur = () => finish(saveOnBlur);
  input.focus();
  input.select();
}

// ---- title bar --------------------------------------------------------------

const isMax = p => p.el.classList.contains('max');
// A default "Terminal 3" says less than the folder it is in.
const tabName = p => (/^Terminal \d+$/.test(p.title) && p.cwd ? p.cwd.split(/[\\/]/).filter(Boolean).at(-1) || p.cwd : p.title);

function renderTabs() {
  $('#tabs').replaceChildren(...panes.map(p => {
    const t = el('button', 'tab' + (p === active ? ' on' : ''), { title: p.labelText.textContent, onclick: () => pickPane(p) });
    const status = p.badge.classList[1];
    if (status) t.append(el('i', 'dot ' + status));
    t.append(tabName(p));
    return t;
  }));
}

// pickPane focuses p; with a pane maximized, p takes its place, like switching tabs.
function pickPane(p) {
  if (panes.some(isMax) && !isMax(p)) toggleMax(p);
  focusPane(p);
}

// winOp asks the native window for a title-bar action (see window.h) and refreshes the
// maximized state it answers with. Op 0 only asks.
function winOp(op) {
  nativeWindow?.(op).then(z => {
    zoomed = !!z;
    document.body.classList.toggle('zoomed', zoomed);
    $('#maxBtn').innerHTML = zoomed ? '&#xE923;' : '&#xE922;';
    $('#maxBtn').title = zoomed ? 'Restore' : 'Maximize';
  });
}

let lastBarDown = 0;
function barDown(e) {
  if (e.button !== 0 || e.target.closest('button, input, #results')) return;
  e.preventDefault();
  // Windows' move loop swallows the mouse-up, so the page never sees a dblclick.
  const now = Date.now();
  if (now - lastBarDown < 400) {
    lastBarDown = 0;
    return winOp(2);
  }
  lastBarDown = now;
  winOp(4);
}
