module main

import db.sqlite
import encoding.base64
import net.http
import os

fn test_storage_roundtrip() ! {
	mut s := new_storage(':memory:')!
	assert s.begin_session()! // no clean-exit marker yet
	s.end_session()!
	assert !s.begin_session()!

	s.save_meta('p1', 'Server', 'v watch run .', true, 'gitbash', 1)!
	s.save_meta('p0', 'DB', '', false, '', 0)!
	s.save_cwd('p1', 'C:\\work\\Masaüstü')!
	s.save_buffer('p1', 'hello\r\n\x1b[32mworld\x1b[0m')!
	s.save_meta('p1', 'API', 'v watch run .', true, 'gitbash', 1)! // meta update keeps cwd/buffer
	s.save_cwd('ghost', 'C:\\nope')! // UPDATE-only: must not create a row

	panes := s.load_panes()!
	assert panes.len == 2
	assert panes[0].id == 'p0'
	assert panes[1].title == 'API'
	assert panes[1].autorun
	assert panes[1].shell == 'gitbash'
	assert panes[1].startup_cmd == 'v watch run .'
	assert panes[1].cwd == 'C:\\work\\Masaüstü'
	assert panes[1].buffer == 'hello\r\n\x1b[32mworld\x1b[0m'
	cwd, shell := s.pane_launch('p1')
	assert cwd == 'C:\\work\\Masaüstü' && shell == 'gitbash'
	gcwd, gshell := s.pane_launch('ghost')
	assert gcwd == '' && gshell == ''

	s.set_config('layout', '{"split":"row"}')!
	s.set_config('layout', '{"split":"col"}')!
	assert s.get_config('layout') == '{"split":"col"}'

	s.delete_pane('p1')!
	s.save_buffer('p1', 'late')! // a late save after close must not resurrect it
	assert s.load_panes()!.len == 1
}

fn test_old_database_gets_shell_column() ! {
	path := os.join_path(os.temp_dir(), 'valentine_migration_test.db')
	os.rm(path) or {}
	defer {
		os.rm(path) or {}
	}
	mut old := sqlite.connect(path)!
	old.exec("CREATE TABLE panes (id TEXT PRIMARY KEY, title TEXT NOT NULL DEFAULT '', cwd TEXT NOT NULL DEFAULT '',
		startup_cmd TEXT NOT NULL DEFAULT '', autorun INTEGER NOT NULL DEFAULT 0, slot INTEGER NOT NULL DEFAULT 0,
		buffer TEXT NOT NULL DEFAULT '', updated_at INTEGER NOT NULL DEFAULT 0)")!
	old.exec("INSERT INTO panes (id, title) VALUES ('p1', 'Old')")!
	old.close()!

	mut s := new_storage(path)!
	panes := s.load_panes()!
	assert panes.len == 1 && panes[0].title == 'Old' && panes[0].shell == ''
	s.db.close()!
	mut again := new_storage(path)! // second open: ALTER fails quietly
	again.db.close()!
}

fn test_valid_id() {
	assert valid_id('p1a2b3c4d')
	assert valid_id('pane_1-x')
	assert !valid_id('')
	assert !valid_id("p'; rm")
	assert !valid_id('..\\evil')
	assert !valid_id('x'.repeat(33))
}

fn test_shell_cmdline() {
	$if windows {
		assert encode_ps('a') == 'YQA=' // UTF-16LE 61 00
		assert encode_ps('ü') == '/AA=' // UTF-16LE FC 00
		assert encode_ps('😀') == 'PdgA3g==' // surrogate pair D83D DE00
		assert shell_cmdline('', 'C:\\Users\\O\'Brien\\h.txt').contains('-EncodedCommand ')
		assert shell_cmdline('cmd', '').starts_with('cmd.exe /k doskey claude=')
		assert shell_cmdline('cmd', '').contains(' & prompt ')
	} $else {
		assert sh_quote("/Users/O'Brien/h.txt") == "'/Users/O'\\''Brien/h.txt'"
		shells := available_shells()
		// An unknown or uninstalled shell falls back to the default one.
		assert shell_cmdline('powershell', '/h') == shell_cmdline(shells[0], '/h')
		if 'bash' in shells {
			assert shell_cmdline('bash', '/tmp/a b').starts_with("HISTFILE='/tmp/a b' exec ")
		}
		if 'zsh' in shells {
			assert shell_cmdline('zsh', '/h').contains('ZDOTDIR="\$VALENTINE_SHELL_DIR"')
		}
	}
}

