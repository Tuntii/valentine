<p align="center"><img src="assets/valentine.png" width="96" alt="Valentine icon"></p>

<h1 align="center">Valentine</h1>

<p align="center">A multi-pane terminal for Windows that survives power cuts.</p>

When the PC goes down hard, every open terminal goes with it: the panes, their folders, their
scrollback, the dev servers you had running. Valentine keeps all of that in a SQLite database as
you work, and on the next start puts it back: same layout, same folders, scrollback restored,
startup commands re-run and Claude Code conversations resumed.

## Features

- **Split anything.** Panes form a free split tree, like Windows Terminal; drag the 1px dividers.
  Presets for 2×2, 3+2 and 1+3.
- **Crash-proof state.** Layout, each pane's folder and its scrollback are written continuously
  (SQLite in WAL mode). After an unexpected shutdown every pane is marked
  `RESTORED AFTER UNEXPECTED SHUTDOWN` and its shell starts in the folder it was in.
- **Startup commands.** Give a pane a command such as `npm run dev`; after a restore it runs
  after a 3-second countdown you can cancel with Esc.
- **Per-pane history.** In PowerShell each pane has its own command history.
- **Any shell.** PowerShell (pwsh if installed), cmd, Git Bash or WSL per pane.
- **Command status.** A pane's label shows when a background command is running, finished or
  failed, with its exit code.
- **Claude Code aware.** Claude in a pane gets a status badge (working / your turn / needs you)
  and is resumed after a crash. Shift+Enter inserts a newline.
- **Agents can drive Valentine.** A built-in MCP server lets Claude Code, OpenCode, Grok and
  other agents list panes, read their output, run commands and talk to each other
  (`ask_agent`).
- **Offline.** The UI (xterm.js) is compiled into the exe.

## Install

Valentine is a single `valentine.exe`. Until there are release builds, build it yourself:

1. Install [V](https://github.com/vlang/v) and a MinGW-w64 toolchain with `gcc`, `g++` and
   `windres` (for example [WinLibs](https://winlibs.com) or MSYS2).
2. Get SQLite for V and the WebView2 binding:
   ```
   v run <path-to-v>/vlib/db/sqlite/install_thirdparty_sqlite.vsh
   v install PUSHPAK-JAISWAL.webview
   ```
3. Build:
   ```
   v -cc gcc -prod -subsystem windows -o valentine.exe src
   ```
   Without the WebView2 binding, `-d edge` builds a version that opens in Edge's app mode.

4. Recommended on Windows 10: put Microsoft's current ConPTY next to the exe. The one built
   into Windows 10 is years old and garbles TUIs such as Claude Code (misplaced cursor,
   redraws in the wrong place). The script downloads it from NuGet and checks that it is
   signed by Microsoft:
   ```
   powershell -ExecutionPolicy Bypass -File tools\fetch-conpty.ps1
   ```
   Valentine uses `conpty.dll` + `OpenConsole.exe` when they sit next to it, and the system
   ConPTY otherwise.

Run the tests with `v -cc gcc test src`.

## Using it

| | |
|---|---|
| Split right / down | `Alt+Shift+=` / `Alt+Shift+-` (`Alt+Shift+D` picks the longer side) |
| Move between panes | `Alt+Arrow` |
| Resize | `Alt+Shift+Arrow`, or drag a divider |
| Maximize / restore | `Ctrl+Shift+Enter` |
| Close pane | `Ctrl+Shift+W` |
| Copy / paste | `Ctrl+C` with a selection / `Ctrl+V` |
| Open a link | `Ctrl+Click` |
| Everything else | right-click a pane: rename, startup command, shell, layouts, start with Windows |

Double-click a pane's label to rename it.

## Agents

Inside Valentine, `claude` automatically loads Valentine's hooks and MCP server for that session
only; your own Claude Code settings are not touched. To give other agents the same tools,
register the server once:

```
grok mcp add -s user valentine "C:\path\to\valentine.exe" -- mcp
opencode mcp add --global valentine -- "C:\path\to\valentine.exe" mcp
```

Tools: `list_panes`, `read_pane`, `run_command`, `send_text`, `open_pane`, `close_pane` and
`ask_agent`, which types a message into another agent's pane and returns its answer.

## Where things live

Everything is under `%APPDATA%\Valentine`: the state database, per-pane histories and the
WebView2 profile. Delete the folder to start from scratch.

## License

MIT, see [LICENSE](LICENSE). xterm.js is MIT licensed, see
[src/ui/vendor/LICENSE-xterm](src/ui/vendor/LICENSE-xterm).
