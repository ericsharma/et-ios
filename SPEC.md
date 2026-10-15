# E.T. — iOS tmux client for trigkey

Name: **E.T.** (display name; "ET phone home"). Bundle ID `xyz.ericsharma.et`. Owner: Eric. Builder: an agent on m1-mini (Xcode).
Status: draft spec, 2026-10-14.

## 1. Goal

One tap on the iPhone or iPad opens the live tmux session on trigkey. Each tmux window is one full-screen terminal page. Swipe left or right to move between windows. A compose bar with on-device dictation sends text to the terminal.

The app replaces this flow: `ssh trigkey` → `tmux attach` → `prefix n` / `prefix p`.

### 1.1 Facts about the current setup (verified on trigkey, 2026-10-14)

| Fact | Value |
|---|---|
| tmux version | 3.6a |
| Session name | `0` (the only session) |
| tmux binary | `/etc/profiles/per-user/eric/bin/tmux` |
| `window-size` | `latest` (default) |
| SSH auth | public key only (`PasswordAuthentication = false`) |
| Authorized keys for trigkey | `~/nixos-config/hosts/nixos/trigkey/default.nix:61` |
| Persistence | tmux-resurrect + tmux-continuum, `@resurrect-processes 'ssh'` |
| Network | iPhone reaches trigkey over Tailscale (MagicDNS name `trigkey`) |

Current windows in session `0`. The names follow a pattern: one shell window and one Claude Code window per machine.

```
1 trigkey          (bash)
2 trigkey-claude   (claude)
3 gmktec           (ssh)
4 gmktec-claude    (ssh → claude on gmktec)
5 mac-mini         (ssh)
6 mac-mini-claude  (claude)
```

The app must use this pattern. See §5.3 (host grouping) and §6.4 (Claude windows).

### 1.2 Decisions made

| Topic | Decision |
|---|---|
| Distribution | Paid Apple Developer account. TestFlight. |
| Voice | On-device dictation into a compose box. The user edits, then sends. No AI. |
| Panes | One shell per window. The app shows the active pane of each window. No split-pane UI. |
| Devices | iPhone and iPad. |
| Network | Tailscale is already on. The app does not manage Tailscale. |

### 1.3 Non-goals (v1)

- General SSH client (host list for direct connections, SFTP, port forwards).
- Mosh.
- Split-pane layout view.
- Push notifications (see §11, later).
- Any AI feature.
- Android, macOS.

## 2. Core technical approach: tmux control mode

Do **not** render tmux's own screen (status bar, borders) in a single terminal. Use **tmux control mode** (`tmux -C`), like iTerm2's tmux integration.

In control mode, tmux sends a text protocol instead of a drawn screen:

- Each pane's raw output comes as a separate stream (`%output %<pane-id> ...`).
- Window events come as notifications (`%window-add`, `%window-close`, `%window-renamed`, ...).
- The app sends normal tmux commands (`send-keys`, `new-window`, `capture-pane`, ...) and gets replies in `%begin` / `%end` blocks.

Result: each tmux window becomes a native page with its own terminal emulator. The window list becomes native UI. Scrollback per window works natively.

### 2.1 Connection command

Open an SSH **exec channel without a PTY** and run:

```sh
exec /etc/profiles/per-user/eric/bin/tmux -C attach-session -t 0
```

