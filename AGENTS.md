# Cobuddy Bridge

Multi-account token rotator for CodeBuddy CLI (`codebuddy.ai` -- global version, NOT China `codebuddy.cn`). Provides a TUI for account management + an HTTP OpenAI-compatible proxy for use with OpenCode or any OpenAI-compatible client.

**Auth is CodeBuddy-specific.** The add account flow uses CodeBuddy's official OAuth endpoints (`/v2/plugin/auth/state`, `/v2/plugin/auth/token`). CodeBuddy uses GitHub as its identity provider. Google OAuth is not directly supported.

## Architecture

### Stack
- **Language**: Dart 3.10+
- **TUI**: `nocterm` v0.8.0 (Flutter-like component system, `StatefulComponent`, `Focusable`, `GestureDetector`)
- **Server**: `dart:io` `HttpServer` (no framework, pure stdlib)
- **HTTP client**: `package:http`
- **Crypto**: `package:crypto`
- **Compile**: `dart compile exe` -> single binary (~9 MB)

### Platform Support

| Platform | Status |
|----------|--------|
| Linux | Primary -- fully tested |
| macOS | Experimental -- clipboard via OSC 52 only (no wl-copy/xclip) |
| Windows | Not tested -- bash scripts need adaptation |

### File Structure

```
cobuddy-bridge/
├── bin/cobuddy_bridge.dart         # Entry point (3 lines)
├── lib/
│   ├── cobuddy_bridge.dart         # Barrel re-export
│   └── src/
│       ├── main.dart               # CLI arg parser, wires services
│       ├── models/
│       │   ├── account.dart        # Account model, RotatorState, Store (JSON file persistence)
│       │   └── config.dart         # Config model + JSON load/save
│       ├── services/
│       │   ├── log_store.dart      # Centralized activity log (JSONL file, max 2000 entries)
│       │   ├── oauth.dart          # OIDC discovery, PKCE, device auth, exchange, refresh, quota probe
│       │   └── rotator.dart        # Strategy-aware token rotation, probe, advance
│       ├── server/
│       │   └── proxy.dart          # HTTP server, 18+ REST endpoints, OpenAI proxy
│       └── tui/
│           └── app.dart            # Nocterm TUI (8 panels, log sidebar/fullscreen, 1100+ lines)
├── test/
│   ├── models/
│   ├── server/
│   └── services/
├── AGENTS.md                       # Architecture docs
├── README.md
├── build                           # Build script (executable)
├── run                             # Run script (executable)
└── pubspec.yaml
```

## Key Design Decisions

### 1. Single Binary
`dart compile exe` produces a single native binary. No VM. No runtime deps. Just `./bin/cobuddy_bridge`.

### 2. TUI vs Server Mode
Two modes, same binary:

| Mode | Command | Behavior |
|------|---------|----------|
| TUI | `./bin/cobuddy_bridge` | Interactive terminal UI (proxy server auto-starts) |
| Server | `./bin/cobuddy_bridge server` | HTTP proxy daemon only, no TUI |

Both share the same account storage at `~/.config/codebuddy/accounts/`. In TUI mode, the proxy server starts automatically alongside the terminal interface -- both run in the same process.

### 3. Storage Format

Each account = one JSON file at `~/.config/codebuddy/accounts/<id>.json`.

The Account schema (`lib/src/models/account.dart`):
```json
{
  "id": "6bc6109b1a82f39a",
  "label": "my-account",
  "user_id": "",
  "email": "",
  "enabled": true,
  "priority": 1,
  "state": "ok",
  "state_msg": "",
  "access_token": "eyJ...",
  "refresh_token": "...",
  "expires_at": "2026-07-19T10:44:54.159322",
  "created_at": "2026-07-19T09:44:54.159447",
  "last_used_at": null,
  "use_count": 0
}
```

Account states: `ok` `unknown` `expired` `exhausted` `error`

Rotation state persisted at `~/.config/codebuddy/state.json`.

Config persisted at `~/.config/codebuddy/config.json`.

### 4. Proxy Path
CodeBuddy's chat endpoint is at **`/v2/chat/completions`** (NOT `/v1/chat/completions`). The proxy rewrites incoming `/v1/chat/completions` -> upstream `/v2/chat/completions`.

