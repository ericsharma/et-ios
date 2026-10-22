# Plan: connect E.T. to any machine over iroh (`etd`)

Status: 2026-10-22. Phases 0–5 done (see §11.1–§11.6): E.T. works with trigkey over iroh, with Tailscale off on the phone. Phase 6 (cleanup) is optional. Code: `~/etd`, public at github.com/ericsharma/etd.

## 1. Goal

E.T. connects to any machine that runs tmux, without Tailscale or other VPN. A small daemon (`etd`) runs on each machine that you want to reach. The phone finds a machine by its iroh key (`EndpointId`), not by an IP address.

To add a machine:

1. Install `etd` on the machine and start it as a user service.
2. Run `etd pair` on the machine. It shows a QR code.
3. Scan the QR code with the iPhone camera. E.T. opens, adds the machine, and connects.

`etd` must work on Linux and macOS, with or without Nix. Nothing in `etd` or in the app assumes a host name, user, session name, or install path. SPEC.md §1 already has this rule for the app.

All E.T. features continue to work on every machine: windows, restore, uploads, push registration, dictation names, Copilot, summaries, and read aloud.

**Public later.** Other people must be able to download `etd`, run it with no configuration, and connect from E.T. The first releases are for your machines only. But the design decisions that are hard to change later are made for the public release now: a public repository, a license, protocol versioning, no shared secrets in the daemon, and push without your APNs key on other people's machines. Section 10 has the public release requirements.

## 2. What the study found

### 2.1 The app touches the network through one small surface

`SessionController` uses only these `SSHConnection` calls:

| Call | Used for |
|---|---|
| `connect` | login, host-key trust, Tailscale approval banner |
| `findTmux` | tmux path, version, socket directory |
| `listSessions` | session picker |
| `openControlChannel` | `tmux -C attach` byte stream → `ControlChannel` |
| `run` | about 10 shell scripts: push device file, image forward, vocabulary discovery, Copilot and summary `curl`, Kokoro TTS, ssh child lookup |
| `upload` | images to `~/.cache/et-uploads/` |
| `close` | disconnect |

`TmuxClient` already takes `any ControlChannel` (`ETCore/Sources/ETCore/TmuxClient.swift:3`). The tmux layer does not know about SSH. This is the place where iroh connects.

### 2.2 What a VPN gives E.T. today, and what replaces it

| Today (Tailscale) | With `etd` |
|---|---|
| A stable address for the machine (`100.x.y.z`) | The machine's `EndpointId` |
| Reach a machine behind NAT, at home or away | iroh hole punching, with relay fallback |
| Encryption | iroh QUIC + TLS 1.3 |
| Who may connect (Tailscale ACL, check mode) | `etd` allowlist of phone `EndpointId`s, added by QR pairing |
| Login on the machine (Tailscale SSH or OpenSSH) | `etd` runs as the user. It needs no login. |

E.T. only needs a connection from the phone to each machine. It does not need the machines to reach each other, an IP for each device, or a TUN device. So a point-to-point link from E.T. to each `etd` is enough (the zedra model). A full mesh VPN (the rayfish model) is not necessary.

Machines can still use tmux windows that run `ssh <other>` (a "hub" machine, like trigkey today). That is your choice. `etd` does not need it.

### 2.3 Things that become simpler

- No Tailscale SSH check mode, no "Approve in browser" screen, no 5-minute banner timeout.
- No swift-nio-ssh MAC problem with OpenSSH defaults (SPEC.md §3 note). E.T. does not use SSH on the iroh path.
- No tmux discovery over a non-login shell. `etd` runs as the user and gets the login environment one time at start (§7.2).
- No `__ET_EXIT__` wrapper. `etd` returns the exit code directly.

## 3. Decisions

### 3.1 Native daemon, not SSH through an iroh pipe