- Use `-C` (one C), not `-CC`. `-CC` is for a TTY and wraps output in a DCS sequence.
- The tmux path and session name are settings (§8). Default as above.
- If the session does not exist (`%exit` or error at start), show the session list (`list-sessions`) and let the user pick or create one.
- **Spike item:** confirm that `tmux -C attach` works on a channel with no PTY on 3.6a. If not, request a PTY, use `-CC`, and strip the DCS wrapper (`ESC P 1000 p` at start, `ESC \` at end).

### 2.2 Protocol details the parser must handle

Lines end with `\n`. Each line is one of:

| Line | Meaning |
|---|---|
| `%begin <time> <cmd-num> <flags>` | Start of reply to a command. Lines up to `%end`/`%error` are the reply body. |
| `%end <time> <cmd-num> <flags>` | Reply OK. |
| `%error <time> <cmd-num> <flags>` | Reply failed. Body is the error text. |
| `%output %<pane> <data>` | Pane output. In `<data>`, bytes < 0x20 and `\` are octal-escaped as `\ooo`. Decode to raw bytes. |
| `%extended-output %<pane> <age> : <data>` | Same, when `pause-after` flow control is on. |
| `%pause %<pane>` / `%continue %<pane>` | Flow control. |
| `%window-add @<win>` | New window. |
| `%window-close @<win>` / `%unlinked-window-close @<win>` | Window gone. |
| `%window-renamed @<win> <name>` | Rename. |
| `%window-pane-changed @<win> %<pane>` | Active pane in window changed. |
| `%session-window-changed $<sess> @<win>` | Current window changed (for example, from the laptop). |
| `%layout-change @<win> <layout> ...` | Pane layout or size changed. |
| `%session-changed $<sess> <name>` / `%sessions-changed` | Session events. |
| `%subscription-changed ...` | Reply to `refresh-client -B` subscriptions. |
| `%exit [reason]` | Control client ends. Treat as disconnect. |

Rules:

- Commands are answered in order. Keep a FIFO of pending commands. Match replies to commands by order, and check `<cmd-num>`.
- Unknown `%` lines: log and ignore. Do not crash.
- The parser is a pure Swift type with no I/O. Unit-test it with recorded fixtures (§10).

### 2.3 Commands the app uses

| Purpose | Command |
|---|---|
| Window list | `list-windows -F '#{window_id}\t#{window_index}\t#{window_name}\t#{window_active}\t#{pane_id}\t#{pane_current_command}\t#{window_panes}'` |
| Send input (any bytes) | `send-keys -t %<pane> -H <hex bytes...>` |
| Restore history | `capture-pane -p -e -J -t %<pane> -S -<N>` (N = scrollback setting, default 2000) |
| Cursor and screen mode | `display-message -p -t %<pane> '#{cursor_x} #{cursor_y} #{alternate_on} #{pane_width} #{pane_height}'` |
| Alternate screen (vim, htop, claude) | `capture-pane -p -e -a -t %<pane>` when `alternate_on` is 1 |
| Set client size | `refresh-client -C <cols>x<rows>` |
| New window | `new-window -n <name>` then `send-keys -t <new pane> 'ssh <target>' Enter` (see §6.3) |
| Rename / close / select | `rename-window`, `kill-window` (with confirm), `select-window` |
| Activity tracking | `refresh-client -B act:@*:#{window_activity}` (subscription) or track `%output` per pane |

### 2.4 History restore on attach

For each window, before live output for its pane is shown:

1. Create the terminal emulator at the pane's size.
2. Run `capture-pane` (history + visible screen, with `-e` for colors). Feed the result into the emulator.
3. Run `display-message` for cursor position. Send a CUP sequence (`ESC [ row ; col H`) to the emulator.
4. Buffer any `%output` for this pane that arrives during steps 2–3. Apply it after step 3.

Do this for the visible window first, then the neighbors, then the rest in the background.

### 2.5 Window size

`window-size latest` means each window takes the size of the last active client. When the phone attaches and the user types, windows resize to the phone. When the user types on the laptop again, windows go back.

- On attach, on rotation, on font-size change, and on iPad window resize: compute cols × rows from the visible terminal view and font. Send `refresh-client -C <cols>x<rows>`.
- Debounce resize by 150 ms.
- Do not change the server's `window-size` option.

## 3. Stack

| Part | Choice | Notes |
|---|---|---|
| Language | Swift 6, strict concurrency | |
| UI | SwiftUI; UIKit where SwiftTerm needs it | |
| Minimum OS | iOS / iPadOS 18 | Builds with Xcode 16.3 on m1-mini (macOS 15.5 cannot run Xcode 26). |
| Terminal emulator | [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) (`TerminalView` for iOS) | Wrap in `UIViewRepresentable`. |
| SSH | [Citadel](https://github.com/orlandos-nl/Citadel) on SwiftNIO SSH | **Spike item:** confirm a long-running exec channel with stdin writes and stdout stream. If Citadel cannot do it, use `swift-nio-ssh` directly. |
| Keys | CryptoKit `SecureEnclave.P256.Signing.PrivateKey` | **Spike item:** confirm SwiftNIO SSH accepts a Secure Enclave key (`NIOSSHPrivateKey(secureEnclaveP256Key:)`). Fallback: Ed25519 key in Keychain, `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`. |
| Speech | `SFSpeechRecognizer` with `requiresOnDeviceRecognition = true`, plus `contextualStrings` | Decided 2026-10-14. Later: move to `SpeechAnalyzer` + `SpeechTranscriber` (iOS 26, Xcode 26) if dictation quality is not good enough. Only `VoiceInput` changes. |
| Persistence | SwiftData or a JSON file for settings and host list | No server. |
| Network monitor | `NWPathMonitor` | Reconnect on path change. |

No other third-party packages unless the spike proves a need.

## 4. Architecture

```
SSHTransport        — connects, authenticates, opens exec channel, byte streams in/out
ControlParser       — pure: bytes → [ControlEvent]  (no I/O, fully unit-tested)
TmuxClient (actor)  — command queue, reply matching, sends commands, emits events
SessionStore (@Observable, MainActor)
                    — windows [id, index, name, host, activePane, hasActivity, bell]
                    — connection state
PaneTerminal        — one SwiftTerm TerminalView per pane; fed by %output;
                      keyboard input → send-keys -H
UI                  — WindowPager, WindowStrip, Overview, ComposeBar, KeyRow, Settings
VoiceInput          — SFSpeechRecognizer wrapper (on-device); publishes partial + final text
KeyStore            — key generation, public key export, host-key pinning
```

Rules:

- Keep a `TerminalView` alive for every window, also when off screen, so output is not lost and swipes are instant. Expect fewer than 20 windows.
- All tmux traffic goes through `TmuxClient`. UI code never writes raw bytes to SSH.

## 5. UI / UX

Borrow from the Claude mobile app's Remote Control screen: dark, calm, one main surface, a compose bar at the bottom, clear connection status at the top.

### 5.1 iPhone layout (portrait)

```
┌─────────────────────────────────┐
│ ● trigkey · 0          ⊞   ⚙   │  status row: connection dot, session, overview, settings
│ [trigkey][gmktec][mac-mini]     │  host strip (§5.3)
│   shell · claude                │  sub-tabs for the current host
├─────────────────────────────────┤
│                                 │
│     terminal (active pane)      │  ← swipe left/right = next/previous window
│                                 │
│                                 │
├─────────────────────────────────┤
│ esc tab ctrl ↑ ↓ ← → | ~ / -    │  key row (§5.5)
│ [ type or dictate…     ] 🎤  ➤ │  compose bar (§6)
└─────────────────────────────────┘
```

### 5.2 Window pager

- A horizontal pager. One page = one tmux window, in `window_index` order.
- Swipe left/right changes page. Light haptic on page change.
- The pager must not take vertical pans (the terminal uses those for scrollback). Start a page change only when the horizontal pan is clearly larger than the vertical pan.
- When text selection is active, the pager does not page.
- Changing page in the app does **not** run `select-window` on the server by default. The laptop keeps its own current window. Setting: "Follow phone window on server" (off).
- When a window is added on the server, insert a page. When a window closes, remove the page and go to the neighbor.

### 5.3 Host grouping

Parse window names as `<host>` or `<host>-<role>`. Known role suffix in v1: `claude`.

- The **host strip** shows one chip per host, in the order of the host's first window. Tap a chip to jump to that host's first window.
- Under it, **sub-tabs** show the windows of the current host (`shell`, `claude`, any other suffix).
- Each host has a color (settings). The chip, the sub-tab underline, and a 2 pt line at the top of the terminal use that color. This shows at a glance which machine is live.
- Window names that do not match a known host get a neutral color and their own chip.
- Swipe still goes window by window across hosts. Strip and sub-tabs update to follow.

### 5.4 Overview

- Tap ⊞ (or two-finger pinch-in on the pager) to open a grid of all windows, grouped by host.
- Each tile shows a live snapshot of the terminal (last N lines, scaled), name, and badges (activity, bell).
- Tap a tile to open it. Long-press a tile: Rename, Close (confirm), New window for this host.
- A **+** tile opens "New window" (§6.3).

### 5.5 Key row

One row above the compose bar. Scrolls horizontally if it does not fit.

v1 keys: `esc`, `tab`, `ctrl` (sticky: next key is sent with Ctrl), `↑ ↓ ← →`, `|`, `~`, `/`, `-`, `^C`, `^D`.

- Long-press `ctrl` = locked Ctrl until tapped again.
- In Claude windows the row changes (§6.4).
- iPad with a hardware keyboard: hide the key row.

### 5.6 Activity and bells

- A window that gets output while it is not visible gets a dot on its chip and sub-tab.
- A BEL byte (`0x07`) in a non-visible window: red badge and a light haptic.
- Opening the window clears both.

### 5.7 Connection state

Status dot at the top left:

| State | Look |
|---|---|
| Connected | green dot, no text |
| Connecting / restoring | pulsing amber, "Restoring 3/6" |
| Reconnecting | amber banner: "Reconnecting…" The last screen stays visible, dimmed 30%. Input is disabled. |
| Cannot reach trigkey | red banner: "Cannot reach trigkey. Is Tailscale on?" with a Retry button |
| Auth failed | red banner with a link to Settings → Key |

### 5.8 Font size

- Pinch inside the terminal changes font size (all windows). Then send a resize (§2.5).
- Default font: SF Mono 13 pt on iPhone, 14 pt on iPad.

### 5.9 iPad

- `NavigationSplitView`. Sidebar: hosts, with their windows under each. Detail: the terminal.
- In compact width (Slide Over, narrow Stage Manager), use the iPhone layout.
- Hardware keyboard shortcuts:
  - `⌘[` / `⌘]` previous / next window
  - `⌘1`…`⌘9` window by index
  - `⌘T` new window
  - `⌘K` focus compose bar
  - `⌘\` toggle sidebar
- All other key presses go to the terminal, including Ctrl and Esc.

## 6. Input

### 6.1 Direct typing

Tap the terminal to show the iOS keyboard. Keys go straight to the pane through SwiftTerm's input delegate → `send-keys -H`. Same as a normal terminal.

### 6.2 Compose bar and dictation

The compose bar is a multi-line text field (grows to 5 lines) with two buttons: mic and send.

- **Mic:** tap to start, tap to stop. While listening, the mic button is red and partial text shows live in the field. Transcription is on-device only.
- **Send:** sends the field text to the active pane, then Enter. Long-press Send: menu with "Send without Enter" and "Paste only".
- The user can edit the text before sending, with the keyboard or by dictating more.
- Clear the field after send. Keep a per-host history of sent text. Swipe up on the field (or ↑ in the field) shows recent items.
- Speech context: give the transcriber contextual strings — host names, window names, and a fixed list (`systemctl`, `journalctl`, `nixos-rebuild`, `tmux`, `ssh`, `sudo`, `docker`, `git`, `grep`, `claude`).

**Spoken-symbol mode** (toggle on the compose bar, default **off** in Claude windows and **on** in shell windows). After transcription, replace spoken words with symbols, without AI:

| Say | Gets |
|---|---|
| "dash dash" / "dash" | `--` / `-` |
| "pipe" | `\|` |
| "slash" | `/` |
| "tilde" | `~` |
| "dot" | `.` |
| "star" | `*` |
| "and and" | `&&` |
| "greater than" | `>` |
| "space" | ` ` |
| "all caps X" | `X` uppercase |

Also: lowercase the first word; remove a trailing period.

Permissions: microphone and speech recognition, with clear purpose strings.

### 6.3 New window

From the overview **+**, a long-press on a host chip, or `⌘T`:

1. Pick a host from the host list (settings) or type a name.
2. Pick a role: `shell` or `claude`.
3. The app runs `new-window -n <host>[-claude]`, then `send-keys 'ssh <ssh-target>' Enter` (skip for trigkey). For `claude`, it also sends `claude` Enter after ssh.

Why send-keys and not `new-window 'ssh gmktec'`: the pane must stay a shell that **runs** ssh, so it does not close when ssh exits, and tmux-resurrect restores it the same way as the user's own windows.

### 6.4 Claude windows

A window whose name ends in `-claude` is a Claude window:

- Key row changes to: `esc`, `⇧tab` (mode switch), `1`, `2`, `3`, `↑`, `↓`, `enter`, `^C`.
- Compose bar sends in prose mode (spoken-symbol mode off).
- Compose bar placeholder: "Message Claude on <host>…"

This copies the Remote Control feel: the phone is a good place to answer Claude's questions and approve actions.

## 7. Lifecycle

| Event | Action |
|---|---|
| App launch / foreground | Connect. Target: first terminal visible < 2 s on Tailscale. Restore visible window first (§2.4). |
| Background | Request background time (`beginBackgroundTask`). Close the control client cleanly. Closing the SSH channel is enough; the tmux session stays on trigkey. |
| Network path change | Reconnect. |
| Disconnect | Reconnect with backoff: 0.5 s, 1 s, 2 s, 4 s, then every 8 s. Stop after 2 min; show Retry. |
| Reconnect | Run the full restore (§2.4) again. Keep existing `TerminalView`s and replace their content, so pages do not flash. |

Restore last viewed window on launch (store window name, not ID; IDs change after a trigkey reboot).

## 8. Settings

| Setting | Default |
|---|---|
| Host | `trigkey` |
| Port | 22 |
| User | `eric` |
| tmux path | `/etc/profiles/per-user/eric/bin/tmux` |
| Session | `0` |
| Scrollback lines to restore | 2000 |
| Follow phone window on server | off |
| Require Face ID to open | off |
| Font size | 13 / 14 pt |
| Host list | `trigkey` (local, no ssh), `gmktec`, `mac-mini` — each with display name, ssh target, color |
| Theme | Dark, colors from `~/nixos-config/home/common/tmux.nix` (Catppuccin Mocha: bg `#181825`, accent `#89b4fa`, active `#f38ba8`) |

## 9. Security

- **Client key:** generated on first launch, in the Secure Enclave (P-256). It cannot leave the device. Settings → Key shows the public key in OpenSSH format with Copy and Share buttons.
- The user adds that key to `~/nixos-config/hosts/nixos/trigkey/default.nix:61` (`users.users.eric.openssh.authorizedKeys.keys`) and deploys trigkey.
- **Host key:** trust on first use. Show the fingerprint and ask once. Store it. If it changes later, stop and show a clear error. Do not connect.
- No passwords. No keyboard-interactive.
- Optional Face ID before the app shows terminal content.
- Hide terminal content in the app switcher snapshot (blur overlay on `scenePhase` inactive).

## 10. Build and test plan for the agent

Build on m1-mini with Xcode. Times are agent working time.

| Phase | Work | Done when | Time |
|---|---|---|---|
| 0. Spike | Xcode project. SSH from Simulator to trigkey (LAN or Tailscale) with a test key. Run `tmux -C attach -t 0`. Print events to the console. Answer the three spike items (§2.1, §3 SSH, §3 keys). | Console shows `%output` from a real pane | 2–4 h |
| 1. Core | `ControlParser` + tests, `TmuxClient`, one `PaneTerminal` page, typing via `send-keys -H`, history restore, resize | Can use the trigkey window like a normal terminal | 1–2 days |
| 2. Navigation | Pager, host strip, sub-tabs, overview, new/rename/close window, activity dots, bells | Swipe through all 6 windows; create `gmktec` shell window from the app | 1 day |
| 3. Input | Key row, compose bar, dictation, spoken-symbol mode, Claude windows | Dictate `systemctl status tmux-server` in shell mode and it runs | 1 day |
| 4. Lifecycle | Reconnect, background, network change, restore last window, connection banners | Turn on Airplane Mode 10 s, turn off: session comes back without user action | 1 day |
| 5. iPad | Split view, keyboard shortcuts, compact fallback | `⌘]` moves through windows with a hardware keyboard | 1 day |
| 6. Ship | Settings screen, Secure Enclave key, host-key pinning, app icon, TestFlight upload | Installed from TestFlight on Eric's iPhone | 4 h |

Total: about 6–8 agent days.

### 10.1 Tests

- **Parser unit tests:** record real control-mode output (run `tmux -C attach` on the Mac with `script` or a pipe) and save it as fixtures. Cover: octal escapes, UTF-8 split across `%output` lines, `%begin` blocks with lines that start with `%`, unknown notifications, `%exit`.
- **Integration test on the Mac:** start a tmux server on m1-mini with a test socket (`tmux -L attachtest`), drive `TmuxClient` against it over a local pipe (no SSH). Check window add/close/rename events and `send-keys` round trip.
- **Manual test on device:** the "Done when" column above.

Do not test against session `0` on trigkey with destructive commands (`kill-window`, `kill-session`). Use a separate session (`tmux new -d -s attachtest`) for those.

## 11. Later (not v1)

1. **Push notifications** when a window rings a bell or a Claude window waits for input. Needs a small service on trigkey (tmux `alert-bell` hook → APNs). Paid account makes this possible.
2. **Live Activity / Dynamic Island** for a long command ("nixos-rebuild on gmktec — running").
3. **Snippets:** saved commands per host, one tap to send.
4. **Shortcuts / Siri:** "Open gmktec in E.T.".
5. **Split-pane support** if the user starts to split windows.

## 12. Open questions

1. ~~App name~~ Decided: **E.T.** (2026-10-14).
2. Bundle ID prefix (for example `xyz.ericsharma.attach`)?
3. Where does the source live: a new private GitHub repo `ericsharma/attach-ios`?
4. `mac-mini-claude` runs `claude` on trigkey, not over ssh to the Mac mini. Intentional, or should the new-window flow always ssh first for non-trigkey hosts? (The spec assumes: always ssh first.)
