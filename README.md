# Cobuddy Bridge

Multi-account token rotator for CodeBuddy CLI (`codebuddy.ai` -- global version, NOT China `codebuddy.cn`). Provides a TUI for account management + an HTTP OpenAI-compatible proxy.

---

<img width="1898" height="922" alt="Image" src="https://github.com/user-attachments/assets/0f8b5af3-59e5-4a90-a32c-9841e91d8d90" />

---

**Auth is CodeBuddy-specific.** Accounts are added through CodeBuddy's official OAuth flow, which uses GitHub as its identity provider. Users log into CodeBuddy via GitHub in a browser and obtain a session code. This bridge does not directly support Google OAuth or other providers -- to extend it, a separate auth flow would need to be implemented.

## Quick Start

```bash
./build           # Compile single binary
./run             # Run TUI + HTTP proxy (server auto-starts)
./run server      # Run HTTP proxy only (headless, no TUI)
```

## Prerequisites

- Dart SDK 3.10.8+
- `wl-copy` or `xclip` for clipboard (optional, Linux only; falls back to OSC 52)

## Platform Support

| Platform | Status |
|----------|--------|
| Linux | Primary -- fully tested |
| macOS | Experimental -- clipboard via OSC 52 only (no wl-copy/xclip) |
| Windows | Not tested -- bash scripts (`./build`, `./run`) need adaptation |

## TUI Mode

The proxy server starts automatically when running `./run`. The TUI and server run in the same process.

```bash
./run
```

### Layout

```
Cobuddy Bridge | my-session-label              3/3 ok
▸ http://127.0.0.1:20130

Accounts: ~/.config/codebuddy/accounts/   [c] copy
─────────────────────────────────────────────────────
  ✓ my-session-label  ▶ CURRENT
    OK  ·  2026-07-19 09:44
    6bc6109b1a82f39a  ·  remaining=42
  ✓ session-2
    OK  ·  2026-07-19 10:12
    ab1234cd5678ef90  ·  remaining=100

Ready                   [a]dd [d]el [e]nable [s]et [t]est [r]strat [R]otate [p]ort [Ctrl+L] log [h]elp [q]uit
```

Header displays:
- Application name
- Current session name (cyan, if set)
- OK/total account count (grey)
- Server proxy URL (green)

Each account is rendered as 3 full lines:
- **Line 1**: cursor, badge (`✓`/`✗`/`!`/`⚠`), label, `▶ CURRENT`, `DISABLED`
- **Line 2**: state (`OK`/`EXPIRED`/`EXHAUSTED`/`ERROR`) + creation date
- **Line 3**: account ID (16-char hash) + state message from quota probe

### Panel Navigation

| Panel | Description |
|-------|-------------|
| Main | Account list, keyboard navigation |
| Add URL | Auth URL with copy box + instructions |
| Import | Two-field form (Label + State), submit on Enter |
| Delete | Account deletion confirmation |
| Strategy | Rotation strategy selector (4 options) |
| Request Count | N input for request-count strategies |
| Port Config | Change the proxy server port |
| Quit | Exit confirmation |
| Help | Scrollable help screen |

### Key Bindings

| Key | Context | Action |
|-----|---------|--------|
| `a` | Main | Add account (start login flow) |
| `d` | Main | Delete selected account (with confirmation) |
| `e` | Main | Toggle enable/disable |
| `s` | Main | Set as current session |
| `t` | Main | Test/probe selected account |
| `r` | Main | Open rotation strategy selector |
| `R` | Main | Force rotate |
| `c` | Main | Copy storage path to clipboard |
| `h` | Main | Open help panel |
| `q` | Main | Quit (with confirmation) |
| `p` | Main | Open port configuration |
| `↑/↓` | Account list, Strategy, Help, Port Config | Navigate |
| `y/n` | Delete, Quit | Confirm / cancel |
| `Enter` | Add URL | Proceed to import panel |
| `Enter` | Strategy | Select strategy / confirm |
| `Enter` | Import | Submit import |
| `Esc` | Any sub-panel | Back to main |
| `Tab` | Import | Switch focus between Label and State |
| `c` | Add URL | Copy auth URL to clipboard |
| `Enter` | Add URL | Proceed to import panel |

### Log Panel (`Ctrl+L`)

Records all bridge activity in real time -- proxy requests, token refresh, rotation, probes, errors.

Three display modes:
1. **Closed** (default) -- log not shown
2. **Sidebar** (`Ctrl+L`) -- log on the right (40% width), main panel stays interactive
3. **Fullscreen** (`f` in sidebar) -- log fills the entire body

```
───────────────────── Monday, 20 July 2026 ─────────────────────
[00:17:40] [OK]  Rotated to my-session (6bc6109b)
[00:05:12] [ERR] Token refresh failed: 401
[00:00:22] [INF] Probe: remaining=42
───────────────────── Sunday, 19 July 2026 ─────────────────────
[23:51:11] [WRN] No healthy accounts available
```

