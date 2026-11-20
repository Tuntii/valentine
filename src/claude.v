module main

// Claude Code integration. Nothing here touches the user's own Claude settings: panes
// run `claude` through a wrapper (see conpty_windows.c.v) that adds
//   --settings claude-settings.json  hooks -> `valentine hook` -> POST /hook (status, resume)
//   --mcp-config claude-mcp.json     MCP server `valentine mcp` -> POST /call -> the window
// Both helper modes find the running Valentine through session.json (port + token).
import json
import net.http
import os
import sync
import time
import x.json2

const hook_events = ['SessionStart', 'SessionEnd', 'UserPromptSubmit', 'Stop', 'Notification']

const mcp_tools = r'[
{"name": "list_panes", "description": "List Valentine terminal panes: id, name, current directory, shell, whether a command or Claude Code is running, and which pane is focused.", "inputSchema": {"type": "object", "properties": {}}},
{"name": "read_pane", "description": "Read the last lines of a pane as plain text (screen and scrollback).", "inputSchema": {"type": "object", "properties": {"pane": {"type": "string", "description": "Pane id or name (case-insensitive). Defaults to the focused pane."}, "lines": {"type": "integer", "description": "Lines from the bottom; default 80, max 2000."}}}},
{"name": "run_command", "description": "Type a command into the shell of a pane, wait for it to finish and return its output and exit code. Refuses when the pane is busy or running Claude Code. On timeout the command keeps running; read it later with read_pane.", "inputSchema": {"type": "object", "properties": {"pane": {"type": "string", "description": "Pane id or name. Defaults to the focused pane."}, "command": {"type": "string"}, "timeout_seconds": {"type": "integer", "description": "Default 60, max 120."}}, "required": ["command"]}},
{"name": "send_text", "description": "Send keystrokes to a pane, e.g. an answer to a prompt or \u0003 for Ctrl+C. Presses Enter afterwards unless enter is false.", "inputSchema": {"type": "object", "properties": {"pane": {"type": "string", "description": "Pane id or name. Defaults to the focused pane."}, "text": {"type": "string"}, "enter": {"type": "boolean"}}, "required": ["text"]}},
{"name": "open_pane", "description": "Split a pane and start a new shell in it. Returns the new pane id.", "inputSchema": {"type": "object", "properties": {"name": {"type": "string"}, "cwd": {"type": "string", "description": "Working directory (absolute path)."}, "shell": {"type": "string", "description": "powershell, cmd, gitbash or wsl on Windows; zsh, bash or fish elsewhere. Defaults to the default shell."}, "command": {"type": "string", "description": "Command to run once the shell is ready."}, "split_from": {"type": "string", "description": "Pane to split; defaults to the focused pane."}, "direction": {"type": "string", "enum": ["right", "down"]}}}},
{"name": "ask_agent", "description": "Talk to the AI agent (Claude Code, OpenCode, Grok, ...) running in another pane: types your message there as if the user wrote it, waits until that agent has answered, and returns its screen. Use list_panes to find agents and read_pane to look at their output without interrupting them. Never ask your own pane.", "inputSchema": {"type": "object", "properties": {"pane": {"type": "string", "description": "Pane id or name of the agent to ask."}, "message": {"type": "string"}, "timeout_seconds": {"type": "integer", "description": "Default 300, max 600. On timeout the current screen is returned."}}, "required": ["pane", "message"]}},
{"name": "close_pane", "description": "Close a pane and terminate its shell.", "inputSchema": {"type": "object", "properties": {"pane": {"type": "string", "description": "Pane id or name."}}, "required": ["pane"]}},
{"name": "todo_list", "description": "List the tasks of a project in the Valentine todo board (like a Jira board): id, title, status (todo, in_progress, done) and note. Use it to see where the work stands before starting and keep it current as you go.", "inputSchema": {"type": "object", "properties": {"project": {"type": "string", "description": "Project name. Defaults to the folder name of the directory of your pane; * lists every project."}}}},
{"name": "todo_add", "description": "Add a task to the todo board of a project. Returns the new task.", "inputSchema": {"type": "object", "properties": {"title": {"type": "string"}, "project": {"type": "string", "description": "Defaults to the folder name of the directory of your pane."}, "status": {"type": "string", "enum": ["todo", "in_progress", "done"]}, "note": {"type": "string"}}, "required": ["title"]}},
{"name": "todo_update", "description": "Change a task: move it to another status (todo, in_progress, done), rename it, edit its note or move it to another project.", "inputSchema": {"type": "object", "properties": {"id": {"type": "integer"}, "status": {"type": "string", "enum": ["todo", "in_progress", "done"]}, "title": {"type": "string"}, "note": {"type": "string"}, "project": {"type": "string"}}, "required": ["id"]}},
{"name": "todo_delete", "description": "Delete a task from the todo board.", "inputSchema": {"type": "object", "properties": {"id": {"type": "integer"}}, "required": ["id"]}}
]'