// A real shell in a real pty: output arrives, input is typed, the exit code comes back.
fn test_pty_roundtrip() ! {
	$if !windows {
		mut p := open_pty('read x; echo "got:\$x"; exit 3', os.temp_dir(), 80, 24)!
		waiter := spawn p.close_on_exit()
		p.write('hello\n')
		mut out := []u8{}
		mut buf := []u8{len: 4096}
		for {
			n := p.read(buf.data, buf.len)
			if n < 0 {
				break
			}
			out << buf[..n]
		}
		waiter.wait()
		assert out.bytestr().contains('got:hello')
		assert p.release() == 3
	}
}

fn test_claude_session_column() ! {
	mut s := new_storage(':memory:')!
	s.save_meta('p1', 'AI', '', false, '', 0)!
	s.save_claude('p1', '9174fd59-2b6b-42c0-8fe6-f9ef41fc6ba0')!
	assert s.load_panes()![0].claude == '9174fd59-2b6b-42c0-8fe6-f9ef41fc6ba0'
	s.save_claude('p1', '')!
	assert s.load_panes()![0].claude == ''
}

fn test_mcp_protocol() {
	init := mcp_handle('{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}')
	assert init.contains('"id":1,') && init.contains('"protocolVersion":"2025-06-18"')
	assert mcp_handle('{"jsonrpc":"2.0","method":"notifications/initialized"}') == ''
	list := mcp_handle('{"jsonrpc":"2.0","id":"a","method":"tools/list"}')
	assert !list.contains('\n') // one JSON-RPC message per line
	for tool in ['list_panes', 'read_pane', 'run_command', 'send_text', 'open_pane', 'ask_agent', 'close_pane'] {
		assert list.contains('"name": "${tool}"')
	}
	assert mcp_handle('{"jsonrpc":"2.0","id":2,"method":"x"}').contains('-32601')
	assert mcp_handle('not json').contains('-32700')
}

fn test_panes_are_not_claude_child_sessions() {
	os.setenv('CLAUDE_CODE_CHILD_SESSION', '1', true)
	os.setenv('CLAUDECODE', '1', true)
	prepare_shell_env()
	assert os.getenv('CLAUDE_CODE_CHILD_SESSION') == ''
	assert os.getenv('CLAUDECODE') == ''
	assert os.getenv('BASH_FUNC_claude%%').contains('--mcp-config')
}

fn test_migrate_from_cockpit() ! {
	root := os.join_path(os.temp_dir(), 'valentine_migrate_test')
	os.rmdir_all(root) or {}
	defer {
		os.rmdir_all(root) or {}
	}
	old := os.join_path(root, 'Cockpit')
	new := os.join_path(root, 'Valentine')
	os.mkdir_all(os.join_path(old, 'history'))!
	os.write_file(os.join_path(old, 'cockpit_state.db'), 'db')!
	os.write_file(os.join_path(old, 'cockpit_state.db-wal'), 'wal')!
	migrate_from_cockpit(old, new)
	assert !os.exists(old)
	assert os.read_file(os.join_path(new, 'valentine_state.db'))! == 'db'
	assert os.read_file(os.join_path(new, 'valentine_state.db-wal'))! == 'wal'
	assert os.is_dir(os.join_path(new, 'history'))
	// Never twice: an existing Valentine dir is left alone.
	os.mkdir_all(old)!
	migrate_from_cockpit(old, new)
	assert os.is_dir(old)
}

struct EchoHandler {}

fn (mut h EchoHandler) handle(req http.Request) http.Response {
	sig := req.header.get_custom('Stripe-Signature') or { '' }
	return http.new_response(body: '${req.method} ${sig} ${req.data}')
}

// Forwarding a caught webhook must keep its method, signature header and body.
fn test_fetch_forwards_method_headers_and_body() ! {
	mut server := &http.Server{
		addr:    '127.0.0.1:47199'
		handler: EchoHandler{}
	}
	spawn server.listen_and_serve()
	server.wait_till_running()!
	defer {
		server.close()
	}
	mut res := FetchMsg{}
	do_fetch(mut res, 'http://127.0.0.1:47199/hook?a=1', 'PUT', '{"Stripe-Signature":"t=1,v1=abc"}',
		base64.encode_str('{"id":"evt_1"}'))!
	assert res.status == 200
	assert res.body == 'PUT t=1,v1=abc {"id":"evt_1"}'
	if _ := do_fetch(mut res, 'file:///C:/Windows/win.ini', '', '', '') {
		assert false, 'non-http URL fetched'
	}
}
