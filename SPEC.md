# E.T. — a tmux client for iPhone and iPad

"ET phone home": one tap opens your tmux session on a server you own. Each tmux window is a full-screen terminal; switch with a two-finger swipe. Push notifications tell you when a long command finishes or Claude Code needs you.

User guide: [docs/GUIDE.md](docs/GUIDE.md) · Bundle ID `xyz.ericsharma.et` · repo `github.com/ericsharma/et-ios` (private) · status: spec v3 (describes the app as built), 2026-10-15.

## 1. Scope

**Replaces:** `ssh server` → `tmux attach` → `prefix n` / `prefix p`, on a phone or iPad.

**Works for any tmux user.** Nothing assumes a host name, session name, window naming scheme, or install path. Eric's setup (§1.1) is the first real user, not the design.

**Not built (by choice, for now):** general SSH client (SFTP browser, port forwards), Mosh, split-pane layouts (each window shows its active pane), font-size control, Face ID lock, app-switcher blur, Android, macOS.

### 1.1 Eric's setup

- Server `trigkey` (NixOS, tmux 3.6a). E.T. connects over **Tailscale only** (`100.73.1.39`), at home or away. Tailscale SSH runs in *check* mode: the first login in a while asks to approve in a browser.
- One session, `0`. Windows: `trigkey`, `trigkey-claude`, `gmktec`, `gmktec-claude`, `mac-mini`, `mac-mini-claude`. Windows for other machines run `ssh <machine>` from trigkey (the Mac mini is `ericsharma@192.168.0.5`, which trusts trigkey's key via nix-darwin).
- tmux-resurrect / tmux-continuum keep windows across reboots; home-manager's `secureSocket` puts the tmux socket under `/run/user/1000`.
- The trigkey side of notifications lives in nixos-config: `home/trigkey/et-notify.nix`, `hosts/nixos/optional/et-push.nix`, `secrets/et.yaml`, and the long-command bell in `home/common/shell.nix`.

## 2. How it works: tmux control mode

E.T. does not draw tmux's own screen. It runs `tmux -C` (control mode), like iTerm2's tmux integration: each pane's output arrives as its own stream (`%output %<pane> …`), window changes arrive as notifications (`%window-add`, …), and commands get replies in `%begin` … `%end` / `%error` blocks. Each tmux window becomes its own terminal emulator (SwiftTerm), and the window list becomes native UI.

### 2.1 Connecting

1. **SSH** with the app's key (§8). A new host key is fetched in a separate short connection and shown for trust *before* the timed login (Citadel allows 10 s for login). Login banners are surfaced: Tailscale SSH's approval link becomes an **Approve in browser** screen, and the login timeout grows to 5 minutes once a banner arrives.
2. **Find tmux and its socket** in one `/bin/sh` exec: `command -v tmux` (plain and login shell), then common paths (`/opt/homebrew/bin`, `/usr/local/bin`, `/usr/bin`, `/run/current-system/sw/bin`, `/etc/profiles/per-user/$USER/bin`, `~/.nix-profile/bin`, `/snap/bin`). Then find the directory with a live server among `$TMUX_TMPDIR`, the login shell's `$TMUX_TMPDIR`, `$XDG_RUNTIME_DIR`, `/run/user/<uid>`, `/tmp`. Non-login commands (Tailscale SSH) lack the login environment, so this matters. Every tmux command then runs as `env TMUX_TMPDIR=<dir> <tmux>`.
3. **Pick a session** (`list-sessions`): the current one on reconnect, the only one, or the last used; otherwise a picker. **Never create a session silently.** An empty list usually means a wrong socket; the picker offers "New session".
4. **Attach** on an exec channel **without a PTY**: `exec env TERM=et-ios <tmux> -C attach-session -t =<session>` (verified on 3.5a and 3.6a). `TERM=et-ios` marks E.T.'s control clients (`#{client_termname}`).
5. Remote commands run wrapped as `/bin/sh -c '( cmd ) 2>&1; echo __ET_EXIT__$?'`, so output and exit code come back whatever the login shell.

### 2.2 Protocol notes

- In `%output`, bytes < 0x20 and `\` arrive as octal `\ooo`; everything else is raw, so a UTF-8 character can be split across lines. Output is bytes, never strings.
- Reply bodies are raw. A block ends only at the `%end`/`%error` matching its `%begin` (body lines may start with `%`).
- Reply flag `1` = sent by this client, `0` = tmux's own (the initial attach). Only flag-1 replies are matched, in order, against sent commands.
- `-F` output turns tabs into `_`: fields are space-separated with the window name last.
- `new-window -n` / `rename-window` expand `#{…}`: `#` is doubled in user-typed names.
- Control-mode commands don't update `#{client_activity}`, so tmux can't tell a live control client from a stale one (see §5.2).

### 2.3 Commands

| Purpose | Command |
|---|---|
| Window list | `list-windows -F '#{window_id} #{window_index} #{window_active} #{pane_id} #{window_panes} #{window_width} #{window_height} #{s/ /_/:pane_current_command} #{window_name}'` |
| Typing | `send-keys -t %<pane> -H <hex>`, posted without waiting, ≤ 256 bytes per command |
| History | `capture-pane -p -e -J -t %<pane> -S -2000` |
| Pane state | `display-message -p -t %<pane>` with cursor, `alternate_on`, size, and mode flags (`cursor_flag`, `keypad_cursor_flag`, `keypad_flag`, mouse flags) |
| Client size | `refresh-client -C <cols>x<rows>` (debounced 150 ms) |
| Claim / release a window's size | `resize-window -t @w -x C -y R` / `set-option -uw -t @w window-size` (§2.5) |
| New window | `new-window -d -n <name> -P -F '#{window_id} #{pane_id}'`, then template lines via `send-keys` |
| Rename / close | `rename-window`, `kill-window` (after confirm) |
| Heartbeat | `run-shell -b 'touch ~/.local/state/et-notify/foreground'` every 20 s; `rm -f` on disconnect (§5.2) |
| Stale clients | `list-clients -F '#{client_name} #{client_termname}'`, `detach-client -t` other `et-ios` clients on attach |

### 2.4 Restoring and repainting a window

Restore = reset the emulator, feed `capture-pane` (history + screen, colors; for the alternate screen: saved normal screen, then `?1049h`, then the visible capture), move the cursor, replay the program's modes (application cursor/keypad, mouse modes, hidden cursor, bracketed paste), then apply `%output` that arrived meanwhile. The visible window goes first.

tmux never sends a resized pane's screen to a control client, and programs redraw relative to what they think is on screen. So after a resize settles (0.4 s), the visible window is **repainted** the same way; other windows are repainted when shown.

### 2.5 Window size

`window-size latest` follows the client that last *typed* in a window, and control-mode input doesn't count, so windows last used on the laptop would stay laptop-wide. E.T. **claims** the window it shows (`resize-window`) and **releases** it on switch, disconnect, or, if it died, on the next attach (claimed IDs are remembered per server). A window open on two devices fits the one showing it. The global option is never changed.

## 3. Stack

| Part | Choice |
|---|---|
| Language / UI | Swift 6 (strict concurrency), SwiftUI, UIKit where needed |
| Minimum OS | iOS / iPadOS 18 (built with Xcode 26.6, iOS 26 SDK) |
| Terminal | SwiftTerm 1.20.0 |
| SSH | Citadel 0.12.1, **vendored** with two patches (`Vendor/Citadel/PATCHES.md`): configurable login timeout and auth-banner callback |
| Keys | Secure Enclave P-256 (CryptoKit); software key in the Simulator |
| Speech | `SFSpeechRecognizer`, on-device only |
| Push | APNs, sent by `et-notify` on the server (§5.2) |

Note: swift-nio-ssh requires a MAC match even for AES-GCM and only offers `hmac-sha2-256`, which NixOS's default OpenSSH (etm-only MACs) refuses. That's why trigkey is reached through Tailscale SSH rather than LAN OpenSSH. Fix if ever needed: vendor swift-nio-ssh and add the etm names to its placeholder MAC list.

## 4. Code layout

```
ETCore/                    Swift package, no UI
  ETCore/  ControlParser (pure), TmuxCommand (pure), TmuxClient (actor), ControlChannel
  ETSSH/   SSHConnection (connect, host-key TOFU + pinning, banners, run, upload, findTmux,
           sessions), SSHControlChannel, SSHIdentity / KeyStore, ServerConfig
  Tests/   parser fixtures + client integration against a throwaway local tmux
App/                       xcodegen project (project.yml)
  AppModel        servers, templates, key, network monitor, notification routing
  SessionController  one connection: attach, windows, restore/repaint, claims, heartbeat,
                     input, uploads, reconnect
  TerminalHost    one SwiftTerm view per window; two-finger gestures; dictation result hook
  Views, KeyRow, Overview, SelectMode, Templates, VoiceInput, VolumeButtons, Push
Vendor/Citadel             patched SSH library
scripts/                   asc-token, asc.env, setup-signing, unlock-signing, testflight, make-icon.swift
```

All tmux traffic goes through `TmuxClient`. Every window keeps a live `TerminalView`, even when hidden.

## 5. Features

### 5.1 Screen

- **Header:** status dot, server · session, build label (`b MM-DD HH:MM`, UTC), ⊞ overview, ⋯ menu (Overview, New window, Debug log, Reconnect, Servers, full build).
- **Window tabs** under the header; long-press a tab for Rename / New window / Close.
- **Terminal:** one finger selects (SwiftTerm), **two-finger up/down scrolls** (wheel events in full-screen apps) and closes the keyboard, **two-finger left/right switches windows**.
- **Bottom bar:** ✎ editor · ⌶ select mode · ⋯ key wheel | **mic** (center) | paste (when the clipboard has text) · 🖼 image · ⏎ Enter. Both sides are the same width.
- **Key wheel** (⋯): a vertical, snapping wheel of keys over the terminal. Shell set: esc, tab, ctrl (tap = once, long-press = lock), arrows, `| ~ / -`, ^C, ^D. Claude set: esc, ⇧tab, 1 2 3, ↑ ↓, enter, ^C. Claude set is chosen automatically for windows running `claude` or named `*claude*`; long-press ⋯ to change, remembered per window name. Hidden with a hardware keyboard.
- **Overview:** live thumbnails of every window; tap to open, long-press to rename / close / new; + tile.
- **iPad (regular width):** sidebar of windows with a visible, remembered collapse toggle; header with tabs when collapsed. Shortcuts: ⌘[ ⌘] ⌘1–9 ⌘T ⌘K ⌘O ⌘\\.
- **Connection states:** connecting / restoring / reconnecting banners over the dimmed last screen; errors carry the real cause (unreachable with detail and a Local Network hint for LAN addresses, key rejected, host key changed, timed out, tmux not found with discovery output).

### 5.2 Notifications

- **Triggers:** anything that rings the terminal bell. Bash on trigkey/gmktec rings after commands ≥ 15 s (not editors, pagers, ssh, claude…). Claude Code rings with Notifications → Terminal Bell. Bells from ssh windows travel back through tmux.
- **Server:** tmux `alert-bell` hook → `et-notify #{hook_window}` → APNs to every device in `~/.config/et/devices/*.json` (written by E.T. after each attach: token, environment, server ID). Body: the pane's last line, or for Claude windows the start of Claude's last `⏺` message. One push per window per 10 s; `apns-collapse-id` per window. Log: `~/.local/state/et-notify/log`.
- **Skipped while E.T. is open:** E.T. touches `~/.local/state/et-notify/foreground` every 20 s while connected and removes it on disconnect; `et-notify` skips if it's under 60 s old. (A control client attached isn't proof: a killed app's SSH session can linger for hours.) The heartbeat is shared: an open E.T. on either device silences pushes to both.
- **Tapping a notification** connects if needed and opens that server, session, and window, also from a cold launch (the delegate is set in `willFinishLaunching`).
- **In the app:** a bell vibrates and shows a banner ("<window> needs you — tap to open"); background windows get red / blue dots.

### 5.3 Input

- **Typing:** keyboard → SwiftTerm → `send-keys -H`.
- **Keyboard dictation:** goes straight in. When it ends, an **Edit** button offers to move the text into the editor (erasing it from the terminal); typing, tapping, or switching windows dismisses it.
- **E.T. mic:** on-device recognition with a live bubble; keeps everything across pauses and long speech (finished stretches are kept and recognition restarts on the same audio). Stops on tap (10-minute cap). Text is typed in (no Enter), then the Edit offer.
- **Editor** (✎, ⌘K): a sheet for writing or editing a whole message; Send (Enter) or Send without Enter. Multi-line text to Claude windows goes as a bracketed paste.
- **Paste:** the system PasteButton (no permission prompt); bracketed paste when the program enabled it.
- **Images:** pick a screenshot/photo → uploaded over SSH (SFTP, base64 fallback) to `~/.cache/et-uploads/` → forwarded over the window's own ssh destination when the window is an ssh session → the path is typed into the window.
- **New window:** name + optional command lines (typed into the new shell), saveable as per-server templates.

### 5.4 Select mode (⌶)

The window's history and screen frozen as plain text in a native text view (iOS handles and magnifier), over the terminal; live output continues underneath.
- Tap = shell word, double-tap = line, triple-tap = block of non-empty lines, long-press + drag = free selection.
- **Copy-on-select:** the selection goes to the clipboard 250 ms after it stops changing ("✓ Copied N characters").
- **Volume buttons:** move the chosen end (Start | End switch) one character; holding repeats; up + down together swaps ends. Implemented with the volume-observation workaround (volume parked mid-way while open, restored after, hidden MPVolumeView); not App Store–safe. The ring/silent switch has no API.
- Toolbar: Copy, One line, Editor, Screen, Done. Switching windows (tab or two-finger swipe) leaves select mode.

### 5.5 Lifecycle

| Event | Action |
|---|---|
| Launch | Connect to the last server (unless a tapped notification chose one). |
| Background | Close the control client (release windows, clear heartbeat) — except while a login waits for browser approval. |
| Foreground / network change | Reconnect, keeping pages; full restore. |
| Lost connection | Retry after 0.5, 1, 2, 4 s, then every 8 s for 2 minutes. |

## 6. Settings and storage

Per server (JSON in Application Support): name, host, port, user, tmux path (auto), last session, pinned host key; templates per server; key-row choices per window name and claimed windows in UserDefaults. App: the client key (Keychain, this device only). Theme: Catppuccin Mocha.

## 7. Security

- Client key in the Secure Enclave, one per device, never exported; shown in OpenSSH format for `authorized_keys`. Through Tailscale SSH it isn't used (Tailscale identity + check approval decides).
- Host keys: trust on first use, pinned; a changed key stops the connection.
- No passwords, no keyboard-interactive.

## 8. Build and release

- **Machine:** Mac mini (m1-mini), headless. Xcode 26.6 via `xcodes`; project from `App/project.yml` (`xcodegen`).
- **Signing:** App Store Connect API key (`scripts/asc.env`, `.p8` in `~/.appstoreconnect/private_keys/`), a dedicated keychain with an API-created development certificate (`scripts/setup-signing`, `scripts/unlock-signing`).
- **Release:** `scripts/testflight` archives (build number = UTC time), exports the `.ipa`, and uploads with `altool`. App Store Connect app 6823235487 ("E.T"), internal group "Eric".
- **Device builds** (when the phone is awake on the same Wi-Fi): `xcodebuild … build` then `xcrun devicectl device install app`.
- **Tests:** `cd ETCore && swift test` (parser fixtures, command builders, client against a throwaway tmux on a private socket). Never run destructive commands against a real session.

## 9. Later (ideas, not planned)

Per-device notification heartbeat, font size, Face ID / app-switcher blur, separate "Claude needs input" vs "finished" notifications, snippets, Shortcuts/Siri, several servers at once, split panes, `SpeechAnalyzer` dictation.