| | A. SSH through an iroh pipe | B. Native daemon (recommended) |
|---|---|---|
| How | `etd` forwards an iroh stream to `localhost:22`. The app runs Citadel over a local TCP port. | `etd` speaks a small E.T. protocol. It runs `tmux -C`, shell commands, and uploads itself. |
| Needs on the machine | A running sshd that accepts the app's MAC and key | Only `etd` and tmux |
| Auth | iroh allowlist + SSH key | iroh allowlist (TLS 1.3, both keys checked) |
| Problems kept | MAC mismatch, Citadel login timeout patches, tmux discovery over SSH | None of these |

Use **B**. Machines without sshd (many Macs) also work.

### 3.2 Keep SSH as a second transport

Each server in E.T. has a transport: `iroh` or `ssh`. SSH stays for machines where you cannot install `etd`. Phase 6 removes only the Tailscale-specific code, not SSH.

## 4. Architecture

```
iPhone (E.T.)                                   each machine (Linux or macOS)
┌───────────────────────────┐                   ┌─────────────────────────────┐
│ AppModel: list of servers  │                   │ etd (user service)           │
│ SessionController          │                   │   iroh Endpoint, ALPN et/1   │
│   └ HostConnection (new)   │   iroh QUIC       │   allowlist of EndpointIds   │
│       ├ SSHHost (today)    │── direct or ─────▶│   ├ tmux -C attach (no PTY)  │
│       └ IrohHost (new)     │   relay, E2E      │   ├ $SHELL -c <script>       │
│           EtLink.xcframework│                  │   └ write upload file        │
│           (Rust + UniFFI)  │                   │ etd pair → QR in terminal    │
│ one iroh Endpoint for all  │                   └─────────────────────────────┘
│ servers                    │                     (one etd per machine)
└───────────────────────────┘
```

The phone has one iroh endpoint and one key. It connects to many machines. Each machine has its own `etd`, key, and allowlist.

### 4.1 Repository layout (new parts)

Two repositories. The daemon and the protocol are public from the first commit. The app becomes public and open source later (phase 8, §10.5). It stays private while phases 0–6 make your own setup work.

```
github.com/ericsharma/etd   (new, PUBLIC, MIT OR Apache-2.0, the same as iroh)
  crates/et-proto/          wire types and framing, shared by both ends
  crates/etd/               daemon + CLI (Linux, macOS)
  crates/et-link/           client library; UniFFI facade for iOS
  vendor/netdev/            iOS patch, copied from ~/p2poker/crates/vendor/netdev
  docs/PROTOCOL.md          the et/1 specification (§5), kept current with the code
  docs/SECURITY.md          threat model and how to report a problem
  install.sh                curl | sh installer (§10.2)
  flake.nix                 etd package, NixOS + home-manager + nix-darwin modules, devShell
  .github/workflows/        CI, and release binaries on each tag

github.com/ericsharma/et-ios   (this repository, private)
  scripts/build-link.sh     builds EtLink.xcframework from a pinned etd tag (git submodule)
  App/Generated/EtLink.xcframework   built on the m1-mini, not in git
```

Keep networking in Rust, the same as p2poker. Do not use the IrohLib Swift package.

Before the first commit: check that the name `etd` is free on crates.io and Homebrew. If not, use `et-daemon` for the package and keep `etd` as the binary name.

## 5. Protocol `et/1`

- One ALPN: `et/1`. Bump the number on any wire change (zedra rule, PROTOCOL_SPECS §2.4).
- One iroh connection per E.T. session. Each operation opens one bi-stream.
- The first frame of a stream is a request: `u32` length + postcard. Then the stream carries the operation's data.
- `etd` reads `connection.remote_id()`. It accepts only `Pair` from an `EndpointId` that is not in the allowlist. It closes all other streams from that peer.

