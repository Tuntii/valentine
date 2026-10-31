# Contributing to Valentine

Thanks for helping. Bug reports, fixes and new platform support are all welcome.

## Building

You need [V 0.5.2](https://github.com/vlang/v/releases/tag/0.5.2) (newer V removed the `json`
module Valentine still uses) and the WebView binding:

```
v install pushpak_jaiswal.webview
```

| Platform | Extra setup | Build |
|---|---|---|
| Windows | MinGW-w64 with `gcc`, `g++`, `windres` ([WinLibs](https://winlibs.com)); `v run <v>/vlib/db/sqlite/install_thirdparty_sqlite.vsh` | `v -cc gcc -subsystem windows -o valentine.exe src` |
| macOS | Xcode command line tools | `v -o valentine src` |
| Linux | `sudo apt install libsqlite3-dev pkg-config libgtk-3-dev libwebkit2gtk-4.1-dev` | `v -o valentine src` |

`-d edge` builds without the WebView binding (Windows: Edge app window, elsewhere: your browser).

Run the tests with `v test src` (`v -cc gcc test src` on Windows). CI runs them on all three
platforms for every pull request.

## Where things are

| | |
|---|---|
| `src/main.v` | startup, single instance, crash detection |
| `src/server.v` | the HTTP + WebSocket backend the UI talks to |
| `src/storage.v` | SQLite state (layout, cwd, scrollback) |
| `src/claude.v` | Claude Code hooks and the MCP server |
| `src/conpty_windows.c.v`, `src/conpty.h` | Windows: ConPTY, shells, autostart |
| `src/pty_nix.c.v`, `src/pty_unix.h` | macOS / Linux: forkpty, shells, autostart |
| `src/window*.v`, `src/window.h` | the native window |
| `src/ui/index.html` | the whole UI (xterm.js) |

## Commits and pull requests

Releases are automatic: [semantic-release](https://semantic-release.gitbook.io) reads the
commit messages on `main`, so they follow [Conventional Commits](https://www.conventionalcommits.org):

```
feat: restore zsh history per pane        -> minor release
fix(pty): reap shells that exit early     -> patch release
docs: explain the data folder             -> no release
feat!: drop the Edge fallback             -> major release
```

Pull requests are squash-merged, so it is the **PR title** that has to follow this format; a
check enforces it. Individual commits inside the PR can say anything.

Before opening a PR: run the tests, keep the change focused, and say in the description which
platforms you tried it on.
