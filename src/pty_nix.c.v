module main

import os
import sync

#include "@VMODROOT/src/pty_unix.h"
#flag linux -lutil

fn C.valentine_pty_open(cols int, rows int, cmdline &char, cwd &char, fd &int, pid &int) int
fn C.valentine_pty_resize(fd int, cols int, rows int) int
fn C.valentine_pty_read(fd int, buf voidptr, len int) int
fn C.valentine_pty_available(fd int) int
fn C.valentine_pty_write(fd int, buf voidptr, len int) int
fn C.valentine_pty_wait(pid int) int
fn C.valentine_pty_kill(pid int)
fn C.valentine_close_fd(fd int)
fn C.valentine_std_read(buf voidptr, len int) int
fn C.valentine_std_write(buf voidptr, len int) int
fn C.valentine_single_instance(lock_path &char) int

// The shells report to the UI like the Windows ones (see conpty_windows.c.v):
// OSC 133;D;<exit code> after each command and OSC 9;9;"<cwd>" with each prompt.
// bash reads it from the environment; a .bashrc that sets its own PROMPT_COMMAND wins.
const bash_prompt_command = r'__valentine_c=$?; printf "\033]133;D;%s\a\033]9;9;\"%s\"\a" "$__valentine_c" "$PWD"'

// zsh starts with ZDOTDIR pointing here; this puts the user's ZDOTDIR back and reads their
// .zshenv, after which zsh reads their .zprofile/.zshrc as usual.
const zshenv = r'ZDOTDIR=${VALENTINE_USER_ZDOTDIR:-$HOME}
unset VALENTINE_USER_ZDOTDIR
[[ -f $ZDOTDIR/.zshenv ]] && source $ZDOTDIR/.zshenv
__valentine_precmd() { printf "\033]133;D;%s\a\033]9;9;\"%s\"\a" $? "$PWD" }
precmd_functions=(__valentine_precmd $precmd_functions)
claude() { command claude --settings "$VALENTINE_CLAUDE_SETTINGS" --mcp-config "$VALENTINE_MCP_CONFIG" "$@" }
'

const fish_init = r'function __valentine_status --on-event fish_postexec; printf "\e]133;D;%s\a" $status; end
function __valentine_cwd --on-event fish_prompt; printf "\e]9;9;\"%s\"\a" $PWD; end
function claude; command claude --settings $VALENTINE_CLAUDE_SETTINGS --mcp-config $VALENTINE_MCP_CONFIG $argv; end
'

// macOS terminals start login shells (that is where PATH is set up); Linux ones do not.
const shell_flags = $if macos { '-il' } $else { '-i' }

const nix_shells = ['zsh', 'bash', 'fish']

@[heap]
struct Pty {
mut:
	fd     int
	pid    int
	exited bool
	code   int
	closed bool
	mu     &sync.Mutex = sync.new_mutex()
}

fn open_pty(cmdline string, cwd string, cols int, rows int) !&Pty {
	mut p := &Pty{}
	rc := C.valentine_pty_open(dim(cols, 80), dim(rows, 24), &char(cmdline.str), &char(cwd.str),
		&p.fd, &p.pid)
	if rc != 0 {
		return error('forkpty failed (errno ${rc})')
	}
	return p
}

fn dim(v int, def int) int {
	if v <= 0 {
		return def
	}
	return if v > 1000 { 1000 } else { v }
}

// read returns bytes read, 0 for nothing yet, -1 once the shell is gone and drained.
fn (mut p Pty) read(buf voidptr, len int) int {
	n := C.valentine_pty_read(p.fd, buf, len)
	return if n == 0 && p.exited { -1 } else { n }
}

fn (mut p Pty) available() int {
	return C.valentine_pty_available(p.fd)
}

fn (mut p Pty) write(data string) {
	p.mu.@lock()
	defer {
		p.mu.unlock()
	}
	if !p.closed && data.len > 0 {
		C.valentine_pty_write(p.fd, data.str, data.len)
	}
}

fn (mut p Pty) resize(cols int, rows int) {
	p.mu.@lock()
	defer {
		p.mu.unlock()
	}
	if !p.closed {
		C.valentine_pty_resize(p.fd, dim(cols, 80), dim(rows, 24))
	}
}

fn (mut p Pty) kill() {
	p.mu.@lock()
	defer {
		p.mu.unlock()
	}
	if !p.closed && !p.exited { // once reaped, the pid may belong to someone else
		C.valentine_pty_kill(p.pid)
	}
}

// close_on_exit runs on its own thread and reaps the shell.
fn (mut p Pty) close_on_exit() {
	code := C.valentine_pty_wait(p.pid)
	p.mu.@lock()
	p.exited = true
	p.code = code
	p.mu.unlock()
}

// release closes the terminal once the reader is done and returns the exit code.
fn (mut p Pty) release() int {
	p.mu.@lock()
	defer {
		p.mu.unlock()
	}
	p.closed = true
	C.valentine_close_fd(p.fd)
	return p.code
}