| Request | Response and stream data | Replaces |
|---|---|---|
| `Pair { secret, device_name }` | `Paired { host_name }` or `Rejected(reason)` | (new) |
| `Hello { app_build }` | `HostInfo { host_name, os, etd_version, tmux_path, tmux_version, tmux_tmpdir }` | `findTmux` |
| `ListSessions` | `Vec<SessionInfo>` | `listSessions` |
| `Control { target: Attach(name) \| AttachOrCreate(name) }` | down: frames `Stdout(bytes)`, `Stderr(text)`, `Exit(code)`; up: raw bytes to tmux stdin | `openControlChannel` |
| `Exec { script }` | `ExecResult { output, exit_code }` | `run` |
| `Upload { path, len }` + `len` raw bytes | `Ok` or `Error(text)` | `upload` |
| `Ping` | `Pong` | (liveness) |

Rules:

- `Control`: `etd` runs `tmux -C attach-session -t =<name>` with `TERM=et-ios` and no PTY, the same as SPEC.md §2.1 step 4. When the stream closes, `etd` closes tmux stdin. tmux detaches. The session continues.
- `Exec`: `etd` runs `/bin/sh -c <script>` in the home directory, with the login environment (§7.2) and stderr joined to stdout. This is the same as the app's SSH `run` wrapper today. The output is bytes, decoded as UTF-8 with replacement on the phone. The limit is 120 s and 8 MiB of output (`truncated` is set).
- `Upload`: the path must be under `$HOME`. `etd` rejects other paths. The maximum size is 32 MiB.
- Keep `ControlParser`, `TmuxCommand`, and all tmux logic in Swift. `etd` does not parse tmux output. It only moves bytes.

### 5.1 Versions

Other people will run old daemons with new apps, and new daemons with old apps. Plan for this from the first release:

- `etd` accepts the current ALPN and the one before it (`et/2` and `et/1`). zedra does the same (PROTOCOL_SPECS §7.4).
- The app offers all ALPNs that it knows. iroh selects the newest one that both ends have.
- `HostInfo` carries `capabilities: Vec<String>` (for example `"upload"`, `"exec"`). Add new optional features as capabilities, not as ALPN bumps.
- If no ALPN matches, the app shows "Update etd on <host>" or "Update E.T.", not a connection error.
- `etd --version` and `HostInfo.etd_version` use semantic versions.

### 6.1 Pairing steps

1. On the machine, run `etd pair` (local, or over any SSH). It makes a random 32-byte secret, stores its hash in the state directory with a 10-minute expiry, and prints a QR code in the terminal. `etd pair --url` prints only the URL, for copy and paste.
2. The QR code holds a URL: `et://pair?t=<TICKET>`. The ticket is upper-case base32 postcard of `{ endpoint_addr (id + relay URL), secret, expires, host_name }`. Direct addresses are not in the ticket: with 6 addresses (bridges, VPNs) the QR code was 73 columns wide. Hole punching finds the direct path after the first connect. The QR code is 57 columns wide. Upper case lets QR use its compact alphanumeric mode. iroh 1.4 has no built-in mDNS address lookup.
3. Scan the QR code with the iPhone Camera app. iOS opens E.T. through the `et` URL scheme. No in-app scanner is necessary for the first release.
4. E.T. shows a confirm sheet: host name and `EndpointId` fingerprint.
5. E.T. connects with its iroh key and sends `Pair`.
6. `etd` checks the secret, deletes the pending secret (one use only), and adds the phone's `EndpointId` and device name to its `clients.json`.
7. E.T. adds the server with `transport: iroh` and the machine's `EndpointId` pinned.

The `pair` command and the daemon share files only. No socket between them is necessary.

One phone pairs with many machines. One machine accepts many phones (iPhone and iPad).

### 6.2 Keys

