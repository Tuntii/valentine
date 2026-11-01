module main

import encoding.base64
import json
import net.http
import net.websocket
import os
import sync
import time

// Everything the UI needs is compiled in: after a power cut there may be no network.
const index_html = $embed_file('ui/index.html')
const app_css = $embed_file('ui/app.css')
// One script from several files: they share a scope, as if they were one file.
const app_js = [$embed_file('ui/js/tree.js'), $embed_file('ui/js/core.js'), $embed_file('ui/js/sidebar.js'),
	$embed_file('ui/js/main.js')].map(it.to_string()).join('
')
const xterm_js = $embed_file('ui/vendor/xterm.js')
const xterm_css = $embed_file('ui/vendor/xterm.css')
const fit_js = $embed_file('ui/vendor/addon-fit.js')
const serialize_js = $embed_file('ui/vendor/addon-serialize.js')
const webgl_js = $embed_file('ui/vendor/addon-webgl.js')
const links_js = $embed_file('ui/vendor/addon-web-links.js')
const logo_png = $embed_file('../assets/valentine.png')

// ui_config is what the UI may store for itself (sidebar notes, shortcuts, theme);
// each value is opaque to the backend.
const ui_config = ['notes', 'shortcuts', 'theme', 'colors', 'start_dir', 'http', 'feeds', 'vault', 'worf', 'relay']

// InMsg is every UI -> backend message; each type uses a subset of the fields.
struct InMsg {
	kind        string @[json: 'type']
	pane_id     string
	data        string
	cols        int
	rows        int
	cwd         string
	title       string
	startup_cmd string
	autorun     bool
	shell       string
	slot        int
	layout      string
	url         string
	enabled     bool
	req_id      string // mcp_result: answers a UiRequest
	result      string
	name        string // config: one of ui_config
	value       string
	method      string // fetch: defaults to GET
	headers     string // fetch: a JSON object
	pid         int    // kill_pid
}

// UiRequest asks the window to do something only it can (read a terminal's screen,
// split a pane...); the window answers with an mcp_result carrying the same req_id.
struct UiRequest {
	kind    string @[json: 'type']
	req_id  string
	payload string
}

struct StateMsg {
	kind      string @[json: 'type']
	layout    string
	unclean   bool
	win_build int // xterm.js needs it to match ConPTY's reflow behaviour on resize
	autostart bool
	shells    []string
	panes     []PaneRow
	config    map[string]string
}

// FetchMsg answers a fetch: the page cannot read other origins (RSS, worf) itself.
struct FetchMsg {
	kind   string @[json: 'type']
	req_id string
mut:
	status int
	body   string
	error  string
}

struct ExitMsg {
	kind    string @[json: 'type']
	pane_id string
	code    int
}

@[heap]
struct App {
mut:
	store   &Storage
	data_dir string
	token   string
	unclean bool
	ptys    map[string]&Pty
	paused  map[string]bool // panes whose output the window asked to hold (flow control); under pty_mu
	pty_mu  &sync.Mutex       = sync.new_mutex()
	send_mu &sync.Mutex       = sync.new_mutex()
	client  &websocket.Client = unsafe { nil }
	req_mu   &sync.Mutex = sync.new_mutex()
	pending  map[string]chan string
	next_req int
}

struct PageHandler {
mut:
	app &App
}

fn (mut h PageHandler) handle(req http.Request) http.Response {
	path := req.url.all_before('?')
	if req.method == .post && path in ['/hook', '/call'] {
		// Called by `valentine hook` / `valentine mcp`, which read the token from session.json.
		token := req.header.get_custom('X-Valentine-Token') or { '' }
		if token != h.app.token {
			return http.new_response(status: .forbidden, body: 'bad token')
		}
		pane := req.header.get_custom('X-Valentine-Pane') or { '' }
		result := if path == '/hook' {
			h.app.on_hook(pane, req.data) or {
				return http.new_response(status: .bad_request, body: err.msg())
			}
		} else {
			h.app.ui_request(req.data, 620 * time.second) or { // ask_agent may wait 600 s
				return http.new_response(status: .bad_request, body: err.msg())
			}
		}
		return http.new_response(
			header: http.new_header(key: .content_type, value: 'application/json')
			body:   result
		)
	}
	body, ctype := asset(path) or {
		return http.new_response(status: .not_found, body: 'not found')
	}
	if req.method != .get {
		return http.new_response(status: .method_not_allowed, body: 'method not allowed')
	}
	return http.new_response(
		header: http.new_header(key: .content_type, value: ctype)
		body:   body
	)
}

fn asset(path string) ?(string, string) {
	js := 'text/javascript; charset=utf-8'
	match path {
		'/' { return index_html.to_string(), 'text/html; charset=utf-8' }
		'/app.js' { return app_js, js }
		'/app.css' { return app_css.to_string(), 'text/css; charset=utf-8' }
		'/vendor/xterm.js' { return xterm_js.to_string(), js }
		'/vendor/xterm.css' { return xterm_css.to_string(), 'text/css; charset=utf-8' }
		'/vendor/addon-fit.js' { return fit_js.to_string(), js }
		'/vendor/addon-serialize.js' { return serialize_js.to_string(), js }
		'/vendor/addon-webgl.js' { return webgl_js.to_string(), js }
		'/vendor/addon-web-links.js' { return links_js.to_string(), js }
		'/logo.png' { return logo_png.to_string(), 'image/png' }
		else { return none }
	}
}

fn (mut app App) serve_http(port int) {
	mut server := &http.Server{
		addr:    '127.0.0.1:${port}'
		handler: PageHandler{
			app: app
		}
	}
	server.listen_and_serve()
}

fn (mut app App) serve_ws(port int) {
	mut server := websocket.new_server(.ip, port, '')
	resource := '/?t=${app.token}'
	// The token gate keeps other local pages and processes from driving our shells.
	server.on_connect(fn [resource] (mut sc websocket.ServerClient) !bool {
		return sc.resource_name == resource
	}) or { panic(err) }
	server.on_message_ref(on_ws_message, app)
	server.on_close_ref(on_ws_close, app)
	server.listen() or { note('websocket server stopped: ${err}') }
}

fn on_ws_message(mut c websocket.Client, msg &websocket.Message, ref voidptr) ! {
	if msg.opcode != .text_frame {
		return
	}
	mut app := unsafe { &App(ref) }
	m := json.decode(InMsg, msg.payload.bytestr()) or { return }
	app.handle(mut c, m) or { note('${m.kind} ${m.pane_id}: ${err}') }
}

fn on_ws_close(mut c websocket.Client, _ int, _ string, ref voidptr) ! {
	mut app := unsafe { &App(ref) }
	app.send_mu.@lock()
	defer {
		app.send_mu.unlock()
	}
	if voidptr(app.client) == unsafe { voidptr(&c) } {
		app.client = unsafe { nil }
		note('window disconnected')
	}
}

fn (mut app App) handle(mut c websocket.Client, m InMsg) ! {
	if m.pane_id != '' && !valid_id(m.pane_id) {
		return error('bad pane_id') // ids end up in file names and PowerShell scripts
	}
	match m.kind {
		'hello' {
			app.attach(mut c)!
		}
		'spawn' {
			app.spawn_pane(m.pane_id, m.cols, m.rows)!
		}
		'input' {
			mut p := app.find_pty(m.pane_id) or { return }
			p.write(m.data)
		}
		'resize' {
			mut p := app.find_pty(m.pane_id) or { return }
			p.resize(m.cols, m.rows)
		}
		'save_buffer' {
			app.store.save_buffer(m.pane_id, m.data)!
		}
		'cwd_update' {
			app.store.save_cwd(m.pane_id, m.cwd)!
		}
		'pane_meta' {
			app.store.save_meta(m.pane_id, m.title, m.startup_cmd, m.autorun, m.shell, m.slot)!
		}
		'close' { // the history file stays until the next start: the pane may be reopened
			note('pane ${m.pane_id} closed')
			app.store.delete_pane(m.pane_id)!
			mut p := app.find_pty(m.pane_id) or { return }
			p.kill()
		}
		'kill' { // the UI respawns after the exit message, e.g. to switch shells
			mut p := app.find_pty(m.pane_id) or { return }
			p.kill()
		}
		'open' {
			// Only web links: a link printed by a program must not launch local files.
			if !(m.url.starts_with('https://') || m.url.starts_with('http://'))
				|| m.url.bytes().any(it <= 32) {
				return error('refusing to open ${m.url}')
			}
			os.open_uri(m.url)!
		}
		'autostart' {
			set_autostart(m.enabled)!
		}
		'layout' {
			app.store.set_config('layout', m.layout)!
		}
		'git_branch' { // body: the branch at cwd, '' outside a repository
			app.send(json.encode(FetchMsg{
				kind:   'fetched'
				req_id: m.req_id
				body:   git_branch(m.cwd)
			}).bytes(), .text_frame)
		}
		'ports' {
			spawn app.list_ports(m.req_id)
		}
		'kill_pid' {
			spawn app.kill_pid(m.req_id, m.pid)
		}
		'fetch' { // data: the request body, base64
			spawn app.fetch_url(m.req_id, m.url, m.method, m.headers, m.data)
		}
		'config' {
			if m.name !in ui_config {
				return error('unknown config ${m.name}')
			}
			app.store.set_config('ui_' + m.name, m.value)!
		}
		'pause', 'resume' { // flow control: the window's terminal is behind / caught up
			app.pty_mu.@lock()
			if m.kind == 'pause' {
				app.paused[m.pane_id] = true
			} else {
				app.paused.delete(m.pane_id)
			}
			app.pty_mu.unlock()
		}
		'log' { // the UI's errors and events
			note('ui: ${m.data#[..2000]}')
		}
		'mcp_result' {
			app.req_mu.@lock()
			if ch := app.pending[m.req_id] {
				ch.try_push(m.result) // cap 1, so never blocks; a late answer is dropped
			}
			app.req_mu.unlock()
		}
		else {
			return error('unknown message type')
		}
	}
}

// attach sends the saved state and makes c the client that receives PTY output.
fn (mut app App) attach(mut c websocket.Client) ! {
	mut panes := app.store.load_panes()!
	app.pty_mu.@lock()
	for mut p in panes {
		p.running = p.id in app.ptys
	}
	app.paused.clear() // a new window has nothing queued; a stale pause would freeze a pane
	app.pty_mu.unlock()
	mut config := map[string]string{}
	for name in ui_config {
		config[name] = app.store.get_config('ui_' + name)
	}
	state := json.encode(StateMsg{
		kind:    'state'
		layout:  app.store.get_config('layout')
		unclean:   app.unclean
		win_build: conpty_build()
		autostart: autostart_enabled()
		shells:    available_shells()
		panes:     panes
		config:    config
	})
	app.send_mu.@lock()
	defer {
		app.send_mu.unlock()
	}
	// State goes out before c is registered, so the UI never gets output for a pane
	// it has not created yet.
	c.write_string(state)!
	app.client = unsafe { &c } // the websocket server heap-allocates every Client
	note('window attached, ${panes.len} panes')
}

fn (mut app App) spawn_pane(id string, cols int, rows int) ! {
	app.pty_mu.@lock()
	defer {
		app.pty_mu.unlock()
	}
	if id in app.ptys {
		return
	}
	mut cwd, shell := app.store.pane_launch(id)
	if cwd == '' || !os.is_dir(cwd) {
		start := app.store.get_config('ui_start_dir') // Settings → New terminals start in
		cwd = if start != '' && os.is_dir(start) { start } else { os.home_dir() }
	}
	// Inherited by the shell and everything it starts, so Claude Code's hooks know which
	// pane they run in. Spawns are serialized by pty_mu, so the variable cannot race.
	os.setenv('VALENTINE_PANE', id, true)
	mut p := open_pty(shell_cmdline(shell, app.history_file(id)), cwd, cols, rows)!
	app.ptys[id] = p
	spawn app.pump(id, mut p)
}

fn (app &App) history_file(id string) string {
	return os.join_path(app.data_dir, 'history', '${id}.txt')
}

fn valid_id(id string) bool {
	return id.len >= 1 && id.len <= 32 && id.bytes().all(it.is_alnum() || it in [`-`, `_`])
}

fn (mut app App) is_paused(id string) bool {
	app.pty_mu.@lock()
	defer {
		app.pty_mu.unlock()
	}
	return app.paused[id]
}

fn (mut app App) find_pty(id string) ?&Pty {
	app.pty_mu.@lock()
	defer {
		app.pty_mu.unlock()
	}
	if p := app.ptys[id] {
		return p
	}
	return none
}

// pump forwards PTY output as binary frames: [id length][id][raw bytes]. Raw bytes keep
// UTF-8 sequences split across reads intact; xterm.js decodes them as a stream.
fn (mut app App) pump(id string, mut p Pty) {
	waiter := spawn p.close_on_exit()
	mut buf := []u8{len: 64 * 1024}
	for {
		// The window asked for a break: its terminal is behind. Not reading makes the
		// pty's buffer fill, which slows the program down instead of the window.
		for app.is_paused(id) {
			time.sleep(10 * time.millisecond)
		}
		mut n := p.read(buf.data, buf.len)
		if n < 0 {
			break
		}
		// Take what else is already waiting: one frame instead of many when output floods.
		for n < buf.len && p.available() > 0 {
			more := p.read(unsafe { &u8(buf.data) + n }, buf.len - n)
			if more <= 0 {
				break
			}
			n += more
		}
		if n == 0 {
			continue
		}
		mut frame := []u8{cap: 1 + id.len + n}
		frame << u8(id.len)
		frame << id.bytes()
		frame << buf[..n]
		app.send(frame, .binary_frame)
	}
	p.kill() // no-op if the shell already exited; unblocks the waiter if only conhost died
	waiter.wait()
	code := p.release()
	app.pty_mu.@lock()
	app.ptys.delete(id)
	app.paused.delete(id)
	app.pty_mu.unlock()
	note('pane ${id}: shell exited with code ${code}')
	app.send(json.encode(ExitMsg{ kind: 'exit', pane_id: id, code: code }).bytes(), .text_frame)
}

// send delivers to the window; false when no window is connected.
fn (mut app App) send(data []u8, code websocket.OPCode) bool {
	app.send_mu.@lock()
	if isnil(app.client) {
		app.send_mu.unlock()
		return false
	}
	app.client.write(data, code) or {
		mut c := app.client
		app.client = unsafe { nil }
		app.send_mu.unlock()
		// Hang up too, or the window stays connected but never gets output again and
		// never reconnects. Outside send_mu: close runs on_ws_close, which takes it.
		c.close(1011, 'write failed') or {}
		return false
	}
	app.send_mu.unlock()
	return true
}

// ui_request forwards payload to the window and waits for its answer.
fn (mut app App) ui_request(payload string, wait time.Duration) !string {
	ch := chan string{cap: 1}
	app.req_mu.@lock()
	app.next_req++
	id := app.next_req.str()
	app.pending[id] = ch
	app.req_mu.unlock()
	defer {
		app.req_mu.@lock()
		app.pending.delete(id)
		app.req_mu.unlock()
	}
	msg := json.encode(UiRequest{ kind: 'mcp', req_id: id, payload: payload })
	if !app.send(msg.bytes(), .text_frame) {
		return error('the Valentine window is not open')
	}
	mut result := ''
	select {
		r := <-ch {
			result = r
		}
		wait {
			return error('the Valentine window did not answer in time')
		}
	}
	return result
}

fn (mut app App) shutdown() {
	app.pty_mu.@lock()
	defer {
		app.pty_mu.unlock()
	}
	for id in app.ptys.keys() {
		mut p := app.ptys[id] or { continue }
		p.kill()
	}
}

// fetch_url makes a request for the page (feeds, worf, forwarding a caught webhook to a
// local server) and sends back a FetchMsg.
fn (mut app App) fetch_url(req_id string, url string, method string, headers string, body_b64 string) {
	mut res := FetchMsg{
		kind:   'fetched'
		req_id: req_id
	}
	do_fetch(mut res, url, method, headers, body_b64) or { res.error = err.msg() }
	app.send(json.encode(res).bytes(), .text_frame)
}

fn do_fetch(mut res FetchMsg, url string, method string, headers string, body_b64 string) ! {
	if !(url.starts_with('https://') || url.starts_with('http://')) {
		return error('only http and https URLs')
	}
	mut header := http.new_header()
	if headers != '' {
		header.add_custom_map(json.decode(map[string]string, headers)!)!
	}
	r := http.fetch(
		url:                url
		method:             if method == '' { .get } else { http.method_from_str(method) }
		header:             header
		data:               base64.decode_str(body_b64)
		validate:           true // a worf or relay token must not go to an impostor
		read_timeout:       15 * time.second
		max_retries:        1
		stop_copying_limit: 4 * 1024 * 1024
	)!
	res.status = r.status_code
	res.body = r.body
}
