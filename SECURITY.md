# Security policy

Valentine runs shells and exposes them to a local web UI and to AI agents (MCP), so a hole
here can mean code execution on the user's machine. Reports are taken seriously.

## Reporting

Please **do not open a public issue**. Use GitHub's
[private vulnerability reporting](https://github.com/Tuntii/valentine/security/advisories/new)
instead. You should get an answer within a week.

## Scope

Of particular interest:

- Anything that lets another local process, user or web page drive Valentine's shells without
  the per-session token (the HTTP server on `127.0.0.1:47100`, the WebSocket on `:47101`).
- The `valentine mcp` / `valentine hook` helpers and `session.json`.
- Links or terminal output that make Valentine open or run something locally.

Only the latest release is supported.