- Machine: `secret.key` in the config directory, mode 0600, made on first start. The `EndpointId` stays the same across restarts.
- Phone: one iroh key for the device, for all machines. iroh keys are Ed25519. The Secure Enclave does not support Ed25519. Store the key in the Keychain with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`. It is not in backups and does not move to a new phone. This is weaker than the current Secure Enclave SSH key. The risk is acceptable for a key that only paired daemons trust, and that each daemon can revoke.
- Both ends check keys in the iroh TLS 1.3 handshake. zedra's `Register` / `Connect` / `AuthProve` steps are not necessary: iroh already proves both identities.

### 6.3 Control commands

- `etd clients` lists paired devices.
- `etd revoke <name|id>` removes a device. `etd` closes its open connections.
- `etd status` shows the `EndpointId`, relay, direct addresses, and connected devices.
- Never write the pairing URL or the secret to a log.
- Limit `Pair` attempts: 5 for each minute for each peer, and close the connection after a wrong secret.
- No telemetry. `etd` sends nothing to you or to other services, except iroh relay and address lookup traffic.

### 6.4 Relays and discovery

- Default: `presets::N0` (n0 public relays + DNS address lookup). Relay traffic is end-to-end encrypted. The relay sees only the two `EndpointId`s. Before the public release, read n0's current terms for the public relays (rate limits, production use). If they do not permit a public product, the public default must be a relay that you run (§10.4).
- `etd` config option `relay = "https://…"` sets a self-hosted `iroh-relay`. The ticket carries the relay URL, so the phone uses the same relay for that machine. p2poker S5 already tested `iroh-relay` 1.4.
- Add LAN (mDNS) address lookup if iroh 1.4 has it. On the same LAN the connection is then direct without a relay.

## 7. The daemon on any machine

### 7.1 Files

Use the platform directories (`directories` crate), with an `ETD_HOME` override:

| | Linux | macOS |
|---|---|---|
| Config (`secret.key`, `clients.json`, `etd.toml`) | `~/.config/etd/` | `~/Library/Application Support/etd/` |
| State (pending pair secrets) | `~/.local/state/etd/` | same as config |
| Log | journal | `~/Library/Logs/etd.log` |

### 7.2 Environment and tmux discovery

A service manager starts `etd` with a small environment. tmux, `git`, `ssh`, and `curl` can be missing from `PATH`, and `TMUX_TMPDIR` can be wrong.

1. At start, `etd` runs `$SHELL -l -c 'env -0'` one time and keeps the result as the environment for tmux and `Exec`. If this fails, it uses its own environment.
2. Then `etd` finds tmux and the socket directory. Move the current Swift logic (`SSHConnection.findTmux`, SPEC.md §2.1 step 2) into Rust: the same path list and the same socket directory list (`$TMUX_TMPDIR`, `$XDG_RUNTIME_DIR`, `/run/user/<uid>`, `/tmp`, macOS `$TMPDIR`).
3. `Hello` reports what `etd` found. The app shows "tmux not found" with this output, as it does today.

### 7.3 Install and service

- `etd install` writes and starts a user service: a systemd user unit on Linux, a launchd agent (`~/Library/LaunchAgents/xyz.ericsharma.etd.plist`) on macOS. `etd uninstall` removes it.
- Linux without a desktop login: `etd install` tells you to run `loginctl enable-linger $USER`. Without it, the service stops when you log out.
- Nix: the flake gives a home-manager module (`services.etd.enable`) for NixOS and nix-darwin. Your machines (trigkey, gmktec, Mac mini) use it from `~/nixos-config`.
- Other machines: the installer or a release binary, then `etd install` (§10.2).
- `etd` with no arguments and no service installed: start in the foreground and show the QR code. This is the "out of the box" path: download, run, scan.
- No firewall change is necessary. iroh uses outgoing UDP and hole punching. Optional config: `port = <n>` binds a fixed UDP port, to open in a firewall for quicker direct connections.

## 8. App changes

1. Add a `HostConnection` protocol with the calls in §2.1. Make `SSHConnection` conform to it. Change `SessionController.connection` to `any HostConnection`. Map errors to one `HostError` enum, so that `SessionController` lines 360–390 do not depend on SSH types.
2. Add `ServerConfig.transport`: `.ssh(host, port, user, hostKey)` or `.iroh(endpointId, addr)`. Decode old JSON as `.ssh`. Server ID, name, last session, and templates stay per server, so several iroh machines work the same as several SSH machines.
3. Add `IrohHost: HostConnection` in a new `ETIroh` target. It wraps `EtLink`. `IrohControlChannel` reads `Stdout` frames into `incoming()` and sends `Stderr` frames to the debug log.
4. Start one iroh endpoint at app launch and share it for all servers. p2poker measured 3.1 s for a native iOS endpoint start. Do not start it again for each connect.
5. Handle `et://pair?t=…` in `ETApp` (`onOpenURL`). Also add "Paste pairing link" in the Servers screen.
6. Push: for your machines, keep `et-notify` and the device file (`~/.config/et/devices/*.json`). For other people, push needs a gateway (§10.3). Design the push hook in `etd` now (`etd notify <window>`), so that the gateway is a later change in one place.
7. Info.plist: register the `et` URL scheme. Keep `NSLocalNetworkUsageDescription`. Link `SystemConfiguration` and `Network`.
8. Header status: show "direct" or "relay" for the connection. This helps when typing feels slow.

