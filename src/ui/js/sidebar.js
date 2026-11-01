// ---- sidebar ----------------------------------------------------------------

function toggleSide(open = !$('#side').classList.contains('open'), tab) {
  const side = $('#side');
  if (tab) showSideTab(tab);
  side.classList.toggle('open', open);
  side.inert = !open;
  $('#sideBtn').classList.toggle('on', open);
  if (open) side.querySelector('section:not([hidden]) :is(textarea, input)')?.focus();
  else active?.term?.focus();
}

function showSideTab(tab) {
  for (const n of document.querySelectorAll('#side [data-tab]')) {
    if (n.tagName === 'SECTION') n.hidden = n.dataset.tab !== tab;
    else n.classList.toggle('on', n.dataset.tab === tab);
  }
  if (tab === 'feeds' && !feedCache[feedPick.value]) loadFeed();
  if (tab === 'ports') loadPorts();
}

let notesTimer = 0;
function saveNotes() {
  clearTimeout(notesTimer);
  notesTimer = 0;
  send({ type: 'config', name: 'notes', value: $('#notes').value });
}

function renderShortcuts() {
  const list = $('#shortcutList');
  if (!shortcuts.length) {
    return list.replaceChildren(el('div', 'empty', { textContent: 'Servers you SSH into, commands you run often. Each opens in a new pane.' }));
  }
  list.replaceChildren(...shortcuts.map((s, i) => {
    const run = () => runShortcut(s);
    const row = el('div', 'item', { tabIndex: 0, title: 'Open in a new pane', onclick: run, onkeydown: e => e.key === 'Enter' && run() });
    const text = el('div');
    text.append(el('b', '', { textContent: s.name }), el('code', '', { textContent: s.command }));
    row.append(text, el('button', '', {
      textContent: '✕', title: 'Remove', ariaLabel: `Remove ${s.name}`,
      onclick: e => { e.stopPropagation(); shortcuts.splice(i, 1); saveShortcuts(); },
    }));
    return row;
  }));
}

function saveShortcuts() {
  send({ type: 'config', name: 'shortcuts', value: JSON.stringify(shortcuts) });
  renderShortcuts();
}

function runShortcut(s) {
  toggleSide(false);
  splitPane(active || panes[0], null, { title: s.name, cwd: s.cwd || '', pendingCommand: s.command });
}

// applyTheme sets theme `name` with the user's colour overrides on top.
function applyTheme(name, persist = true) {
  theme = name;
  const base = THEMES[name], { accent = base.accent, ...over } = colors, css = document.documentElement.style;
  termTheme = { ...base.term, ...over };
  css.setProperty('--bg', termTheme.background);
  css.setProperty('--fg', termTheme.foreground);
  css.setProperty('--accent', accent);
  panes.forEach(p => { if (p.term) p.term.options.theme = termTheme; });
  if (persist) send({ type: 'config', name: 'theme', value: name });
}

// pickTheme switches to a preset and drops the colour overrides made on the old one.
function pickTheme(name) {
  colors = {};
  send({ type: 'config', name: 'colors', value: '{}' });
  applyTheme(name);
  renderLook();
}

const COLOR_KEYS = [['accent', 'Accent'], ['background', 'Background'], ['foreground', 'Text'], ['cursor', 'Cursor'],
  ...ANSI.map(c => [c, c[0].toUpperCase() + c.slice(1)]),
  ...ANSI.map(c => ['bright' + c[0].toUpperCase() + c.slice(1), 'Bright ' + c])];

function renderLook() {
  const now = { accent: THEMES[theme].accent, ...termTheme, ...colors };
  $('#colorList').replaceChildren(...COLOR_KEYS.map(([k, text]) => {
    const input = el('input', '', { type: 'color', value: now[k] });
    input.oninput = () => { colors[k] = input.value; applyTheme(theme, false); };
    input.onchange = () => send({ type: 'config', name: 'colors', value: JSON.stringify(colors) });
    const row = el('label', 'color');
    row.append(input, text);
    return row;
  }));
  $('#themeList').replaceChildren(...Object.entries(THEMES).map(([n, s]) => {
    const b = el('button', 'theme' + (n === theme ? ' on' : ''), { onclick: () => pickTheme(n) });
    const swatch = el('span', 'swatch');
    for (const c of ['background', 'foreground', 'red', 'green', 'yellow', 'blue', 'magenta']) {
      swatch.append(el('i', '', { style: `background: ${s.term[c]}` }));
    }
    b.append(el('span', '', { textContent: n }), swatch);
    return b;
  }));
}