5 color-coded levels: `ERR` (red), `WRN` (yellow), `OK` (green), `INF` (cyan), `DBG` (grey).

Key bindings when log is active:
| Key | Action |
|-----|--------|
| `Ctrl+L` | Toggle sidebar on/off |
| `f` | Toggle sidebar / fullscreen |
| `C` | Clear all log entries |
| `O` | Clear entries before today |

Log is persisted to `~/.config/codebuddy/logs.jsonl` (max 2000 entries).

### Rotation Strategy (`r`)

Four rotation strategies:
- **exhausted-next** -- advance when exhausted, next in order
- **exhausted-random** -- advance when exhausted, random pick
- **request-count-next** -- advance every N API requests, in order
- **request-count-random** -- advance every N API requests, random

Request-count strategies prompt for N (1-999999).

### Port Configuration (`p`)

Change the proxy server port from the TUI (`p` key). The default port is **20130**.

When opening the port config panel, the TUI scans a list of recommended ports and displays which ones are currently available (not in use). Pick one from the list or type any port in the 1024-65535 range.

Recommended ports (scanned dynamically): `20130, 3010, 4001, 9090, 3001, 5001, 20131, 10000, 18080, 65432`

Note: changing the port requires a restart of the application to take effect.

Note: changing the port requires a restart of the application to take effect.

### Add Account Flow (CodeBuddy-specific)

1. Press `a` in main panel
2. Copy the auth URL (`c` key or click the URL box)
3. Open the URL in a browser where you have a CodeBuddy session (GitHub login)
4. After GitHub login, the browser redirects to a URL containing `session_code=<uuid>`
5. Copy the `session_code` value from the URL bar
6. Press `Enter` to enter the import panel
7. Optionally enter a label (defaults to "my-session" with auto-dedup)
8. Tab to the State field, paste the session_code
9. Press `Enter` to exchange the code for tokens and create the account

Label auto-dedup: if "my-session" already exists, creates "my-session(1)", "my-session(2)", etc.

### Status Bar

Bottom bar with color-coded status level system:
- **Ready** (white) -- waiting for input
- **Info** (cyan) -- operation in progress
- **Success** (green) -- operation completed
- **Warning** (yellow) -- confirmation required
- **Error** (red) -- operation failed

Status auto-clears after 2-5 seconds depending on severity.

### Help Panel (`h`)

Scrollable help screen covering all key bindings, panel descriptions, rotation strategies, add account flow, and storage locations.

## Server Mode (HTTP Proxy, headless)

For headless/server-only mode (no TUI):

```bash
./run server
```

The proxy also auto-starts in TUI mode (`./run`), so this is only needed when you want a pure daemon without the terminal interface.

OpenAI-compatible proxy at `http://127.0.0.1:20130`.

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/v1/chat/completions` | POST | Chat proxy (rewrites to `/v2/...`) |
| `/v1/token` | GET | Get current access token |
| `/v1/connections` | GET | List all accounts |
| `/v1/health` | GET | Health check |
| `/v1/config` | GET/PATCH | View/update config |
| `/v1/logs` | GET | Activity logs (real-time) |

## Storage

All data lives under `~/.config/codebuddy/`:
- `accounts/<id>.json` -- one JSON file per account
- `state.json` -- rotation state (current session, counters)
- `config.json` -- config (rotation strategy, etc.)
- `logs.jsonl` -- activity log (JSONL, max 2000 entries)

The storage path is visible in the TUI header and can be copied with `c`.

## Build & Scripts

| Command | Description |
|---------|-------------|
| `./build` | `dart pub get` + `dart compile exe` |
| `./run` | Run TUI (args like `server` are forwarded) |

## Test

```bash
dart test
```

123 tests covering models, services (oauth, rotator), and server proxy.

## Project Structure

```
cobuddy-bridge/
├── bin/
│   ├── cobuddy_bridge.dart   # Entry point
│   └── cobuddy_bridge        # Compiled binary (git-ignored)
├── lib/src/
│   ├── main.dart             # CLI arg parser, wiring
│   ├── models/
│   │   ├── account.dart      # Account model, Store, RotatorState
│   │   └── config.dart       # Config model
│   ├── services/
│   │   ├── log_store.dart    # Centralized activity log (JSONL)
│   │   ├── oauth.dart        # OIDC, PKCE, token exchange
│   │   └── rotator.dart      # Rotation strategies
│   ├── server/
│   │   └── proxy.dart        # HTTP server + OpenAI proxy
│   └── tui/
│       └── app.dart          # Nocterm TUI (8 panels, log, help)
├── test/
│   ├── models/
│   ├── server/
│   └── services/
├── AGENTS.md                 # Architecture docs
├── README.md
├── build                     # Build script (executable)
├── run                       # Run script (executable)
└── pubspec.yaml
```