The lifecycle (SPEC.md §5.5) does not change. On background, E.T. closes the control stream. On foreground, it reconnects.

## 9. Your use first, public later

Phases 0–6 (§11) give you a working system on your own machines. Phases 7–9 make it public. The public work does not change the protocol or the app design, because §4.1, §5.1, and §8 item 6 already plan for it.

## 10. Public release requirements

### 10.1 Out of the box

A new user with a Linux or macOS machine and tmux must do only this:

1. `curl -fsSL https://<site>/install.sh | sh`
2. `etd install` (or `etd` to try it in the foreground)
3. Scan the QR code with E.T.

No account, no configuration file, no open port, no SSH server. `etd` makes its key and its configuration on first start. All defaults must be safe: no device is paired until a QR code is scanned.

### 10.2 Binaries and install

| Channel | What |
|---|---|
| GitHub Releases | `etd` for linux x86_64 and aarch64 (static musl), macOS arm64 and x86_64. SHA-256 checksums and a minisign signature for each file. |
| `install.sh` | Finds the OS and CPU, downloads the binary, checks the checksum, puts it in `~/.local/bin`. No `sudo`. |
| Homebrew tap | `brew install ericsharma/tap/etd` |
| Nix flake | `nix run github:ericsharma/etd` and the modules in §7.3 |
| `cargo install etd` | For people who build from source |

macOS: sign the binary with a Developer ID certificate and notarize it. Without this, Gatekeeper blocks a downloaded binary. The App Store Connect API key in `scripts/asc.env` can notarize, but a Developer ID Application certificate is a separate certificate. Make it in phase 7.

Updates: `etd update` downloads the newest release, checks the signature, replaces the binary, and restarts the service. Homebrew and Nix users update with their package manager.

### 10.3 Push for other people

Today `et-notify` on trigkey sends to APNs with your APNs key. You cannot put that key on other people's machines. Use a small push gateway that you run:

1. At pairing, E.T. registers its APNs token with the gateway. The gateway returns a random push token for this phone and this machine.
2. E.T. sends the push token to `etd` (new request `RegisterPush`).
3. On a tmux bell, `etd notify` sends `{ push token, title, body }` to the gateway over HTTPS.
4. The gateway sends to APNs. It never sees the terminal session, only the short notification text.

Privacy option: `etd` can encrypt the body with a key that only the phone has. A Notification Service Extension in E.T. decrypts it. Then the gateway sees nothing but the push token.

Without the gateway, other people get all features except push. That is acceptable for the first public release.

### 10.4 Relay for other people

- If n0's terms permit it: keep `presets::N0` as the default.
- If not: run your own `iroh-relay` on a public host and make it the default. Users can always set their own relay in `etd.toml`.

### 10.5 The app

The app becomes public and open source. The public daemon is not useful without a public app. The app is currently in internal TestFlight only.

Before the repository becomes public:

- `scripts/asc.env` is in git. It holds your App Store Connect key ID, issuer ID, and team ID. These are not the private key (`.p8` is never committed), but move them out of git: read them from `~/.appstoreconnect/asc.env`, and commit an `asc.env.example`.
- Search the full git history for other personal data (host names, LAN IPs, Tailscale IPs, `Isabel`). SPEC.md §1.1 and `App/Sources/Views.swift:318` have some. Publish a new repository with a squashed first commit if the history is not clean.
- Change the bundle ID in `App/project.yml` to a placeholder that each builder sets, and keep yours in a local file.