// parseList reads a stored JSON config value, falling back when it is missing or broken.
function parseList(json, fallback) {
  if (!json) return fallback;
  try { return JSON.parse(json) ?? fallback; } catch { return fallback; }
}

// ---- backend fetch: the page cannot read other origins (feeds, worf) itself ----

const fetches = new Map();
let fetchSeq = 0;

// backendFetch has the backend make a request; body64 is the request body in base64.
function backendFetch(url, { method = 'GET', headers = {}, body64 = '' } = {}) {
  const req_id = 'f' + ++fetchSeq;
  send({ type: 'fetch', req_id, url, method, headers: JSON.stringify(headers), data: body64 });
  return new Promise((resolve, reject) => {
    fetches.set(req_id, { resolve, reject });
    setTimeout(() => fetches.delete(req_id) && reject(new Error('no answer in 30 s')), 30000);
  });
}

// ask sends msg with a fresh req_id and resolves with the backend's answer, { error }
// on failure, or null when none comes within ms (e.g. while reconnecting).
function ask(msg, ms = 1000) {
  const req_id = 'q' + ++fetchSeq;
  send({ ...msg, req_id });
  return new Promise(resolve => {
    fetches.set(req_id, { resolve, reject: e => resolve({ error: e.message }) });
    setTimeout(() => fetches.delete(req_id) && resolve(null), ms);
  });
}

function onFetched(m) {
  const f = fetches.get(m.req_id);
  if (!f) return;
  fetches.delete(m.req_id);
  if (m.error) f.reject(new Error(m.error)); else f.resolve(m);
}

const ago = when => {
  const s = (Date.now() - new Date(when)) / 1000;
  if (!(s >= 0)) return '';
  return s < 3600 ? `${Math.max(1, s / 60 | 0)}m ago` : s < 86400 ? `${s / 3600 | 0}h ago` : `${s / 86400 | 0}d ago`;
};
const host = url => { try { return new URL(url).host.replace(/^www\./, ''); } catch { return ''; } };
const openUrl = url => /^https?:\/\//.test(url) && send({ type: 'open', url });

// ---- feeds ------------------------------------------------------------------

const DEFAULT_FEEDS = [{ name: 'Hacker News', url: 'https://news.ycombinator.com/rss' }];
const feedPick = $('#feedPick'), feedCache = {};
let feeds = [];

function parseFeed(xml) {
  const doc = new DOMParser().parseFromString(xml, 'text/xml');
  if (doc.querySelector('parsererror') || !doc.querySelector('rss, feed, RDF')) throw new Error('not an RSS or Atom feed');
  const text = (n, sel) => n.querySelector(sel)?.textContent.trim() || '';
  return {
    title: text(doc, 'channel > title') || text(doc, 'feed > title'),
    items: [...doc.querySelectorAll('item, entry')].slice(0, 60).map(n => ({
      title: text(n, 'title'),
      link: text(n, 'link') || n.querySelector('link')?.getAttribute('href') || '',
      date: text(n, 'pubDate') || text(n, 'updated') || text(n, 'published'),
      comments: text(n, 'comments'),
    })),
  };
}

function renderFeedPick() {
  feedPick.replaceChildren(...feeds.map(f => el('option', '', { value: f.url, textContent: f.name || host(f.url) })));
  $('#feedRemove').disabled = !feeds.length;
  if (!feeds.length) $('#feedItems').replaceChildren(el('div', 'empty', { textContent: 'No feeds yet. Add one below.' }));
}

