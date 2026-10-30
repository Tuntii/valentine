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
{"name": "open_pane", "description": "Split a pane and start a new shell in it. Returns the new pane id.", "inputSchema": {"type": "object", "properties": {"name": {"type": "string"}, "cwd": {"type": "string", "description": "Working directory (Windows path)."}, "shell": {"type": "string", "enum": ["powershell", "cmd", "gitbash", "wsl"]}, "command": {"type": "string", "description": "Command to run once the shell is ready."}, "split_from": {"type": "string", "description": "Pane to split; defaults to the focused pane."}, "direction": {"type": "string", "enum": ["right", "down"]}}}},
{"name": "ask_agent", "description": "Talk to the AI agent (Claude Code, OpenCode, Grok, ...) running in another pane: types your message there as if the user wrote it, waits until that agent has answered, and returns its screen. Use list_panes to find agents and read_pane to look at their output without interrupting them. Never ask your own pane.", "inputSchema": {"type": "object", "properties": {"pane": {"type": "string", "description": "Pane id or name of the agent to ask."}, "message": {"type": "string"}, "timeout_seconds": {"type": "integer", "description": "Default 300, max 600. On timeout the current screen is returned."}}, "required": ["pane", "message"]}},
{"name": "close_pane", "description": "Close a pane and terminate its shell.", "inputSchema": {"type": "object", "properties": {"pane": {"type": "string", "description": "Pane id or name."}}, "required": ["pane"]}}
]'

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
}

fn session_file() string {
	return os.join_path(os.getenv_opt('APPDATA') or { os.home_dir() }, 'Valentine', 'session.json')
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

// run_hook is `valentine hook`: forwards the event on stdin to the pane's Valentine. It never
// prints and always exits 0, so it cannot change what Claude does.
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
	post_valentine('/hook', body.bytestr(), pane, 2 * time.second) or {}
}

// on_hook records the session for resume-after-restart and tells the window.
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
	return '{}'
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
	resp := mcp_handle(line)
	if resp == '' {
		return
	}
	out := resp + '\n'
	out_mu.@lock()
	C.valentine_std_write(out.str, out.len)
	out_mu.unlock()
}

fn mcp_handle(line string) string {
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
				'"capabilities":{"tools":{}},"serverInfo":{"name":"valentine","version":"0.1.0"}}}'
		}
		'tools/list' {
			// One message per line: the readable const must lose its newlines.
			return '{"jsonrpc":"2.0","id":${id},"result":{"tools":${mcp_tools.replace('\n', '')}}}'
		}
		'tools/call' {
			args := if a := params['arguments'] { a.json_str() } else { '{}' }
			// `from`: the pane this agent runs in (unknown when its MCP host is a service).
			body := '{"tool":${json.encode(json_str(params, 'name'))},"args":${args},"from":${json.encode(os.getenv('VALENTINE_PANE'))}}'
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

fn rpc_error(id string, code int, msg string) string {
	return '{"jsonrpc":"2.0","id":${id},"error":{"code":${code},"message":${json.encode(msg)}}}'
}
