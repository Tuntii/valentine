module main

import json
import os

// PortRow is a TCP port some process listens on (sidebar → Ports).
struct PortRow {
	port int
	pid  int
mut:
	name string
}

// Windows services nobody starts from a terminal; listing them only hides the dev servers.
const system_procs = ['svchost.exe', 'System', 'lsass.exe', 'wininit.exe', 'services.exe', 'spoolsv.exe']

// list_ports answers a 'ports' request. It runs on its own thread: netstat and tasklist
// take a few hundred milliseconds, and only run while the Ports tab is opened.
fn (mut app App) list_ports(req_id string) {
	mut res := FetchMsg{
		kind:   'fetched'
		req_id: req_id
	}
	rows := listening_ports() or {
		res.error = err.msg()
		[]PortRow{}
	}
	res.body = json.encode(rows)
	app.send(json.encode(res).bytes(), .text_frame)
}

fn listening_ports() ![]PortRow {
	$if windows {
		ns := os.execute('netstat -ano')
		if ns.exit_code != 0 {
			return error('netstat failed')
		}
		mut rows := parse_netstat(ns.output)
		names := parse_tasklist(os.execute('tasklist /fo csv /nh').output)
		for mut r in rows {
			r.name = names[r.pid] or { '' }
		}
		return rows.filter(it.name !in system_procs)
	} $else {
		// lsof exits 1 when nothing listens, so its status says nothing.
		return parse_lsof(os.execute('lsof -nP -iTCP -sTCP:LISTEN -Fpcn').output)
	}
}

// parse_netstat reads `netstat -ano`. Listening sockets are told apart by their foreign
// address, not the state column, which Windows translates ("LISTENING", "DİNLEME"...).
fn parse_netstat(out string) []PortRow {
	mut rows := []PortRow{}
	for line in out.split_into_lines() {
		f := line.fields()
		if f.len != 5 || f[0] != 'TCP' || f[2] !in ['0.0.0.0:0', '[::]:0'] {
			continue
		}
		port, pid := f[1].all_after_last(':').int(), f[4].int()
		if pid > 4 && port > 0 && !rows.any(it.port == port && it.pid == pid) { // 0, 4: the kernel
			rows << PortRow{
				port: port
				pid:  pid
			}
		}
	}
	rows.sort(a.port < b.port)
	return rows
}

// parse_tasklist maps pid -> image name from `tasklist /fo csv /nh`.
fn parse_tasklist(out string) map[int]string {
	mut names := map[int]string{}
	for line in out.split_into_lines() {
		f := line.split('","')
		if f.len > 1 {
			names[f[1].int()] = f[0].trim_left('"')
		}
	}
	return names
}

// parse_lsof reads `lsof -F pcn`: a p<pid> line, then c<command>, then one n<addr> per socket.
fn parse_lsof(out string) []PortRow {
	mut rows := []PortRow{}
	mut pid, mut name := 0, ''
	for line in out.split_into_lines() {
		if line.len < 2 {
			continue
		}
		v := line[1..]
		match line[0] {
			`p` { pid = v.int() }
			`c` { name = v }
			`n` {
				port := v.all_after_last(':').int()
				if port > 0 && !rows.any(it.port == port && it.pid == pid) {
					rows << PortRow{
						port: port
						pid:  pid
						name: name
					}
				}
			}
			else {}
		}
	}
	rows.sort(a.port < b.port)
	return rows
}

// kill_pid answers a 'kill_pid' request from the Ports tab.
fn (mut app App) kill_pid(req_id string, pid int) {
	mut res := FetchMsg{
		kind:   'fetched'
		req_id: req_id
	}
	if pid <= 4 || pid == os.getpid() {
		res.error = 'refusing to kill pid ${pid}'
	} else {
		$if windows {
			r := os.execute('taskkill /F /PID ${pid}')
			if r.exit_code != 0 {
				res.error = r.output.trim_space()
			}
		} $else {
			r := os.execute('kill ${pid}')
			if r.exit_code != 0 {
				res.error = r.output.trim_space()
			}
		}
	}
	app.send(json.encode(res).bytes(), .text_frame)
}

// git_branch names the branch checked out at cwd: '' outside a repository, a short hash
// when detached. It reads .git/HEAD instead of running git, so it is cheap enough to
// call after every command.
fn git_branch(cwd string) string {
	if cwd == '' || !os.is_dir(cwd) {
		return ''
	}
	mut dir := os.real_path(cwd)
	for {
		dot := os.join_path(dir, '.git')
		if os.exists(dot) {
			mut git_dir := dot
			if os.is_file(dot) { // worktree or submodule: "gitdir: <path>"
				line := (os.read_file(dot) or { return '' }).trim_space()
				if !line.starts_with('gitdir:') {
					return ''
				}
				git_dir = line.all_after('gitdir:').trim_space()
				if !os.is_abs_path(git_dir) {
					git_dir = os.join_path(dir, git_dir)
				}
			}
			head := (os.read_file(os.join_path(git_dir, 'HEAD')) or { return '' }).trim_space()
			if head.starts_with('ref: ') {
				return head.all_after('ref: ').trim_string_left('refs/heads/')
			}
			return head#[..7]
		}
		parent := os.dir(dir)
		if parent == dir || parent == '' || parent == '.' {
			return ''
		}
		dir = parent
	}
	return ''
}