async function loadFeed() {
  const url = feedPick.value, box = $('#feedItems');
  if (!url) return;
  box.replaceChildren(el('div', 'empty', { textContent: 'Loading…' }));
  try {
    const r = await backendFetch(url);
    if (r.status !== 200) throw new Error(`HTTP ${r.status}`);
    feedCache[url] = parseFeed(r.body);
  } catch (e) {
    if (feedPick.value === url) box.replaceChildren(el('div', 'msg err', { textContent: `Could not load: ${e.message}` }));
    return;
  }
  if (feedPick.value === url) showFeed(feedCache[url]);
}

function showFeed(feed) {
  $('#feedItems').replaceChildren(...feed.items.map(it => {
    const row = el('div', 'item', { tabIndex: 0, title: it.title, onclick: () => openUrl(it.link), onkeydown: e => e.key === 'Enter' && openUrl(it.link) });
    const text = el('div');
    text.append(el('b', '', { textContent: it.title }), el('code', '', { textContent: [host(it.link), ago(it.date)].filter(Boolean).join(' · ') }));
    row.append(text);
    if (it.comments && it.comments !== it.link) {
      row.append(el('button', '', { textContent: 'comments', onclick: e => { e.stopPropagation(); openUrl(it.comments); } }));
    }
    return row;
  }));
}

function saveFeeds() {
  send({ type: 'config', name: 'feeds', value: JSON.stringify(feeds) });
  renderFeedPick();
}

feedPick.onchange = () => (feedCache[feedPick.value] ? showFeed(feedCache[feedPick.value]) : loadFeed());
$('#feedReload').onclick = loadFeed;
$('#feedRemove').onclick = () => {
  const f = feeds.find(f => f.url === feedPick.value);
  if (!f || !confirm(`Remove the feed "${f.name}"?`)) return;
  feeds.splice(feeds.indexOf(f), 1);
  saveFeeds();
  if (feeds.length) feedPick.onchange();
};
$('#feedForm').onsubmit = async e => {
  e.preventDefault();
  const url = e.target.elements.namedItem('url').value.trim();
  if (feeds.some(f => f.url === url)) return;
  const status = el('div', 'empty', { textContent: 'Checking the feed…' });
  e.target.append(status);
  try {
    const r = await backendFetch(url);
    if (r.status !== 200) throw new Error(`HTTP ${r.status}`);
    feedCache[url] = parseFeed(r.body);
  } catch (err) {
    status.className = 'msg err';
    status.textContent = `Not added: ${err.message}`;
    return;
  }
  status.remove();
  e.target.reset();
  feeds.push({ name: feedCache[url].title || host(url), url });
  saveFeeds();
  feedPick.value = url;
  showFeed(feedCache[url]);
};

// ---- password vault: AES-GCM under a key derived from the master password -------
// Windows' credential store is not used (it loses its keys on some machines). The
// key lives only in memory while unlocked; the stored blob is { salt, iv, data }.

const VAULT_IDLE_MS = 10 * 60 * 1000;
const vault = { stored: null, key: null, items: [], timer: 0 };
const b64 = buf => { let s = ''; for (const b of new Uint8Array(buf)) s += String.fromCharCode(b); return btoa(s); };
const unb64 = s => Uint8Array.from(atob(s), c => c.charCodeAt(0));

async function vaultKey(password, salt) {
  const base = await crypto.subtle.importKey('raw', new TextEncoder().encode(password), 'PBKDF2', false, ['deriveKey']);
  return crypto.subtle.deriveKey({ name: 'PBKDF2', salt, iterations: 600000, hash: 'SHA-256' },
    base, { name: 'AES-GCM', length: 256 }, false, ['encrypt', 'decrypt']);
}

async function sealVault() {
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const data = await crypto.subtle.encrypt({ name: 'AES-GCM', iv }, vault.key, new TextEncoder().encode(JSON.stringify(vault.items)));
  vault.stored = { v: 1, salt: vault.stored.salt, iv: b64(iv), data: b64(data) };
  send({ type: 'config', name: 'vault', value: JSON.stringify(vault.stored) });
}

async function unlockVault(password) {
  const key = await vaultKey(password, unb64(vault.stored.salt));
  const plain = await crypto.subtle.decrypt({ name: 'AES-GCM', iv: unb64(vault.stored.iv) }, key, unb64(vault.stored.data));
  vault.key = key; // decrypt throws on a wrong password, so we only get here with the right one
  vault.items = JSON.parse(new TextDecoder().decode(plain));
}