## TUI Layout

### Header
```
Cobuddy Bridge | my-session-label              3/3 ok
▸ http://127.0.0.1:20130
```
- App name + current session label (cyan) + account count (grey)
- Server URL (green) with arrow indicator

### Account List
```
Accounts: ~/.config/codebuddy/accounts/   [c] copy
─────────────────────────────────────────────────────
  ✓ my-session-label  ▶ CURRENT
    OK  ·  2026-07-19 09:44
    6bc6109b1a82f39a  ·  remaining=42
```
- Clickable storage path header (GestureDetector + `_doCopyPath`)
- Each account = 3 lines: badge+label+tags / state+date / id+msg
- Badges: `✓` (ok/green), `✗` (expired/red), `!` (exhausted/yellow), `⚠` (error/red)
- Tags: `▶ CURRENT` (cyan), `DISABLED` (grey)

### Status Bar
Bottom bar with colored status level system:
| Level | Color | Usage |
|-------|-------|-------|
| Ready | White | Waiting for input |
| Info | Cyan | Operation in progress |
| Success | Green | Operation completed |
| Warning | Yellow | Needs confirmation |
| Error | Red | Operation failed |

Status auto-clears after 2-5 seconds depending on severity. Uses `Timer` (`_statusTimer`) with `_setStatus(level, duration)`.

### Log Panel (`Ctrl+L`)
Replaces the right side of the screen (or fills it in fullscreen mode). Shows real-time activity from LogStore.

```
──────────────── Monday, 20 July 2026 ────────────────
[00:17:40] [OK]  Rotated to my-session (6bc6109b)
[00:05:12] [ERR] Token refresh failed: 401
```

5 log levels: `ERR` (red), `WRN` (yellow), `OK` (green), `INF` (cyan), `DBG` (grey).

Date separators between days (e.g., `──────────────── Monday, 20 July 2026 ────────────────`).

Three modes:
1. **Closed** -- log not shown, `_showLog = false`
2. **Sidebar** -- 40% width right panel, border + padding, `_showLog = true, _logFullscreen = false`
3. **Fullscreen** -- log fills entire body, `_showLog = true, _logFullscreen = true`

Log cleared with `C` (all) or `O` (entries before today).

## TUI Panels (8 panels)

`AppState._panel` field controls which panel is shown. All panels are components rendered by `_body()`:

| Panel | Enum | Trigger | Description |
|-------|------|---------|-------------|
| Main | `_Panel.main` | Default | Account list with keyboard navigation |
| Add URL | `_Panel.addUrl` | `a` | Auth URL + GestureDetector copy box + instructions |
| Import | `_Panel.import` | Enter in Add URL | Two-field form (Label + State) with Tab focus switching |
| Delete | `_Panel.delete` | `d` | Confirmation dialog with account name + id |
| Strategy | `_Panel.strategy` | `r` | 4-option radio list with current indicator |
| Request Count | `_Panel.requestCount` | Enter in Strategy | N input for request-count strategies |
| Quit | `_Panel.quit` | `q` | Confirmation dialog with server URL warning |
| Help | `_Panel.help` | `h` | Scrollable help screen with all key bindings and docs |

All dialog panels use `Container` with `BoxDecoration(border: ...)` centered via `Center` widget.

## TUI Key Bindings

| Key | Panel | Action |
|-----|-------|--------|
| `a` | Main | Start add flow (get login URL) |
| `d` | Main | Open delete confirmation dialog |
| `e` | Main | Toggle selected account enabled/disabled |
| `s` | Main | Set selected account as current session |
| `t` | Main | Test/probe selected account |
| `r` | Main | Open rotation strategy selector |
| `R` | Main | Force rotate to next OK account |
| `q` | Main | Open quit confirmation dialog |
| `h` | Main | Open help panel |
| `c` | Main | Copy storage path to clipboard |
| `↑/↓` | Main, Strategy, Help | Navigate |
| `y/n` | Delete, Quit | Confirm / cancel |
| `c` | Add URL | Copy auth URL to clipboard |
| `Enter` | Add URL | Proceed to import panel |
| `Esc` | Any sub-panel | Back to main |
| `Tab` | Import | Switch focus between Label and State fields |
| `Enter` | Import | Submit import |
| `Enter` | Strategy | Select strategy / confirm request count |
| `Esc` | Import, Strategy, Request Count | Back to previous panel |
| F | Add URL (box) | Click to copy URL |
| - Path row | Main | Click to copy storage path |
| `Ctrl+L` | Any | Toggle log sidebar on/off (when log closed) |
| `Ctrl+L` | Any | Close log (when log open) |
| `f` | Log open | Toggle sidebar / fullscreen |
| `C` | Log open | Clear all log entries |
| `O` | Log open | Clear entries before today |
| `h` | Help | Close help |