Release:

- A public TestFlight link is the first step. It needs a Beta App Review.
- App Store review: the volume button workaround in select mode (SPEC.md §5.4) is not App Store safe. Turn it off in the public build, or remove it.
- Mac mini, Grok, and Kokoro settings already read from the user's own machine (`summary.env`). They need no change.
- Remove names that are only for you (for example "say hi to Isabel" in the header) from the public build, or make them a setting.
- SSH stays for users who do not install `etd`.

### 10.6 Documents

- `README.md`: what it is, the 3 install steps, a GIF.
- `docs/PROTOCOL.md`: §5 of this plan, kept current with the code.
- `docs/SECURITY.md`: what a paired device can do (everything the user can do), how to revoke, key storage, relay trust, how to report a problem.

## 11. Phases

Time estimates are for an agent doing the work, plus your test time.

| # | Phase | Result you can test | Estimate |
|---|---|---|---|
| 0 | **Spike** on trigkey: `etd` with `Hello`, `ListSessions`, `Control`. A small Rust CLI client attaches to tmux over iroh and prints `%output` lines. | `etd-probe attach <id> 0` shows live tmux events through a relay | 2–3 h |
| 1 | **Daemon complete on Linux**: `Exec`, `Upload`, `Pair`, allowlist, QR, `clients`, `revoke`, `status`, login environment, tmux discovery. Tests with a throwaway tmux socket. | `etd pair` prints a QR; `etd-probe` passes all requests | 4–5 h |
| 2 | **Packaging**: `etd install` for systemd and launchd, macOS paths, flake modules, release workflow. Deploy to trigkey, gmktec, and the Mac mini. | `etd status` works on all three machines (two Linux, one macOS) | 3–4 h |
| 3 | **iOS link library**: `et-link` UniFFI facade, `build-link.sh`, xcframework on the m1-mini. Copy the netdev patch and the `libc` 0.2.189 pin from p2poker. | Simulator test: connect and get `HostInfo` | 2–3 h, more if the iOS build breaks |
| 4 | **App transport**: `HostConnection`, `IrohHost`, `ServerConfig.transport`, pairing URL, status label. | TestFlight build: pair all three machines by QR; Tailscale off | 3–4 h |
| 5 | **Field test** (you): cellular, Wi-Fi → cellular switch, app in background for 1 h, machine reboot, revoke a device, push from a machine that is not trigkey. | Short checklist | 30 min |
| 6 | **Cleanup and docs**: remove the Tailscale-only code (approval screen, banner timeout). Keep SSH. Update SPEC.md §1, §2.1, §7 and GUIDE.md. Write an `etd` README with the 3-step install. | SPEC describes both transports | 1–2 h |
| 7 | **Public daemon**: `install.sh`, signed and notarized macOS binary, minisign signatures, Homebrew tap, `etd update`, `PROTOCOL.md`, `SECURITY.md`. Test on a clean Ubuntu VM and a Mac user account with no Nix. | A new machine works with the 3 steps in §10.1 | 1 day, plus Developer ID setup |
| 8 | **Public app**: public build settings (§10.5), public TestFlight link. | A friend installs E.T. and `etd` with no help from you | 3–4 h, plus Apple review time |
| 9 | **Push gateway** (§10.3): gateway service, `RegisterPush`, `etd notify`, optional encrypted body. | A friend's machine sends a push to their phone | 1 day |

Phases 0–6 (your machines): about 2.5 working days of agent time. Phases 7–9 (public): about 2.5 more days, plus Apple review. Phase 0 tells early if the main risk (latency through a relay) is acceptable.

### 11.1 Phase 0 results (2026-10-22, trigkey → trigkey)