function lockVault() {
  clearTimeout(vault.timer);
  vault.key = null;
  vault.items = [];
  renderVault();
}

function touchVault() {
  clearTimeout(vault.timer);
  vault.timer = setTimeout(lockVault, VAULT_IDLE_MS);
}

// copySecret puts text on the clipboard and clears it after 30 s if it is still there.
function copySecret(text) {
  touchVault();
  navigator.clipboard.writeText(text).then(() => setTimeout(() => {
    navigator.clipboard.readText().then(t => t === text && navigator.clipboard.writeText('')).catch(() => {});
  }, 30000)).catch(() => {});
}

function vaultForm(caption, fields, submit, onSubmit) {
  const f = el('form', 'add');
  const msg = el('div', 'msg err');
  f.append(el('h4', '', { textContent: caption }),
    ...fields.map(([name, placeholder, type = 'text']) => el('input', '', { name, placeholder, type, autocomplete: 'off', required: name !== 'user' })),
    msg, el('button', '', { textContent: submit }));
  f.onsubmit = async e => {
    e.preventDefault();
    const v = Object.fromEntries(fields.map(([name]) => [name, f.elements.namedItem(name).value]));
    f.querySelector('button').disabled = true;
    try { await onSubmit(v, f); } catch (err) { msg.textContent = err.message; }
    f.querySelector('button').disabled = false;
  };
  return f;
}

function renderVault() {
  const box = $('section[data-tab="vault"]');
  if (!vault.stored) {
    return box.replaceChildren(
      el('div', 'empty', { textContent: 'Passwords are encrypted with a master password you set here. Valentine cannot recover them if you forget it.' }),
      vaultForm('Create the vault', [['pw', 'Master password (at least 10 characters)', 'password'], ['again', 'Repeat it', 'password']], 'Create', async v => {
        if (v.pw.length < 10) throw new Error('Use at least 10 characters.');
        if (v.pw !== v.again) throw new Error('The two passwords differ.');
        const salt = crypto.getRandomValues(new Uint8Array(16));
        vault.stored = { salt: b64(salt) };
        vault.key = await vaultKey(v.pw, salt);
        vault.items = [];
        await sealVault();
        touchVault();
        renderVault();
      }));
  }
  if (!vault.key) {
    const f = vaultForm('Locked', [['pw', 'Master password', 'password']], 'Unlock', async v => {
      try { await unlockVault(v.pw); } catch { throw new Error('Wrong master password.'); }
      touchVault();
      renderVault();
    });
    box.replaceChildren(f);
    return f.querySelector('input').focus();
  }
  const list = vault.items.map((it, i) => {
    const row = el('div', 'item');
    const text = el('div');
    text.append(el('b', '', { textContent: it.name }), el('code', '', { textContent: it.user || '—' }));
    const btn = (label, title, fn) => el('button', '', { textContent: label, title, onclick: fn });
    row.append(text,
      ...(it.user ? [btn('user', 'Copy the user name', () => copySecret(it.user))] : []),
      btn('copy', 'Copy the password (cleared from the clipboard after 30 s)', () => copySecret(it.secret)),
      btn('type', 'Type the password into the focused pane, without Enter', () => {
        touchVault();
        if (active?.running) send({ type: 'input', pane_id: active.id, data: it.secret });
        active?.term?.focus();
      }),
      btn('✕', 'Delete', async () => {
        if (!confirm(`Delete "${it.name}"?`)) return;
        vault.items.splice(i, 1);
        await sealVault();
        touchVault();
        renderVault();
      }));
    return row;
  });
  box.replaceChildren(
    el('div', 'row', {}),
    ...(list.length ? list : [el('div', 'empty', { textContent: 'Empty. Add a password below.' })]),
    vaultForm('Add a password', [['name', 'Name, e.g. worf root'], ['user', 'User (optional)'], ['secret', 'Password', 'password']], 'Add', async (v, f) => {
      vault.items.push({ name: v.name.trim(), user: v.user.trim(), secret: v.secret });
      await sealVault();
      touchVault();
      f.reset();
      renderVault();
    }));
  box.firstChild.append(el('span', 'empty', { textContent: `${list.length} saved`, style: 'flex: 1' }),
    el('button', 'icon', { textContent: 'Lock', style: 'width: auto; padding: 0 8px', onclick: lockVault }));
}

