module main

import crypto.rand
import net
import os
import time

const http_port = 47100
const ws_port = 47101

// Set by release builds (`-d valentine_version=1.2.3`).
const app_version = $d('valentine_version', 'dev')

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
		show_existing() // it may be hidden in the tray
		return
	}
	data_dir := app_dir()
	migrate_from_cockpit(os.join_path(os.dir(data_dir), 'Cockpit'), data_dir)
	os.mkdir_all(os.join_path(data_dir, 'history')) or { fatal('cannot create ${data_dir}: ${err}') }
	start_log(data_dir)
	note('valentine ${app_version} starting')
	prepare_shell_env()
	mut store := new_storage(os.join_path(data_dir, 'valentine_state.db')) or {
		fatal('cannot open state db: ${err}')
	}
	unclean := store.begin_session() or { fatal('state db: ${err}') }
	if unclean {
		note('the previous run did not exit cleanly')
	}
	forget_closed_panes(mut store, data_dir)
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
	store.end_session() or { note('could not record clean exit: ${err}') }
	note('valentine exiting')
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

// app_dir holds Valentine's state: %APPDATA%\Valentine, ~/Library/Application Support/Valentine
// or $XDG_CONFIG_HOME/Valentine.
fn app_dir() string {
	return os.join_path(os.config_dir() or { os.home_dir() }, 'Valentine')
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

// start_log sends stderr (eprintln, V's panics, our notes) to valentine.log: the GUI build
// has no console, and without a log a failure leaves no trace. One old file is kept.
fn start_log(data_dir string) {
	path := os.join_path(data_dir, 'valentine.log')
	if os.file_size(path) > 1024 * 1024 {
		os.mv(path, path + '.1', overwrite: true) or {}
	}
	$if windows {
		C._wfreopen(path.to_wide(), 'a'.to_wide(), C.stderr)
	} $else {
		C.freopen(&char(path.str), c'a', C.stderr)
	}
}

// note writes one timestamped line to the log.
fn note(msg string) {
	eprintln('${time.now().format_ss()} ${msg}')
}

// forget_closed_panes deletes the shell history of panes closed in an earlier run; it is
// kept until then so that a closed pane can be reopened with its history.
fn forget_closed_panes(mut store Storage, data_dir string) {
	ids := (store.load_panes() or { return }).map(it.id)
	dir := os.join_path(data_dir, 'history')
	for f in os.ls(dir) or { [] } {
		if f.ends_with('.txt') && f.all_before_last('.txt') !in ids {
			os.rm(os.join_path(dir, f)) or {}
		}
	}
}

@[noreturn]
fn fatal(msg string) {
	eprintln('valentine: ${msg}')
	exit(1)
}