Key bindings in `_footer()` are dynamic -- only relevant keys shown per panel. Colors match panel theme.

## Rotation Strategies

Defined in `lib/src/services/rotator.dart` and `lib/src/models/config.dart`. The old `quota-aware`, `per-request`, `round-robin` names were replaced with 4 concrete strategies:

| Strategy Enum | Label | Behavior |
|---------------|-------|----------|
| `exhaustedNext` | exhausted-next | Advance when exhausted, next in order |
| `exhaustedRandom` | exhausted-random | Advance when exhausted, random pick |
| `requestCountNext` | request-count-next | Advance every N API requests, in order |
| `requestCountRandom` | request-count-random | Advance every N API requests, random |

The `requestCountNext` and `requestCountRandom` strategies prompt for N (1-999999) via `_requestCountPanel()`.

Strategy selector (`_strategyPanel()`) shows a centered dialog with radio buttons. Current strategy marked with `◉`. Selection confirmed with `Enter`.

The rotator also auto-refreshes tokens when near expiry (uses `refresh_token`).

## Add Account Flow (CodeBuddy-specific)

```
1. Press [a] in main panel
2. TUI calls OAuthClient.startLoginOfficial()
   -> POST https://www.codebuddy.ai/v2/plugin/auth/state?platform=cli
   -> Returns { authUrl, state }
3. TUI shows the auth URL
4. Press [c] to copy URL to clipboard (or click URL box)
5. Open URL in browser where you have CodeBuddy session (GitHub login)
6. Browser redirects to URL like: https://www.codebuddy.ai/broker/after-post-broker-login?session_code=<uuid>
7. Copy the session_code value from the URL bar
8. Press [Enter] to enter import panel
9. Enter label (optional, defaults to "my-session" with auto-deduplication)
10. Tab to State field, paste session_code
11. Press Enter -> TUI calls OAuthClient.fetchTokenByState(state)
    -> GET https://www.codebuddy.ai/v2/plugin/auth/token?state=<uuid>
    -> Returns { accessToken, refreshToken, expiresIn, ... }
12. Account created with state=ok, stored as <id>.json
```

Label auto-deduplication: if "my-session" already exists, creates "my-session(1)", "my-session(2)", etc.

## LogStore (`lib/src/services/log_store.dart`)

Centralized activity logging system:
- In-memory `Queue<LogEntry>` (max 2000 items)
- Persisted to `~/.config/codebuddy/logs.jsonl` (JSONL format, one JSON object per line)
- 5 levels: `info`, `success`, `error`, `warning`, `debug`
- Static methods: `info()`, `success()`, `error()`, `warning()`, `debug()`
- Static helpers: `entries`, `latestFirst`, `clear()`, `clearBeforeToday()`, `countBeforeToday()`
- Written to file on every `add()` call via `_appendToFile()`
- Rewritten on overflow (removes oldest) via `_rewriteFile()`
- Loaded from file on init via `_loadFromFile()`
- Integrated throughout TUI: proxy requests, token refresh, rotation, probe, errors, strategy changes

## Quota Probe Logic

`interpretQuotaResponse` in `rotator.dart` distinguishes between:
- HTML 401/403 -> APISIX/openresty (token valid but wrong scope -> leave state alone)
- JSON 401/403 -> real auth failure -> mark expired
- 200 with quota fields (`remaining`, `balance`, etc.) -> mark ok/exhausted
- 200 HTML -> inconclusive (leave state alone)
- 429 -> mark exhausted