// ---- worf: is anything on the servers broken? -----------------------------------

const WORF_POLL_MS = 60 * 1000;
let worf = {}, worfTimer = 0;

async function pollWorf() {
  clearTimeout(worfTimer);
  const btn = $('#worfBtn'), body = $('#worfBody'), dot = btn.querySelector('.dot');
  btn.hidden = !worf.token;
  if (!worf.token) {
    $('#worfSetup').open = true;
    return body.replaceChildren(el('div', 'empty', { textContent: 'Create an API token in worf and paste it under Connection; Valentine then checks alerts and site probes every minute.' }));
  }
  worfTimer = setTimeout(pollWorf, WORF_POLL_MS);
  const get = async path => {
    const r = await backendFetch(worf.url.replace(/\/+$/, '') + path, { headers: { Authorization: 'Bearer ' + worf.token } });
    if (r.status === 401 || r.status === 403) throw new Error('worf rejected the token');
    if (r.status !== 200) throw new Error(`HTTP ${r.status} from ${path}`);
    return JSON.parse(r.body);
  };
  let alerts, probes;
  try {
    [alerts, probes] = await Promise.all([get('/api/admin/alerts'), get('/api/admin/probes')]);
  } catch (e) {
    dot.className = 'dot fail';
    btn.title = `worf: ${e.message}`;
    return body.replaceChildren(el('div', 'msg err', { textContent: e.message }));
  }
  const open = (alerts.open || []).filter(a => !a.muted);
  const down = Object.entries(probes || {}).filter(([, p]) => p && !p.ok);
  const crit = open.filter(a => a.severity === 'critical').length + down.length;
  const warn = open.filter(a => a.severity === 'warning').length;
  const [level, word] = crit ? ['fail', `${crit} critical`] : warn ? ['running', `${warn} warning${warn > 1 ? 's' : ''}`] : ['done', 'All good'];
  dot.className = 'dot ' + level;
  btn.title = `worf: ${word}`;
  const verdict = el('div', 'verdict');
  verdict.append(el('i', 'dot ' + level), word);
  body.replaceChildren(verdict,
    ...down.map(([site, p]) => row('crit', site, p.error || `HTTP ${p.status}`)),
    ...open.map(a => row(a.severity === 'critical' ? 'crit' : a.severity === 'warning' ? 'warn' : '', a.title, [a.detail, ago(a.started_at)].filter(Boolean).join(' · '))),
    el('button', '', { textContent: 'Open worf', className: 'theme', onclick: () => openUrl(worf.url) }),
    el('div', 'empty', { textContent: `Checked ${new Date().toLocaleTimeString()}` }));
  function row(cls, title, detail) {
    const r = el('div', 'item ' + cls), t = el('div');
    t.append(el('b', '', { textContent: title }), el('code', '', { textContent: detail }));
    r.append(t);
    return r;
  }
}

$('#worfBtn').onclick = () => toggleSide(true, 'worf');
// Settings save as they change, like every other setting.
$('#worfForm').onchange = () => {
  const f = $('#worfForm').elements;
  worf = { url: f.namedItem('url').value.trim(), token: f.namedItem('token').value.trim() };
  send({ type: 'config', name: 'worf', value: JSON.stringify(worf) });
  pollWorf();
};
$('#worfForm').onsubmit = e => { e.preventDefault(); $('#worfForm').onchange(); };

// ---- webhooks: caught by the relay on the server (relay/relay.py), pulled here ----

const RELAY_POLL_MS = 5000, HOOKS_KEPT = 100;
// Headers that describe the hop to the relay, not the webhook itself.
const HOP_HEADERS = new Set(['host', 'content-length', 'connection', 'x-real-ip', 'x-forwarded-for',
  'x-forwarded-proto', 'accept-encoding', 'transfer-encoding']);
