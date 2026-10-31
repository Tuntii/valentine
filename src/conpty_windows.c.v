module main

import encoding.base64
import os
import sync

#include "@VMODROOT/src/conpty.h"
#flag windows -ladvapi32

fn C.valentine_pty_open(cols int, rows int, cmdline &u16, cwd &u16, hpc &voidptr, in_w &voidptr, out_r &voidptr, process &voidptr) int
fn C.valentine_pty_resize(hpc voidptr, cols int, rows int) int
fn C.valentine_pty_close(hpc voidptr)
fn C.valentine_pty_read(h voidptr, buf voidptr, len int) int
fn C.valentine_pty_write(h voidptr, buf voidptr, len int) int
fn C.valentine_pty_wait(process voidptr)
fn C.valentine_pty_kill(process voidptr)
fn C.valentine_pty_exit_code(process voidptr) int
fn C.valentine_close_handle(h voidptr)
fn C.valentine_run_and_wait(cmdline &u16) int
fn C.valentine_single_instance() int
fn C.valentine_show_existing()
fn C.valentine_windows_build() int
fn C.valentine_conpty_bundled() int
fn C.valentine_autostart_enabled() int
fn C.valentine_autostart_set(cmdline &u16) int
fn C.valentine_std_read(buf voidptr, len int) int
fn C.valentine_std_write(buf voidptr, len int) int

// Every shell reports to the UI through two sequences in its prompt:
//   OSC 133;D;<exit code>  the previous command finished (FinalTerm shell integration)
//   OSC 9;9;"<cwd>"         current directory (Windows Terminal convention)