// mcp_instructions tells every agent how to keep the todo board current across sessions.
const mcp_instructions = 'Valentine keeps a todo board per project (the folder name of your pane), shared by every session and shown to the user in its sidebar. ' +
	'Before starting work, call todo_list to see what is open. Move a task to in_progress when you start it and to done when it is finished. ' +
	'Before you end your turn, todo_add whatever is still left to do: follow-ups, steps the user has to take, things you deferred, so a later session can pick them up.'

struct Session {
	port  int
	token string
}

// ClaudeMsg tells the window what Claude Code is doing in a pane.
struct ClaudeMsg {
	kind       string @[json: 'type']
	pane_id    string
	event      string
	session_id string
	message    string
}

struct UiResult {
	text     string
	is_error bool
}

struct HookCommand {
	kind    string @[json: 'type']
	command string
	args    []string
	timeout int
}

struct HookGroup {
	hooks []HookCommand
}

// write_claude_files writes the files the pane wrappers and helper modes read, and
// exports their paths to every shell Valentine starts.
fn write_claude_files(data_dir string, port int, token string) ! {
	exe := os.executable()
	mut hooks := map[string][]HookGroup{}
	for event in hook_events {
		// Exec form: no shell in between, and Claude ignores a silent exit-0 hook.
		hooks[event] = [
			HookGroup{
				hooks: [HookCommand{
					kind:    'command'
					command: exe
					args:    ['hook']
					timeout: 5
				}]
			},
		]
	}
	settings := os.join_path(data_dir, 'claude-settings.json')
	mcp := os.join_path(data_dir, 'claude-mcp.json')
	os.write_file(settings, '{"hooks": ${json.encode(hooks)}}')!
	os.write_file(mcp, '{"mcpServers": {"valentine": {"type": "stdio", "command": ${json.encode(exe)}, "args": ["mcp"]}}}')!
	os.write_file(session_file(), json.encode(Session{ port: port, token: token }))!
	os.setenv('VALENTINE_CLAUDE_SETTINGS', settings, true)
	os.setenv('VALENTINE_MCP_CONFIG', mcp, true)
	// Claude's classic renderer draws into the pane's scrollback, so the wheel scrolls the
	// pane instead of the conversation and the prompt slides off screen. Fullscreen keeps
	// the prompt pinned and scrolls inside Claude, as in Windows Terminal. A value the user
	// set (0 forces classic) wins.
	if os.getenv('CLAUDE_CODE_NO_FLICKER') == '' {
		os.setenv('CLAUDE_CODE_NO_FLICKER', '1', true)
	}
}

fn session_file() string {
	return os.join_path(app_dir(), 'session.json')
}

fn post_valentine(path string, body string, pane string, wait time.Duration) !string {
	s := json.decode(Session, os.read_file(session_file()) or {
		return error('Valentine is not running')
	})!
	mut header := http.new_header(key: .content_type, value: 'application/json')
	header.add_custom('X-Valentine-Token', s.token)!
	if pane != '' {
		header.add_custom('X-Valentine-Pane', pane)!
	}
	resp := http.fetch(
		url:          'http://127.0.0.1:${s.port}${path}'
		method:       .post
		data:         body
		header:       header
		read_timeout: wait
	) or { return error('Valentine is not running') }
	if resp.status_code != 200 {
		return error(resp.body)
	}
	return resp.body
}

