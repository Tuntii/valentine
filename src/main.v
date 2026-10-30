module main

import crypto.rand
import net
import os
import time

const http_port = 47100
const ws_port = 47101

fn main() {
	// Helper modes Claude Code starts from inside a pane; see claude.v.
	match os.args[1] or { '' } {
		'hook' {
			run_hook()
			return
		}
		'mcp' {
			run_mcp()
			return
		}
		else {}
	}
	if !single_instance() {
		fatal('Valentine is already running.')
	}
	appdata := os.getenv_opt('APPDATA') or { os.home_dir() }
	data_dir := os.join_path(appdata, 'Valentine')
	migrate_from_cockpit(os.join_path(appdata, 'Cockpit'), data_dir)
	os.mkdir_all(os.join_path(data_dir, 'history')) or { fatal('cannot create ${data_dir}: ${err}') }
	prepare_shell_env()
	mut store := new_storage(os.join_path(data_dir, 'valentine_state.db')) or {
		fatal('cannot open state db: ${err}')
	}
	unclean := store.begin_session() or { fatal('state db: ${err}') }
	token := (rand.bytes(16) or { fatal('no secure random source: ${err}') }).hex()

	mut app := &App{
		store:    store
		data_dir: data_dir
		token:    token
		unclean:  unclean
	}
	write_claude_files(data_dir, http_port, token) or { fatal('cannot write ${data_dir}: ${err}') }
	spawn app.serve_ws(ws_port)
	spawn app.serve_http(http_port)
	wait_for_port(http_port)

	open_window('http://127.0.0.1:${http_port}/?t=${token}&ws=${ws_port}', data_dir)
	// The window is gone: this is a deliberate exit, not a crash.
	app.shutdown()
	store.end_session() or { eprintln('valentine: could not record clean exit: ${err}') }
	os.rm(session_file()) or {}
}

// open_edge_window shows the UI as a chromeless Edge app window and returns when it
// closes: the fallback when WebView2 is unavailable (and the whole UI of `-d edge` builds).
// A dedicated profile dir makes the launched msedge.exe the window's own process.
fn open_edge_window(url string, data_dir string) {
	edge := find_edge()
	if edge == '' {
		os.open_uri(url) or { fatal('cannot open a browser: ${err}') }
		println('Valentine is running in your browser. Press Ctrl+C here to quit.')
		for {
			time.sleep(time.hour)
		}
	}
	profile := os.join_path(data_dir, 'webview')
	// A bare window: without these Edge signs the profile into the Windows account and
	// syncs its extensions in, which then open their own welcome tabs (MetaMask etc.).
	cmd := '"${edge}" --app="${url}" --user-data-dir="${profile}" --start-maximized --no-first-run ' +
		'--no-default-browser-check --disable-extensions --disable-sync ' +
		'--disable-features=msImplicitSignin,msEdgeSidebar,msHubApps'
	run_and_wait(cmd) or { fatal('cannot start Edge: ${err}') }
}

fn find_edge() string {
	for base in [os.getenv('ProgramFiles(x86)'), os.getenv('ProgramFiles'), os.getenv('LOCALAPPDATA')] {
		path := os.join_path(base, 'Microsoft', 'Edge', 'Application', 'msedge.exe')
		if base != '' && os.exists(path) {
			return path
		}
	}
	return ''
}

fn wait_for_port(port int) {
	for _ in 0 .. 50 {
		mut c := net.dial_tcp('127.0.0.1:${port}') or {
			time.sleep(100 * time.millisecond)
			continue
		}
		c.close() or {}
		return
	}
	fatal('HTTP server did not start on port ${port}')
}

// migrate_from_cockpit moves the data of the app's pre-rename builds into place, once.
fn migrate_from_cockpit(old_dir string, data_dir string) {
	if os.exists(data_dir) || !os.is_dir(old_dir) {
		return
	}
	os.mv(old_dir, data_dir) or { return } // in use by an old build: start fresh instead
	for ext in ['', '-wal', '-shm'] {
		old_db := os.join_path(data_dir, 'cockpit_state.db${ext}')
		if os.exists(old_db) {
			os.mv(old_db, os.join_path(data_dir, 'valentine_state.db${ext}')) or {}
		}
	}
}

@[noreturn]
fn fatal(msg string) {
	eprintln('valentine: ${msg}')
	exit(1)
}