Code in `~/etd`: `et-proto` (types, framing, ALPN `et/1`), `etd` (daemon: `Hello`, `ListSessions`, `Control`, `Ping`; allowlist in `clients.json`; `etd id`, `etd allow`, `etd clients`), `etd-probe` (test client). iroh 1.4.1, `presets::N0`.

| Test | Result |
|---|---|
| tmux discovery with `TMUX_TMPDIR` unset in the daemon | Found `/run/user/1000` through the login shell environment |
| Connect (n0 relay, us-east) | 100–300 ms, then hole punching moves the connection to a direct path |
| 50 tmux command round trips, direct path | median 0.8 ms, max 5 ms |
| 50 tmux command round trips, relay only (`--relay-only`) | median 33 ms, max 44 ms |
| Attach, one command, close stdin | tmux replies, `%exit`, exit code 0; the session continues |
| Device not in `clients.json` | Connection closed with "not paired" |
| Session that does not exist | tmux `%error` "can't find session" reaches the client |

Conclusion: relay latency (33 ms) is acceptable for typing. Phase 5 must still measure a phone on cellular.

### 11.2 Phase 1 results (2026-10-22)

Added: `Pair`, `Exec`, `Upload`; `etd pair [--url]` (QR in the terminal), `etd status`, `etd revoke`; `status.json` and one-use pending secrets in the state directory; revokes and status every 2 s; 5 pairing tries per minute per device; SIGTERM handling.

Tests (`cargo test`, 7 tests): an integration test runs the daemon in-process with offline iroh endpoints and a throwaway tmux server. It checks: unpaired devices are refused, wrong and used secrets are refused, pairing works and the connection continues as paired, tmux discovery, sessions, control attach and detach, exec output and exit code, uploads inside home only (also through a symlink), the status file, revoke closes the connection, and the try limit.

Live over the n0 relay: pair by link, the same link refused for a second device, exec, upload, revoke of a connected device.

### 11.3 Phase 2 results (2026-10-22)

Scope change: deploy to **trigkey only**. All tmux windows run on trigkey and ssh to the other machines, so only trigkey needs `etd`. gmktec and the Mac mini were in this phase only to test portability; that moves to phase 7. The launchd code is written but not tested on macOS.

- `etd install` / `etd uninstall` (systemd user unit; launchd agent). `etd` run by hand with no paired device shows the QR code.
- The login shell comes from `$SHELL`, else the user database (launchd does not set `$SHELL`).
- Flake: `packages.etd`, `homeManagerModules.default` (`services.etd.enable`).
- Repository: github.com/ericsharma/etd, public, MIT OR Apache-2.0, with README.
- nixos-config `eacf80a`: input `etd` (follows `nixpkgs-unstable`), `home/trigkey/etd.nix`, docs row. Deployed with `rebuild`.
- Check after deploy: the service found tmux at `/run/user/1000`; a probe paired, listed sessions, and ran a command; then it was revoked. 0 devices are paired.

### 11.4 Phase 3, Linux part (2026-10-22)

`crates/et-link` (etd commit `369b2d2`): the Swift-facing client over UniFFI 0.32 with async exports. `Link` (one endpoint per device; `start`, `pair`, `connect`), `RemoteHost` (`hello`, `list_sessions`, `exec`, `upload`, `open_control`, `ping`, `path`, `closed`), `ControlStream` (`next`, `write`, `finish`), typed `LinkError` (`NotPaired` after a revoke). The Swift class is `RemoteHost`, because `Host` clashes with Foundation on macOS. iOS fixes from p2poker: `vendor/netdev`, `libc` 0.2.189. Tested on Linux against an in-process etd; the Swift bindings generate. The Mac part (xcframework, `apple/EtLink` Swift tests, Simulator end to end) is for the Mac mini agent.

### 11.6 Phase 5 results (2026-10-22, the owner on the iPhone, Tailscale off)

| Test | Result |
|---|---|
| Pair by QR code | Pass |
| Windows, typing | Pass |
| Wi-Fi off, then on again while connected | Pass: E.T. reconnects by itself |
| Image upload into a Claude window | Pass |
| Push after a command of more than 15 s | Pass |
| E.T. in the background for 1 hour | Not reported |