// run_hook is `valentine hook`: forwards the event on stdin to the pane's Valentine. It always
// exits 0; it prints only the open tasks Valentine returns for SessionStart, which Claude
// adds to the new session's context.
fn run_hook() {
	pane := os.getenv('VALENTINE_PANE')
	if pane == '' {
		return // Claude started outside a Valentine pane
	}
	mut body := []u8{}
	mut buf := []u8{len: 8192}
	for {
		n := C.valentine_std_read(buf.data, buf.len)
		if n <= 0 {
			break
		}
		body << buf[..n]
	}
	context := post_valentine('/hook', body.bytestr(), pane, 2 * time.second) or { '' }
	if context != '' {
		print(context)
	}
}

struct Todo {
	id      int
	project string
	title   string
	status  string
	note    string
}

// open_tasks lists the unfinished tasks of a project on the todo board for a new session,
// or '' when there are none.
fn open_tasks(todos_json string, project string) string {
	todos := json.decode([]Todo, todos_json) or { return '' }
	mut lines := []string{}
	for t in todos {
		if t.project == project && t.status != 'done' {
			note := if t.note == '' { '' } else { ' (${t.note})' }
			lines << '- #${t.id} [${t.status}] ${t.title}${note}'
		}
	}
	if lines.len == 0 {
		return ''
	}
	return 'Open tasks for project "${project}" on the Valentine todo board (todo_* tools):\n' +
		lines.join('\n') + '\nMention them to the user when relevant; move each one with todo_update as you work on it.'
}

// on_hook records the session for resume-after-restart and tells the window. For
// SessionStart it answers with the open tasks of the session's project (its folder name,
// as the todo_* tools default to).
fn (mut app App) on_hook(pane string, body string) !string {
	if !valid_id(pane) {
		return error('bad pane')
	}
	ev := json2.decode[json2.Any](body)!.as_map()
	event := json_str(ev, 'hook_event_name')
	session := json_str(ev, 'session_id')
	match event {
		'SessionStart' { app.store.save_claude(pane, session)! }
		'SessionEnd' { app.store.save_claude(pane, '')! }
		else {}
	}
	app.send(json.encode(ClaudeMsg{
		kind:       'claude'
		pane_id:    pane
		event:      event
		session_id: session
		message:    json_str(ev, 'message')
	}).bytes(), .text_frame)
	if event != 'SessionStart' {
		return ''
	}
	parts := json_str(ev, 'cwd').split_any('\\/').filter(it != '')
	if parts.len == 0 {
		return ''
	}
	return open_tasks(app.store.get_config('ui_todos'), parts.last())
}

fn json_str(m map[string]json2.Any, key string) string {
	v := m[key] or { return '' }
	return if v is string { v } else { '' }
}

// run_mcp is `valentine mcp`: a stdio MCP server (newline-delimited JSON-RPC). Tool calls
// run on their own threads so a long run_command does not hold up other requests.
fn run_mcp() {
	out_mu := sync.new_mutex()
	mut pending := []u8{}
	mut buf := []u8{len: 65536}
	for {
		n := C.valentine_std_read(buf.data, buf.len)
		if n <= 0 {
			break // stdin closed: Claude is done with us
		}
		pending << buf[..n]
		for {
			i := pending.index(`\n`)
			if i < 0 {
				break
			}
			line := pending[..i].bytestr().trim_space()
			pending = pending[i + 1..].clone()
			if line == '' {
				continue
			}
			if line.contains('"tools/call"') {
				spawn mcp_reply(line, out_mu)
			} else {
				mcp_reply(line, out_mu)
			}
		}
	}
}

fn mcp_reply(line string, out_mu &sync.Mutex) {
	resp := mcp_handle(line, os.getenv('VALENTINE_PANE'))
	if resp == '' {
		return
	}
	out := resp + '\n'
	out_mu.@lock()
	C.valentine_std_write(out.str, out.len)
	out_mu.unlock()
}