let relay = {}, relayTimer = 0, relayAfter = 0, relayError = '';
const hooks = [], openHooks = new Set(); // newest first; ids shown expanded

async function pollRelay() {
  clearTimeout(relayTimer);
  if (!relay.token) {
    $('#hookSetup').open = true;
    return renderHooks();
  }
  let changed = false;
  try {
    const r = await backendFetch(`${relay.url.replace(/\/+$/, '')}/api/events?after=${relayAfter}`,
      { headers: { Authorization: 'Bearer ' + relay.token } });
    if (r.status === 401) throw new Error('the relay rejected the token');
    if (r.status !== 200) throw new Error(`HTTP ${r.status} from the relay`);
    const backlog = relayAfter === 0; // caught before this start: shown, not replayed
    for (const ev of JSON.parse(r.body)) {
      relayAfter = Math.max(relayAfter, ev.id);
      hooks.unshift(ev);
      changed = true;
      if (relay.forward && !backlog) forwardHook(ev);
    }
    hooks.splice(HOOKS_KEPT);
    changed ||= relayError !== '';
    relayError = '';
  } catch (e) {
    changed = relayError !== e.message;
    relayError = e.message;
  }
  if (changed) renderHooks();
  relayTimer = setTimeout(pollRelay, RELAY_POLL_MS);
}

// forwardHook replays a caught webhook to the local URL, with its method, headers
// (signatures included) and body, so a dev server sees what the service sent.
async function forwardHook(ev) {
  const headers = Object.fromEntries(ev.headers.filter(([k]) => !HOP_HEADERS.has(k.toLowerCase())));
  const url = relay.forward + (ev.query ? (relay.forward.includes('?') ? '&' : '?') + ev.query : '');
  ev.forward = '→ sending…';
  renderHooks();
  try {
    const r = await backendFetch(url, { method: ev.method, headers, body64: ev.body });
    ev.forward = `→ ${r.status}`;
  } catch (e) {
    ev.forward = `→ failed: ${e.message}`;
  }
  renderHooks();
}

function hookText(ev) {
  let body = new TextDecoder().decode(unb64(ev.body)); // binary bodies show replacement characters
  try { body = JSON.stringify(JSON.parse(body), null, 2); } catch { /* not JSON */ }
  return [`${ev.method} ${ev.path}${ev.query ? '?' + ev.query : ''}`, ...ev.headers.map(([k, v]) => `${k}: ${v}`), '', body].join('\n');
}

function renderHooks() {
  const box = $('#hookList');
  if (!relay.token) {
    return box.replaceChildren(el('div', 'empty', { textContent: 'Webhooks sent to the relay on your server show up here. Set its token under Relay.' }));
  }
  const head = relayError ? [el('div', 'msg err', { textContent: relayError })] : [];
  if (!hooks.length) {
    return box.replaceChildren(...head, el('div', 'empty', { textContent: 'Nothing caught yet. Name a hook above, copy its URL and give it to the service.' }));
  }
  box.replaceChildren(...head, ...hooks.map(ev => {
    const toggle = () => { if (!openHooks.delete(ev.id)) openHooks.add(ev.id); renderHooks(); };
    const row = el('div', 'item', { tabIndex: 0, style: 'flex-wrap: wrap', onclick: toggle, onkeydown: e => e.key === 'Enter' && toggle() });
    const text = el('div');
    text.append(el('b', '', { textContent: `${ev.method} ${ev.name}` }),
      el('code', '', { textContent: [ago(ev.at * 1000), ev.ip, ev.forward].filter(Boolean).join(' · ') }));
    row.append(text);
    if (relay.forward) {
      row.append(el('button', '', { textContent: 'resend', title: `Send again to ${relay.forward}`, onclick: e => { e.stopPropagation(); forwardHook(ev); } }));
    }
    if (openHooks.has(ev.id)) {
      row.append(el('pre', '', { textContent: hookText(ev), style: 'flex-basis: 100%', onclick: e => e.stopPropagation() }));
    }
    return row;
  }));
}