## HTTP API Endpoints

All served by `ProxyServer` in `lib/src/server/proxy.dart`:

| Method | Path | Description |
|--------|------|-------------|
| GET | `/v1/health` | Health check |
| GET | `/v1/config` | Get config |
| PATCH | `/v1/config` | Update config |
| GET | `/v1/logs` | Get logs |
| GET | `/v1/connections` | List accounts |
| POST | `/v1/connections/import` | Import account (JSON body with `access_token`, `label`, etc.) |
| POST | `/v1/connections/login-official` | Start official auth flow (returns `auth_url`, `state`) |
| POST | `/v1/connections/import-session` | Import via session_code |
| POST | `/v1/connections/test-all` | Probe all accounts |
| GET | `/v1/connections/:id` | Get single account |
| DELETE | `/v1/connections/:id` | Delete account |
| PATCH | `/v1/connections/:id` | Update account fields |
| POST | `/v1/connections/:id/test` | Probe single account |
| POST | `/v1/connections/:id/reset` | Reset state to unknown |
| POST | `/v1/rotation/rotate` | Force rotate |
| GET | `/v1/rotation/state` | Get rotation state |
| GET | `/v1/token` | Get current access token (plain text) |
| POST | `/v1/chat/completions` | OpenAI-compatible chat proxy |
| GET | `/v1/models` | List available models |

## OpenCode Configuration

```jsonc
"CodeBuddy": {
  "name": "CodeBuddy OpenAI Compatible",
  "options": {
    "baseURL": "http://127.0.0.1:20130/v1",
    "apiKey": "anything"
  },
  "models": {
    "gpt-5.4": {
      "name": "CodeBuddy - GPT 5.4",
      "attachment": true,
      "tool_call": true,
      "temperature": true,
      "reasoning": true,
      "limit": {
        "context": 1048576,
        "input": 1048576,
        "output": 8192
      },
      "modalities": {
        "input": ["text"],
        "output": ["text"]
      }
    }
  }
}
```

## Compilation & Build

```bash
# Build single binary
./build

# Run
./bin/cobuddy_bridge         # TUI mode (server auto-starts)
./bin/cobuddy_bridge server  # Headless server mode
```

`./build` runs `dart pub get` then `dart compile exe bin/cobuddy_bridge.dart`.

## Migration from Go Version

This is a complete rewrite of the original Go project at `~/App/codebuddy/`. Key differences:

| Aspect | Go (old) | Dart (new) |
|--------|----------|------------|
| Framework | Bubbletea + net/http | Nocterm + dart:io HttpServer |
| TUI quality | Poor (modal/input issues) | 8 panels, log sidebar/fullscreen, colored status bar |
| Binary size | 12 MB | 9 MB |
| Lines of code | ~3600 (7 files) | ~2500 (9 files) |
| Storage format | Same (JSON per account) | Same (backward compatible) |
| Proxy path | `/v2` (fixed) | `/v2` |
| Clipboard | No | wl-copy/xclip stdin pipe, fallback OSC 52 |
| Terminal cleanup | `exit(0)` -> garbage chars | `shutdownApp()` -> clean |
| Rotation strategies | 3 (named) | 4 (exhausted-next/random, request-count-next/random) |
| Activity log | In-memory only | Persisted JSONL (2000 entries), sidebar/fullscreen view |
| Label dedup | None | Auto-deduplicate (my-session(1), my-session(2), ...) |

## Known Issues / Gotchas

- Login URL flow requires browser with active CodeBuddy session (GitHub auth)
- Session_code expires after a few minutes -- must paste quickly
- Quota probe returns HTML 401 from APISIX for valid tokens (handled gracefully -- leaves state alone)
- Clipboard: native `wl-copy`/`xclip` via stdin pipe (priority), fallback OSC 52
- `nocterm` `TextField` consumes Enter key -- import uses `onSubmitted` callback, not root `Focusable` handler
- `LogStore.init()` is called in both `main.dart` and `app.dart` -- a duplicate call bug (only needs one call in `main.dart`)
- Scrollbar thumb width = 1 col, overwrites the rightmost character of content
- LogStore file rewrite on overflow can be slow with 2000 entries (~100KB JSONL)