// from: the pane the agent runs in, '' when it is not in one (a service, a remote client).
fn mcp_handle(line string, from string) string {
	req := (json2.decode[json2.Any](line) or { return rpc_error('null', -32700, 'parse error') }).as_map()
	id_any := req['id'] or { return '' } // a notification: no reply
	id := id_any.json_str()
	params := if p := req['params'] { p.as_map() } else { map[string]json2.Any{} }
	match json_str(req, 'method') {
		'initialize' {
			mut version := json_str(params, 'protocolVersion')
			if version == '' {
				version = '2025-06-18'
			}
			return '{"jsonrpc":"2.0","id":${id},"result":{"protocolVersion":${json.encode(version)},' +
				'"capabilities":{"tools":{}},"serverInfo":{"name":"valentine","version":"${app_version}"},' +
				'"instructions":${json.encode(mcp_instructions)}}}'
		}
		'tools/list' {
			// One message per line: the readable const must lose its newlines.
			return '{"jsonrpc":"2.0","id":${id},"result":{"tools":${mcp_tools.replace('\n', '')}}}'
		}
		'tools/call' {
			args := if a := params['arguments'] { a.json_str() } else { '{}' }
			body := '{"tool":${json.encode(json_str(params, 'name'))},"args":${args},"from":${json.encode(from)}}'
			res := post_valentine('/call', body, '', 630 * time.second) or {
				json.encode(UiResult{ text: err.msg(), is_error: true })
			}
			r := json.decode(UiResult, res) or { UiResult{ text: res, is_error: true } }
			return '{"jsonrpc":"2.0","id":${id},"result":{"content":[{"type":"text","text":${json.encode(r.text)}}],"isError":${r.is_error}}}'
		}
		'ping' {
			return '{"jsonrpc":"2.0","id":${id},"result":{}}'
		}
		else {
			return rpc_error(id, -32601, 'method not found')
		}
	}
}

struct RelayConfig {
	url   string
	token string
}

struct RelayJob {
	id   int
	body string
}

// remote_mcp serves remote MCP clients (a claude.ai connector on mcp.rustapi.cloud): it
// long-polls the relay set under Sidebar → Relay and answers each request like `valentine mcp`.
// The relay only queues requests when it has MCP_SECRET set (relay/relay.py).
fn (mut app App) remote_mcp() {
	for {
		cfg := json.decode(RelayConfig, app.store.get_config('ui_relay')) or { RelayConfig{} }
		if cfg.url == '' || cfg.token == '' {
			time.sleep(5 * time.second)
			continue
		}
		base := cfg.url.trim_right('/')
		r := relay_fetch(.get, '${base}/api/mcp/next', cfg.token, '', 30 * time.second) or {
			time.sleep(10 * time.second) // offline, bad token or an older relay
			continue
		}
		job := json.decode(RelayJob, r) or { RelayJob{} }
		if job.id > 0 {
			spawn relay_answer(base, cfg.token, job)
		}
	}
}

fn relay_answer(base string, token string, job RelayJob) {
	resp := mcp_handle(job.body, '')
	relay_fetch(.post, '${base}/api/mcp/reply?id=${job.id}', token, resp, 15 * time.second) or {
		note('remote MCP: cannot answer the relay: ${err}')
	}
}

fn relay_fetch(method http.Method, url string, token string, body string, wait time.Duration) !string {
	mut header := http.new_header(key: .content_type, value: 'application/json')
	header.add_custom('Authorization', 'Bearer ${token}')!
	r := http.fetch(
		url:                url
		method:             method
		data:               body
		header:             header
		validate:           true // the token must not go to an impostor
		read_timeout:       wait
		stop_copying_limit: 4 * 1024 * 1024
	)!
	if r.status_code != 200 {
		return error('HTTP ${r.status_code}')
	}
	return r.body
}

fn rpc_error(id string, code int, msg string) string {
	return '{"jsonrpc":"2.0","id":${id},"error":{"code":${code},"message":${json.encode(msg)}}}'
}