// PowerShell: wraps whatever prompt the profile set up (oh-my-posh, starship, default).
// $__valentine_history is prepended per pane so each pane keeps its own PSReadLine history;
// it must be set before the first ReadLine, which is when PSReadLine loads the file.
const prompt_hook = r'if (Get-Module PSReadLine) { Set-PSReadLineOption -HistorySavePath $__valentine_history }
$global:__valentine_prompt = $function:prompt
function global:claude {
    $exe = Get-Command claude -CommandType Application -ErrorAction Stop | Select-Object -First 1
    & $exe.Source --settings $env:VALENTINE_CLAUDE_SETTINGS --mcp-config $env:VALENTINE_MCP_CONFIG @args
}
function global:prompt {
    $ok = $?
    # A failed cmdlet adds to $Error; a failed native program only sets $LASTEXITCODE,
    # which stays stale afterwards, so it is used only when no new error appeared.
    $err = $global:Error[0]
    $newErr = $err -and -not [object]::ReferenceEquals($err, $global:__valentine_err)
    $global:__valentine_err = $err
    $code = if ($ok) { 0 } elseif ($newErr -or -not $global:LASTEXITCODE) { 1 } else { $global:LASTEXITCODE }
    $e = [char]27
    $osc = "$e]133;D;$code$e\"
    $loc = $executionContext.SessionState.Path.CurrentLocation
    if ($loc.Provider.Name -eq "FileSystem") {
        $osc += "$e]9;9;`"$($loc.ProviderPath)`"$e\"
    }
    $osc + (& $global:__valentine_prompt)
}'

// cmd has no exit code in PROMPT, so it only reports "finished".
const cmd_prompt = r'$e]133;D$e\$e]9;9;"$P"$e\$P$G'

// cmd's equivalent of the PowerShell claude wrapper (doskey macros apply to typed input).
const cmd_claude_macro = r'doskey claude=claude --settings "%VALENTINE_CLAUDE_SETTINGS%" --mcp-config "%VALENTINE_MCP_CONFIG%" $*'

// Git Bash and WSL bash read it from the environment (WSL via WSLENV). BEL-terminated:
// Git Bash's console layer eats ESC-\ terminated OSC. A .bashrc that sets its own
// PROMPT_COMMAND wins. shortcut: no CWD/status then; append instead if it matters.
const bash_prompt_command = r'__valentine_c=$?; printf "\e]133;D;%s\a\e]9;9;\"%s\"\a" "$__valentine_c" "$(cygpath -w "$PWD" 2>/dev/null || wslpath -w "$PWD" 2>/dev/null || pwd)"'

@[heap]
struct Pty {
mut:
	hpc     voidptr
	in_w    voidptr
	out_r   voidptr
	process voidptr
	closed  bool
	mu      &sync.Mutex = sync.new_mutex()
}

fn open_pty(cmdline string, cwd string, cols int, rows int) !&Pty {
	mut p := &Pty{}
	rc := C.valentine_pty_open(dim(cols, 80), dim(rows, 24), cmdline.to_wide(), cwd.to_wide(),
		&p.hpc, &p.in_w, &p.out_r, &p.process)
	if rc != 0 {
		return error('ConPTY spawn failed (0x${u32(rc):08x})')
	}
	return p
}

fn dim(v int, def int) int {
	if v <= 0 {
		return def
	}
	return if v > 1000 { 1000 } else { v }
}

fn (mut p Pty) write(data string) {
	p.mu.@lock()
	defer {
		p.mu.unlock()
	}
	if !p.closed && data.len > 0 {
		C.valentine_pty_write(p.in_w, data.str, data.len)
	}
}

fn (mut p Pty) resize(cols int, rows int) {
	p.mu.@lock()
	defer {
		p.mu.unlock()
	}
	if !p.closed && p.hpc != unsafe { nil } {
		C.valentine_pty_resize(p.hpc, dim(cols, 80), dim(rows, 24))
	}
}

fn (mut p Pty) kill() {
	p.mu.@lock()
	defer {
		p.mu.unlock()
	}
	if !p.closed {
		C.valentine_pty_kill(p.process)
	}
}

// close_on_exit runs on its own thread: ConPTY keeps the output pipe open after the
// shell exits, so the pseudo console must be closed for the reader to see EOF.
fn (mut p Pty) close_on_exit() {
	C.valentine_pty_wait(p.process)
	p.mu.@lock()
	C.valentine_pty_close(p.hpc)
	p.hpc = unsafe { nil }
	p.mu.unlock()
}

// release frees the handles once the reader has hit EOF and returns the exit code.
fn (mut p Pty) release() int {
	p.mu.@lock()
	defer {
		p.mu.unlock()
	}
	p.closed = true
	code := C.valentine_pty_exit_code(p.process)
	C.valentine_close_handle(p.in_w)
	C.valentine_close_handle(p.out_r)
	C.valentine_close_handle(p.process)
	return code
}

// shell_cmdline returns the command line for a pane's shell; unknown or no longer
// installed shells fall back to PowerShell.
fn shell_cmdline(shell string, history_file string) string {
	if shell == 'cmd' {
		return 'cmd.exe /k ${cmd_claude_macro} & prompt ${cmd_prompt}'
	}
	if shell == 'gitbash' && git_bash() != '' {
		return '"${git_bash()}" --login -i'
	}
	if shell == 'wsl' && os.exists(wsl_exe) {
		return '"${wsl_exe}"'
	}
	exe := os.find_abs_path_of_executable('pwsh.exe') or { 'powershell.exe' }
	script := "\$__valentine_history = '${history_file.replace("'", "''")}'\n" + prompt_hook
	return '"${exe}" -NoLogo -NoExit -EncodedCommand ${encode_ps(script)}'
}

const wsl_exe = os.join_path(os.getenv('SystemRoot'), 'System32', 'wsl.exe')

fn git_bash() string {
	path := os.join_path(os.getenv('ProgramFiles'), 'Git', 'bin', 'bash.exe')
	return if os.exists(path) { path } else { '' }
}

// available_shells lists what the shell picker offers on this machine.
fn available_shells() []string {
	mut shells := ['powershell', 'cmd']
	if git_bash() != '' {
		shells << 'gitbash'
	}
	if os.exists(wsl_exe) {
		shells << 'wsl'
	}
	return shells
}

// prepare_shell_env sets what bash shells inherit from us. Called once at startup.
fn prepare_shell_env() {
	// Started from inside Claude Code, these would make every pane's `claude` a "child
	// session" that keeps no transcript, so it could never be resumed.
	if os.getenv('CLAUDECODE') != '' {
		os.unsetenv('NO_COLOR') // Claude's Bash tool sets it; panes would lose all color
	}
	os.unsetenv('CLAUDE_CODE_CHILD_SESSION')
	os.unsetenv('CLAUDECODE')
	os.setenv('PROMPT_COMMAND', bash_prompt_command, true)
	os.setenv('CHERE_INVOKING', '1', true) // Git Bash: start in the pane's cwd, not $HOME
	// bash imports exported functions from BASH_FUNC_<name>%% variables.
	os.setenv('BASH_FUNC_claude%%', r'() { command claude --settings "$VALENTINE_CLAUDE_SETTINGS" --mcp-config "$VALENTINE_MCP_CONFIG" "$@"; }',
		true)
	wslenv := os.getenv('WSLENV')
	os.setenv('WSLENV', if wslenv == '' { 'PROMPT_COMMAND' } else { '${wslenv}:PROMPT_COMMAND' },
		true)
}

// encode_ps encodes s the way -EncodedCommand expects: base64 of UTF-16LE.
fn encode_ps(s string) string {
	mut b := []u8{cap: s.len * 2}
	for r in s.runes() {
		mut units := [u16(r)]
		if u32(r) > 0xffff {
			v := u32(r) - 0x10000
			units = [u16(0xd800 + (v >> 10)), u16(0xdc00 + (v & 0x3ff))]
		}
		for u in units {
			b << u8(u & 0xff)
			b << u8(u >> 8)
		}
	}
	return base64.encode(b)
}

fn autostart_enabled() bool {
	return C.valentine_autostart_enabled() == 1
}

fn set_autostart(on bool) ! {
	rc := if on {
		C.valentine_autostart_set('"${os.executable()}"'.to_wide())
	} else {
		C.valentine_autostart_set(unsafe { nil })
	}
	if rc != 0 {
		return error('registry write failed (${rc})')
	}
}

fn run_and_wait(cmdline string) ! {
	rc := C.valentine_run_and_wait(cmdline.to_wide())
	if rc != 0 {
		return error('CreateProcess failed (${rc})')
	}
}

fn windows_build() int {
	return C.valentine_windows_build()
}

// conpty_build is the build whose ConPTY the panes really get, for xterm.js's reflow
// setting: the bundled conpty.dll reflows on resize like Windows' own does from 21376.
fn conpty_build() int {
	build := windows_build()
	return if C.valentine_conpty_bundled() == 1 && build < 21376 { 21376 } else { build }
}

fn single_instance() bool {
	return C.valentine_single_instance() == 1
}

fn show_existing() {
	C.valentine_show_existing()
}
