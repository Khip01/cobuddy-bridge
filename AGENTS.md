# Cobuddy Bridge

Multi-account token rotator untuk CodeBuddy CLI (`codebuddy.ai` — **global version, NOT China `codebuddy.cn`**). Menyediakan TUI untuk manajemen akun + HTTP proxy OpenAI-compatible untuk digunakan dengan OpenCode atau client lain.

## Architecture

### Stack
- **Bahasa**: Dart 3.10+
- **TUI**: `nocterm` v0.8.0 (Flutter-like component system, `StatefulComponent`, `Focusable`)
- **Server**: `dart:io` `HttpServer` (no framework, pure stdlib)
- **HTTP client**: `package:http`
- **Crypto**: `package:crypto`
- **Compile**: `dart compile exe` → single binary (~9 MB)

### File Structure

```
cobuddy-bridge/
├── bin/codebuddy.dart              # Entry point (3 lines)
├── lib/
│   ├── codebuddy.dart              # Barrel re-export
│   └── src/
│       ├── main.dart               # CLI arg parser, wires services
│       ├── models/
│       │   ├── account.dart        # Account model, RotatorState, Store (JSON file persistence)
│       │   └── config.dart         # Config model + JSON load/save
│       ├── services/
│       │   ├── oauth.dart          # OIDC discovery, PKCE, device auth, exchange, refresh, quota probe
│       │   └── rotator.dart        # Strategy-aware token rotation, probe, advance
│       ├── server/
│       │   └── proxy.dart          # HTTP server, 15+ REST endpoints, OpenAI proxy
│       └── tui/
│           └── app.dart            # Nocterm TUI (Focusable, keybinds, 3 panels)
```

## Key Design Decisions

### 1. Single Binary
`dart compile exe` produces a single native binary. No VM. No runtime deps. Just `./bin/cobuddy_bridge`.

### 2. TUI vs Server Mode
Two modes, same binary:

| Mode | Command | Behavior |
|------|---------|----------|
| TUI | `./bin/cobuddy_bridge` | Interactive terminal UI |
| Server | `./bin/cobuddy_bridge server` | HTTP proxy daemon on `:20130` |

Both share the same account storage at `~/.config/codebuddy/accounts/`.

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
CodeBuddy's chat endpoint is at **`/v2/chat/completions`** (NOT `/v1/chat/completions`). The proxy rewrites incoming `/v1/chat/completions` → upstream `/v2/chat/completions`.

## TUI Key Bindings

| Key | Panel | Action |
|-----|-------|--------|
| `a` | Main | Start add flow (get login URL) |
| `d` | Main | Delete selected account |
| `t` | Main | Test/probe selected account |
| `r` | Main | Force rotate to next OK account |
| `q` | Main | Quit (clean shutdown via `shutdownApp()`) |
| `↑/↓` | Main | Navigate account list |
| `c` | Add URL | Copy auth URL to clipboard (OSC 52 → xclip → wl-copy) |
| `Enter` | Add URL | Proceed to import panel |
| `Esc` | Add URL / Import | Cancel, return to main |
| `Tab` | Import | Switch focus between Label and State fields |
| `Enter` | Import | Submit import (via `onSubmitted` on both TextFields) |

### TUI States
- `_Panel.main` — account list, keyboard navigation
- `_Panel.addUrl` — shows auth URL, copy instructions
- `_Panel.import` — two-field form (Label + State), submit on Enter

No dummy data. No hardcoded accounts. State comes entirely from JSON files on disk.

## Add Account Flow

```
1. Press [a] in main panel
2. TUI calls OAuthClient.startLoginOfficial()
   → POST https://www.codebuddy.ai/v2/plugin/auth/state?platform=cli
   → Returns { authUrl, state }
3. TUI shows the auth URL
4. Press [c] to copy URL to clipboard (OSC 52 → xclip → wl-copy)
5. Open URL in browser where you have CodeBuddy session (GitHub login)
6. Browser redirects to URL like: https://www.codebuddy.ai/broker/after-post-broker-login?session_code=<uuid>
7. Copy the session_code value from the URL bar
8. Press [Enter] to enter import panel
9. Paste session_code into State field (Tab to switch fields)
10. Press Enter → TUI calls OAuthClient.fetchTokenByState(state)
    → GET https://www.codebuddy.ai/v2/plugin/auth/token?state=<uuid>
    → Returns { accessToken, refreshToken, expiresIn, ... }
11. Account created with state=ok, stored as <id>.json
```

## Rotation Strategies

Defined in `lib/src/services/rotator.dart` and `lib/src/models/config.dart`:

| Strategy | Behavior |
|----------|----------|
| `quota-aware` | Stay on current account until exhausted/expired, then advance |
| `per-request` | Rotate every N API calls (`requests_per_rotation`) |
| `round-robin` | Rotate every N seconds (`rotation_interval_s`) |

The rotator also auto-refreshes tokens when near expiry (uses `refresh_token`).

## Quota Probe Logic

`interpretQuotaResponse` in `rotator.dart` distinguishes between:
- HTML 401/403 → APISIX/openresty (token valid but wrong scope → leave state alone)
- JSON 401/403 → real auth failure → mark expired
- 200 with quota fields (`remaining`, `balance`, etc.) → mark ok/exhausted
- 200 HTML → inconclusive (leave state alone)
- 429 → mark exhausted

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
dart pub get
dart compile exe bin/codebuddy.dart

# Run
./bin/cobuddy_bridge         # TUI mode
./bin/cobuddy_bridge server  # Server mode
```

## Migration from Go Version

This is a complete rewrite of the original Go project at `~/App/codebuddy/`. Key differences:

| Aspect | Go (old) | Dart (new) |
|--------|----------|------------|
| Framework | Bubbletea + net/http | Nocterm + dart:io HttpServer |
| TUI quality | Poor (modal/input issues) | Clean Focusable + KeyBound |
| Binary size | 12 MB | 9 MB |
| Lines of code | ~3600 (7 files) | ~1600 (7 files) |
| Storage format | Same (JSON per account) | Same (backward compatible) |
| Proxy path | `/v2` (fixed) | `/v2` |
| Clipboard | No | OSC 52 + xclip + wl-copy |
| Terminal cleanup | `exit(0)` → garbage chars | `shutdownApp()` → clean |

## Known Issues / Gotchas

- Login URL flow requires browser with active CodeBuddy session (GitHub auth)
- Session_code expires after a few minutes — must paste quickly
- Quota probe returns HTML 401 from APISIX for valid tokens (handled gracefully — leaves state alone)
- Clipboard fallback (`xclip` / `wl-copy`) depends on the user's Linux display server
- `nocterm` `TextField` consumes Enter key — import uses `onSubmitted` callback, not root `Focusable` handler