### 11.5 Idea: manymux for sessions on other machines (not planned yet)

[manymux](https://github.com/rayfish/manymux) (MPL-2.0, v0.2.2) keeps terminal sessions on each machine (its own PTY daemon, no tmux), lists sessions across machines, and routes bells to you. It reaches machines with `ssh <host> mm agent` and has no networking of its own. Its protocol runs on any byte stream, and its client core builds for mobile (`--no-default-features`, already used by its iOS app).

How it could fit: etd gets one request, `Pipe { host: Local | Ssh(name) }`, that connects an iroh stream to `mm agent` on the hub or `ssh <name> mm agent` from the hub. E.T. links the manymux client core and gives it that stream. Result: iroh for phone → hub, ssh for hub → machines (keys already trusted), and each machine only needs `mm`. E.T. shows a second page type for manymux sessions (a plain terminal stream; manymux repaints on the server). tmux pages keep working as now.

Cost and risk: etd side about 1 day; app side about 2–3 days. The project is young (11 stars); pin one manymux version on both ends. tmux-only E.T. features (window list, select mode history, Copilot transcripts, size claims) do not apply to manymux pages.

**Incident:** the first test run killed the user's real tmux server. The test set only `TMUX_TMPDIR`; the inherited `$TMUX` (Claude runs in a tmux pane) wins over it, so the test's `kill-server` reached the real server. Restored from the tmux-resurrect save. Fixes: `etd` removes `$TMUX`/`TMUX_PANE` before every tmux command (the daemon had the same bug); the test uses `-S <socket>` for every tmux command.

## 12. Risks

| Risk | Effect | What to do |
|---|---|---|
| iroh does not build for iOS | Phase 3 stops | p2poker already fixed this (netdev patch, `libc` pin, linker frameworks). Copy the fix. |
| Login environment differs a lot between machines (fish, slow `.zshrc`, prompts) | tmux not found, or `Exec` fails | 5 s limit on the `env` step; fallback to service environment; `etd status` shows the `PATH` used. |
| Relay latency on cellular | Typing feels slow | Show direct/relay in the header. Measure in phases 0 and 5. A self-hosted relay is the fix. |
| Endpoint start is slow on iOS (3.1 s) | Slow first connect | Start at launch. Show "Starting network…" in the connecting banner. |
| `Exec` is a full remote shell | A stolen paired phone can run commands on every paired machine | Same power as SSH today. `etd revoke` on each machine. Keychain key is "this device only". |
| n0 relay or DNS is down | No connection away from home | LAN addresses still work at home. A self-hosted relay removes the dependency. |
| A security bug in a public `etd` gives shell access to strangers | Serious harm to other people | Small code surface; no request runs before the allowlist check; `cargo audit` in CI; `SECURITY.md`; an outside review before you call it 1.0. |
| Old daemons and new apps do not match | Users cannot connect | Two ALPNs at a time, capabilities, a clear "Update etd" message (§5.1). |
| Running the relay and push gateway costs money and time | Ongoing work for you | Both are small. Users can set their own relay. Push is optional. |

## 13. Not in this plan

- A general mesh VPN (TUN device, IP for each device). Not necessary: see §2.2.
- Machine-to-machine links. Use SSH between machines as today.
- Windows hosts (no tmux).
- An in-app QR scanner. The Camera app and a pasted link are enough for the first release.
- Sharing a machine with other people (roles, read-only access).
- Push over iroh. APNs stays, through the gateway for other people.
- An Android app.

## 14. Open questions

1. n0 public relays as the default, or a self-hosted relay from the start? (A self-hosted relay needs a host with a public IP. It is necessary for the public release only if n0's terms do not permit it.)
2. ~~The app: public or private?~~ Answered 2026-10-22: public and open source, after your own setup works (phases 0–6 first).
3. A website for `install.sh` and the docs: a domain you have (for example `ericsharma.xyz`), or GitHub Pages?