$('#hookCopy').onclick = () => {
  const name = $('#hookName').value.trim().replace(/[^\w.-]+/g, '-') || 'test';
  navigator.clipboard.writeText(`${relay.url.replace(/\/+$/, '')}/h/${name}`).catch(() => {});
  $('#hookCopy').textContent = 'Copied';
  setTimeout(() => { $('#hookCopy').textContent = 'Copy URL'; }, 1500);
};
$('#hookForm').onsubmit = e => { e.preventDefault(); $('#hookForm').onchange(); };
$('#hookForm').onchange = () => {
  const f = $('#hookForm').elements;
  relay = { url: f.namedItem('url').value.trim(), token: f.namedItem('token').value.trim(), forward: f.namedItem('forward').value.trim() };
  send({ type: 'config', name: 'relay', value: JSON.stringify(relay) });
  relayAfter = 0;
  hooks.length = 0;
  pollRelay();
};

// ---- ports --------------------------------------------------------------------

async function loadPorts() {
  const box = $('#portList');
  if (!box.childElementCount) box.replaceChildren(el('div', 'empty', { textContent: 'Looking…' }));
  const r = await ask({ type: 'ports' }, 10000);
  if (!r || r.error) return box.replaceChildren(el('div', 'msg err', { textContent: r?.error || 'no answer' }));
  const rows = JSON.parse(r.body || '[]');
  if (!rows.length) return box.replaceChildren(el('div', 'empty', { textContent: 'Nothing is listening.' }));
  box.replaceChildren(...rows.map(({ port, pid, name }) => {
    // The pane whose command printed this port, if any.
    const owner = panes.find(p => [...p.servers].some(u => u.endsWith(':' + port)));
    const text = el('div');
    text.append(el('b', '', { textContent: `:${port}  ${name || '?'}` }),
      el('code', '', { textContent: [`pid ${pid}`, owner && tabName(owner)].filter(Boolean).join(' · ') }));
    const kill = el('button', '', { textContent: 'kill', title: `End ${name || 'pid ' + pid}` });
    kill.onclick = async () => {
      if (kill.textContent === 'kill') { kill.textContent = 'sure?'; return; } // two clicks: it ends a process
      kill.textContent = '…';
      const res = await ask({ type: 'kill_pid', pid }, 10000);
      flash(res?.error ? `Could not end ${name || pid}: ${res.error}` : `Ended ${name || pid}`);
      loadPorts();
    };
    const row = el('div', 'item');
    row.append(text, el('button', '', { textContent: 'open', title: `http://localhost:${port}`, onclick: () => openUrl(`http://localhost:${port}`) }), kill);
    return row;
  }));
}
$('#portsReload').onclick = loadPorts;

// ---- HTTP request -------------------------------------------------------------

const HTTP_SHOW = 200000; // characters drawn: a <pre> with megabytes of text is slow to lay out
$('#httpForm').onsubmit = async e => {
  e.preventDefault();
  const f = e.target.elements, req = {};
  for (const k of ['method', 'url', 'headers', 'body']) req[k] = f.namedItem(k).value;
  send({ type: 'config', name: 'http', value: JSON.stringify(req) });
  const headers = parseHeaders(req.headers);
  const meta = $('#httpMeta'), out = $('#httpOut'), t0 = performance.now();
  meta.className = 'msg';
  meta.textContent = 'Sending…';
  try {
    const r = await backendFetch(req.url.trim(), {
      method: req.method, headers, body64: req.body ? b64(new TextEncoder().encode(req.body)) : '',
    });
    let body = r.body || '';
    meta.textContent = `${r.status}  ·  ${Math.round(performance.now() - t0)} ms  ·  ${(body.length / 1024).toFixed(1)} KB`;
    if (r.status >= 400) meta.className = 'msg err';
    if (body.length < HTTP_SHOW) try { body = JSON.stringify(JSON.parse(body), null, 2); } catch { /* not JSON */ }
    out.textContent = body.length > HTTP_SHOW ? body.slice(0, HTTP_SHOW) + '\n… (cut, the rest is not shown)' : body;
    out.hidden = !body;
  } catch (err) {
    meta.className = 'msg err';
    meta.textContent = err.message;
    out.hidden = true;
  }
};