// available_shells lists what the shell picker offers, the login shell first: it is
// also what a pane without a chosen shell gets.
fn available_shells() []string {
	mut shells := []string{}
	mut candidates := [os.file_name(os.getenv('SHELL'))]
	candidates << nix_shells
	for candidate in candidates {
		if candidate in nix_shells && candidate !in shells && os.exists_in_system_path(candidate) {
			shells << candidate
		}
	}
	return if shells.len > 0 { shells } else { ['sh'] }
}

fn shell_cmdline(shell string, history_file string) string {
	shells := available_shells()
	name := if shell in shells { shell } else { shells[0] }
	exe := sh_quote(os.find_abs_path_of_executable(name) or { '/bin/sh' })
	hist := 'HISTFILE=${sh_quote(history_file)}'
	return match name {
		'zsh' { '${hist} VALENTINE_USER_ZDOTDIR="\${ZDOTDIR:-\$HOME}" ZDOTDIR="\$VALENTINE_SHELL_DIR" exec ${exe} ${shell_flags}' }
		// shortcut: fish keeps one shared history; per pane would need fish_history names.
		'fish' { 'exec ${exe} ${shell_flags} -C \'source "\$VALENTINE_SHELL_DIR/valentine.fish"\'' }
		else { '${hist} exec ${exe} ${shell_flags}' }
	}
}

fn sh_quote(s string) string {
	return "'" + s.replace("'", "'\\''") + "'"
}

// prepare_shell_env sets what every shell inherits from us. Called once at startup.
fn prepare_shell_env() {
	// Started from inside Claude Code, these would make every pane's `claude` a "child
	// session" that keeps no transcript, so it could never be resumed.
	if os.getenv('CLAUDECODE') != '' {
		os.unsetenv('NO_COLOR')
	}
	os.unsetenv('CLAUDE_CODE_CHILD_SESSION')
	os.unsetenv('CLAUDECODE')
	os.setenv('TERM', 'xterm-256color', true)
	os.setenv('COLORTERM', 'truecolor', true)
	if os.getenv('LANG') == '' && os.getenv('LC_ALL') == '' {
		os.setenv('LANG', 'en_US.UTF-8', true) // apps started from Finder get no locale
	}
	os.setenv('PROMPT_COMMAND', bash_prompt_command, true)
	os.setenv('BASH_FUNC_claude%%',
		r'() { command claude --settings "$VALENTINE_CLAUDE_SETTINGS" --mcp-config "$VALENTINE_MCP_CONFIG" "$@"; }',
		true)
	dir := os.join_path(app_dir(), 'shell')
	os.setenv('VALENTINE_SHELL_DIR', dir, true)
	os.mkdir_all(dir) or {}
	os.write_file(os.join_path(dir, '.zshenv'), zshenv) or {
		eprintln('valentine: zsh integration: ${err}')
	}
	os.write_file(os.join_path(dir, 'valentine.fish'), fish_init) or {
		eprintln('valentine: fish integration: ${err}')
	}
}

// autostart_file is the login item: an XDG autostart entry, or a launchd agent on macOS.
fn autostart_file() string {
	$if macos {
		return os.join_path(os.home_dir(), 'Library', 'LaunchAgents',
			'com.github.tuntii.valentine.plist')
	}
	return os.join_path(os.config_dir() or { os.home_dir() }, 'autostart', 'valentine.desktop')
}

fn autostart_enabled() bool {
	return os.exists(autostart_file())
}

fn set_autostart(on bool) ! {
	path := autostart_file()
	if !on {
		os.rm(path) or {}
		return
	}
	exe := os.executable()
	os.mkdir_all(os.dir(path))!
	$if macos {
		xml := exe.replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;')
		os.write_file(path, '<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>com.github.tuntii.valentine</string>
<key>ProgramArguments</key><array><string>${xml}</string></array>
<key>RunAtLoad</key><true/>
</dict></plist>
')!
	} $else {
		os.write_file(path,
			'[Desktop Entry]\nType=Application\nName=Valentine\nExec="${exe}"\nX-GNOME-Autostart-enabled=true\n')!
	}
}

// Only the Edge fallback uses it, and there is no Edge to find here.
fn run_and_wait(cmdline string) ! {
	if os.system(cmdline) != 0 {
		return error('${cmdline} failed')
	}
}

// conpty_build tells xterm.js which ConPTY it talks to; 0: none, a real Unix pty.
fn conpty_build() int {
	return 0
}

fn single_instance() bool {
	path := os.join_path(os.temp_dir(), 'valentine-${os.getuid()}.lock')
	return C.valentine_single_instance(&char(path.str)) == 1
}

// shortcut: no tray on macOS/Linux, so the running window is not raised; add an IPC
// "show" message if people start Valentine twice expecting that.
fn show_existing() {
	eprintln('valentine: already running')
}
