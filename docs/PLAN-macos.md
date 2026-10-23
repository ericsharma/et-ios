# Plan: E.T. for macOS (client of every machine, and a machine itself)

Status: 2026-10-23. Decisions D1–D5 ACCEPTED by the owner (all as recommended); A3 not wanted for now. A1 + A2 DONE (etd 4f3eb42, tag v0.0.2): `etd status --json` (with `manager`), `etd install --no-service`, `ETD_LOG_FILE` (`~/` = home), one etd per key (lock `etd.lock` in the state directory), clear `etd join` error for a phone link (the invite is used up by the try). B1 DONE (Mac agent): target `ET-mac` in App/project.yml (sources App/Mac + App/Shared; SwiftTerm vendored without its build plugin); the app on the Mac mini attached to trigkey/bash over EtLink. B2 DONE (Mac agent): E.T.app bundles etd + etd-ssh (built from Vendor/etd v0.0.2 by an Xcode phase) and the SMAppService agent `xyz.ericsharma.et.etd`; onboarding §4.2 (look → login item → `etd install --no-service` → network → pair as "<machine> app"), the network choice §4.3, D4 detection (an etd older than v0.0.2 reports no `exe`: the app reads the pid's program path). scripts/mac-onboarding-test PASSES. On the Mac mini the app says "managed by Nix", registers nothing, installs nothing, real etd and node untouched. B4 DONE (Mac agent): scripts/mac-release signs etd, etd-ssh and E.T.app with Developer ID Application (Eric Sharm, 9MY2559FS4) + hardened runtime, notarizes (accepted on the first try), staples, zips; `spctl -a -vv`: accepted, source=Notarized Developer ID; `stapler validate`: worked. First release: ET-0.1-202610231411.zip (commit 72f652f, sha256 d506b585…). Ready for C2. Next: B3. Owner requests (2026-10-23): before the D4 test, the trigkey session walks the owner through removing etd, manymux and every related file from m1-air (§5.1), so the app is tested from zero; the app shows a screen with the choice **Start a new network** / **Join a network** (§4.3). C1 DONE 2026-10-23 (trigkey session with the owner): m1-air revoked (network key 49f7246ca3 → 8fddfe130e), etd, mm, data folders, logs and manymux's .zshenv lines removed; all §5.1 checks empty.

Follows [PLAN-network.md](PLAN-network.md). The m1-air test on 2026-10-23 (prebuilt etd v0.0.1, `etd install`, `etd join`) is the manual version of what this app does by itself.

## 1. Goal

One download of `E.T.app` on a Mac gives two things:

1. **A client.** Everything the iPad app does: the sessions of every machine in the network, terminals, network members and invites, notifications, uploads, templates, dictation, Copilot.
2. **A machine.** The Mac runs etd and a manymux node all the time, also when the app is closed. Its sessions show on the phone, on the iPad, and in `mm ls` on every other machine.

The first start does what we did by hand on m1-air, with no terminal:

| By hand on m1-air | In the app |
|---|---|
| `curl … \| tar xz`, then `etd install` | Install the app. First start: **Make this Mac a machine** (one approval in System Settings → Login Items). |
| `etd invite --machine` on trigkey, `etd join <link> --name m1-air` | **Join a network**: paste the link (or click an `et://` link). The app fills in the name. Or **Start a new network**. |
| Scan a QR code with the phone | Nothing. The app pairs itself with the etd on its own Mac. |

## 2. Facts that decide the design (checked 2026-10-23)

| Fact | Where | Effect |
|---|---|---|
| The Mac App Store and TestFlight for macOS need the App Sandbox. A sandboxed app cannot run a shell for other users' sessions, write `~/.zshenv`, or start an unrestricted daemon. | Apple rules | The Mac app is **not** on TestFlight. It ships Developer ID signed and notarized (D1). |
| `SMAppService.agent(plistName:)` (macOS 13+) registers a LaunchAgent whose plist and program are inside the app bundle. The user approves it once; it shows under the app's name in Login Items. | Apple ServiceManagement | etd runs as the app's agent, not as a plist in `~/Library/LaunchAgents` that points into the bundle. |
| EtLink already builds for `aarch64-apple-darwin`; ETCore and EtLink declare `.macOS(.v15)`. | `etd/scripts/build-ios.sh`, `Package.swift` files | The network, sessions and control code are shared as they are. |
| `etd invite`, `etd join` and `etd members` read and write etd's files directly; `etd join` works while etd runs (m1-air). Running status is `status.json` plus a pid check. | `etd/crates/etd/src/main.rs`, `config.rs` | The app drives etd with the bundled `etd` CLI as a subprocess. No new protocol. |
| `etd install` installs `mm` with manymux's installer into `~/.local/bin` and adds `PATH` + `MM_SSH` to `~/.zshenv`; it never restarts a running node. It worked first time on macOS (m1-air). | `etd/crates/etd/src/service.rs` | Reuse it for mm, the node and `MM_SSH`, without its etd service part. |
| A manymux node restart ends every session on that Mac. | PLAN-manymux | The node must **not** live inside the app bundle or under SMAppService: an app update must never restart it. |
| Two etd processes with one key (same `ETD_HOME`) fight over the same iroh identity. | iroh | The app never starts etd when one already runs (Nix on m1-mini, `etd install` on m1-air). |
| A device name may hold spaces; a machine name is letters, digits, `.`, `_`, `-` only. | etd baad243 | The app suggests the machine name from the host name (`m1-air`) and the device name `m1-air app`. |

## 3. Decisions for the owner

| # | Question | Recommended | Other choice |
|---|---|---|---|
| D1 | How do we ship it? | **Developer ID + notarized zip** (`scripts/mac-release`), copied to each Mac. Sparkle auto-update later. | Mac App Store / TestFlight: impossible without the sandboxed, client-only app. |
| D2 | Which identity does the app use? | **The app is a device member** that pairs itself with the etd on its own Mac (`etd invite --url` → `Link.pair`). No change to etd or et-link. A Mac shows twice in `etd members`: `m1-air` (machine) and `m1-air app` (device). | The app uses the machine's key through etd's local socket: one member per Mac, but et-link needs a second transport and etd needs a request set for local clients. About 2 days more. |
| D3 | Where is the code? | **A new native macOS target (`ET-mac`) in this repo**: SwiftUI + AppKit, sharing ETCore, EtLink and SwiftTerm (it has an AppKit `TerminalView`). Platform-free parts of `App/Sources` move into a shared folder. | Mac Catalyst: fast, but the iPad keyboard handling and UI are wrong for a desktop terminal. A separate repo: copies code that then drifts. |
| D4 | When an etd already runs on this Mac? | **Use it.** The app shows who manages it (Nix, `etd install`, or the app). For an `etd install` setup, offer **Let E.T. manage etd**: the same key and network, no new join. Never for Nix. | Always install the app's own etd: two etds with one key on m1-mini and m1-air. |
| D5 | Pushes to the Mac? | **Local notifications** from the network's events while the app runs. The app sends `Foreground` only while it is the active app, so the phone still gets pushes when you are not at the Mac. | APNs for macOS: a second push target in et-push, a macOS push entitlement and profile. Later, if needed. |

## 4. Design

### 4.1 What runs where

```
E.T.app/Contents/
  MacOS/ET                          the app (client)
  MacOS/etd, MacOS/etd-ssh          built from Vendor/etd (the same commit as EtLink)
  Library/LaunchAgents/xyz.ericsharma.et.etd.plist   SMAppService agent: BundleProgram MacOS/etd,
                                    KeepAlive, ETD_MANYMUX_HOSTS=1, ETD_LOG_FILE (A2)
~/.local/bin/mm                     manymux, from manymux's installer (pinned 0.2.2)
~/Library/LaunchAgents/xyz.ericsharma.etd.manymux.plist   the node, written by etd (never by the app)
~/.zshenv                           PATH + MM_SSH=<E.T.app>/Contents/MacOS/etd-ssh (etd's marked block)
~/Library/Application Support/etd   key, network, status.json (the same as a CLI install)
```

The app talks to every machine, its own Mac too, over iroh with EtLink, as the iPad does. Its own Mac's etd is its first server, so the Machines screen opens even when no other machine is on.

### 4.2 First start (onboarding)

1. **Look.** Read `etd status --json` (A1) with the bundled CLI. Result: not running; running and managed by Nix / `etd install` / the app.
2. **Make this Mac a machine** (when no etd runs): `SMAppService.agent(...).register()`. If the status is `requiresApproval`, show the button that opens Login Items and wait. Then run `etd install --no-service` (A1) for mm, the node and `MM_SSH`. Show each step with a check mark.
3. **Network.** If this etd's network has only itself, show the **network choice screen** (§4.3). If it already has other members (an etd that was set up before), skip to step 4.
4. **Pair the app.** `etd invite --url` → `Link.pair(url, "<machine> app")`. Save the server. No QR code.
5. **Done.** Machines screen with every machine. **Invite** shows a QR code for a phone, or a link for a machine.

Every step is idempotent: the app runs steps 1, 2 and 4 again at each start, and fixes what is missing (app moved: new `MM_SSH` path; agent removed in Login Items: ask again).

### 4.3 The network choice screen

Shown in onboarding step 3, and later from Settings → **Network** while this Mac's network has only itself. Two large choices, side by side:

```
┌──────────────────────────────┐  ┌──────────────────────────────┐
│  Start a new network         │  │  Join a network              │
│  This Mac is the first       │  │  Add this Mac to the network │
│  machine. Add your phone and │  │  of your other machines.     │
│  other machines after.       │  │                              │
└──────────────────────────────┘  └──────────────────────────────┘
```

**Start a new network**

1. A field **Network name**, filled with this Mac's machine name. etd names the network after its first machine today; if the owner wants a free network name, that is an etd change (A3, optional).
2. **Create** → the network exists (etd made it at its first start). The app pairs itself (step 4).
3. Next screen: **Add your phone** shows the QR code from `etd invite` (device), with a short line: "Scan with the iPhone camera, or in E.T. → + → Scan QR code." **Skip** goes to Machines.

**Join a network**

1. A text field: "Paste the link from `etd invite --machine` on one of your machines, or from E.T. on your phone: Network → Invite → Machine." The app also fills it in when the user clicks an `et://pair?…` link. When the clipboard holds an `et://pair` link, the app offers **Paste** at once.
2. A field **Name for this Mac**, filled with the host name in machine-name rules (letters, digits, `.`, `_`, `-`). Red text if a member already has the name.
3. **Join** → `etd join <link> --name <name>`. A spinner, then the member list from the join output, or the error in plain words: link expired (10 minutes), link already used, the inviting machine is off.
4. The app pairs itself (step 4) and opens Machines.

A link for a phone or tablet (not `--machine`) in the field: show "This link is for a phone. Make one with `etd invite --machine`." The ticket does not say its kind today (`TicketInfo` has no kind), so A1 makes `etd join` fail with that exact reason, and the app shows it.

### 4.4 Feature parity with the iPad app (SPEC §5)

| iPad | Mac |
|---|---|
| Machines, sessions, new session (§5.0) | Same views; a sidebar of machines, a window per session or tabs |
| Network members, invites (§5.0) | Same; QR code for phones, copyable link for machines |
| Two-finger swipe between windows (§5.1) | ⌘[ / ⌘], ⌘1–9, a tab bar |
| Key row, volume buttons (§5.3) | Not needed: the physical keyboard. Templates stay as a toolbar menu |
| Dictation (§5.3), Copilot | Same code (`SFSpeechRecognizer` works on macOS) |
| Select mode (§5.4) | Native mouse selection and ⌘C |
| Open in E.T. / uploads | Drag a file onto the terminal → `Upload` → type its path |
| QR scanner | Not needed: paste a link, or click an `et://` link |
| Push (§5.2) | Local notifications (D5); a click opens the session |

## 5. Work

Owners: **A** = the trigkey Claude session (etd), **B** = the Mac agent (app, builds, signing), **C** = the owner (tests on real Macs).

| Step | Owner | What | Done when |
|---|---|---|---|
| M0 | C | Accept or change D1–D5 | This file says so |
| A1 | A | `etd join` fails with "this link is for a phone or tablet" for a device invite. `etd status --json` (pid, version, id, host, network name, member count, `exe` path, manager: nix / cli / app / unknown). `etd install --no-service`: mm, the node plist and `MM_SSH` only, with `etd-ssh` from next to the running `etd`. Unit tests. | etd tagged `v0.0.2`; the Mac agent updates `Vendor/etd` |
| A2 | A | `ETD_LOG_FILE`: etd writes its log there (an SMAppService plist cannot name the user's home). | Same tag |
| A3 | A | Optional: a network name chosen at **Start a new network** (today etd names the network after its first machine) | Only if the owner wants it |
| B1 | B | `ET-mac` target (D3): shared code folder, macOS app shell, Machines + terminal over EtLink to an already paired machine | Attach to a trigkey session from the app on the Mac mini |
| B2 | B | Bundle `etd` + `etd-ssh` (cargo build from `Vendor/etd` in the build), SMAppService agent, onboarding §4.2 with D4 detection | §6 test passes on the Mac mini |
| B3 | B | Parity §4.4 | Owner's checklist in GUIDE.md |
| B4 | B | `scripts/mac-release`: sign `etd`, `etd-ssh` and the app with Developer ID + hardened runtime, notarize with the ASC key (`scripts/asc-token`), staple, zip | A zip that opens with no Gatekeeper warning on m1-air |
| C1 | C + A | When B2 is ready: remove etd, manymux and every related file from m1-air, step by step with the trigkey session (§5.1) | Every check in §5.1 passes |
| C2 | C | m1-air from zero: download the zip, open, approve in Login Items, **Join a network** with a link from trigkey or the phone, name `m1-air` | `m1-air` and `m1-air app` in `etd members` on trigkey; `mm ls` on trigkey shows an `m1-air/…` session; no terminal used on the laptop |
| C3 | C | The Mac mini (Nix etd): open the app | It says "etd is managed by Nix", installs nothing, and pairs itself |

Time: A1 + A2 about 2 hours. B1 about 1 day, B2 about 1 day, B3 2–3 days, B4 about half a day (the first notarization often fails on one missing signature).

The **Let E.T. manage etd** takeover (D4, for an `etd install` setup) has no real Mac left to test on after C1. The automatic test (§6) covers it with a temporary CLI-style setup.

### 5.1 Removing etd from m1-air (C1)

The trigkey session walks the owner through this live, one step at a time, and checks each result. The only session on m1-air is `test`; stopping the node ends it.

1. **On trigkey:** `etd revoke m1-air`. The other machines drop it, and the network moves to a new network key (N1b). Check: `etd members` has no `m1-air`; `~/.config/manymux/hosts.toml` has no `m1-air`.
2. **On m1-air:** `~/.local/bin/etd uninstall`. It stops etd and removes both LaunchAgent plists and the `MM_SSH` block in `~/.zshenv`. It leaves the node running.
3. **On m1-air:** stop the node: `launchctl bootout gui/$(id -u)/xyz.ericsharma.etd.manymux`. This ends the `test` session.
4. **On m1-air:** remove the files:
   ```sh
   rm -f ~/.local/bin/etd ~/.local/bin/etd-ssh ~/.local/bin/mm
   rm -rf ~/Library/Application\ Support/etd ~/Library/Application\ Support/manymux /tmp/manymux-$(id -u)
   rm -f ~/Library/Logs/etd.log ~/Library/Logs/manymux-daemon.log
   ```
   Then open `~/.zshenv` and delete the 2 lines manymux's installer added (`# manymux: also read by …` and the `export PATH="…/.local/bin:$PATH"` under it), unless something else needs `~/.local/bin`.
5. **Checks on m1-air**, in a new terminal: `command -v etd etd-ssh mm` prints nothing; `launchctl list | grep ericsharma` prints nothing; `ls ~/Library/LaunchAgents | grep ericsharma` prints nothing; `grep -n "etd\|manymux\|MM_SSH" ~/.zshenv` prints nothing.

## 6. Automatic test (B2)

`scripts/mac-onboarding-test` on the Mac mini runs §4.2 without the UI and without touching the real setup:

1. A temporary `ETD_HOME` for a "hub" etd and one for the "new Mac", a temporary `ETD_SOCKET`, and `mm --socket <temp>` for the node. The test runs the bundled `etd` directly, not through SMAppService.
2. Onboarding logic (a Swift module the app and the test share) against those directories: status → install `--no-service` → join with an invite from the hub → pair the app → `Link.network()` lists both machines and the device.
3. `ExecOn` from the hub to the new Mac returns `hostname`.
   A second case: a CLI-style setup (etd started by hand with its plist marker) → the takeover keeps the same id and network.
4. Remove the temporary directories and stop only the processes the test started.

Rules: never the real `~/Library/Application Support/etd`, never the real manymux node (no `mm restart`, `mm stop`, `mm update`), never `launchctl` on real labels. Strip `TMUX` from the environment. This one test, no simulator suite.

## 7. Risks

- **Two etds with one key** if detection fails. Mitigation: `etd` refuses to start when `status.json` names a live pid that is not itself (A1 adds this check), so a second one exits at once.
- **The app is moved or deleted**: `MM_SSH` and the agent point to the old path. The next start fixes `MM_SSH`; a deleted app leaves the node running and `MM_SSH` broken until `etd uninstall` (Settings → **Stop being a machine** runs it first).
- **Version skew**: the app's etd is newer or older than the other machines'. Allowed while there are no users (no compatibility work); the app shows the etd version in Settings.
- **Notarization** needs the Developer ID Application certificate on the Mac mini (not only the iOS distribution certificate).
