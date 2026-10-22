# Plan: manymux sessions on all machines, over etd

Status: 2026-10-22. A1 and B1 done: manymux v0.2.2 nodes run on trigkey, gmktec and the Mac mini (nixos-config a5f8cc0); `mm ls` on trigkey reaches all three. Next: A2. Follows [PLAN-iroh.md](PLAN-iroh.md).

## 1. Goal

Your work runs in [manymux](https://github.com/rayfish/manymux) sessions on trigkey, gmktec, and the Mac mini, not in one tmux session on trigkey. E.T. shows the sessions of all three machines in one list, through the one iroh link to etd on trigkey.

- A session lives on its own machine. A crash or reboot of trigkey does not stop sessions on gmktec or the Mac mini.
- Each session shows its title (Claude Code sets it to its current task), idle time, and a bell mark.
- New session from the phone: choose a machine, then a command.
- View-only mode that does not change the size for other devices.
- The tmux mode stays in the app (for other users, and as a fallback). Your daily use moves to manymux.

## 2. Facts that decide the design (checked 2026-10-22)

| Fact | Where | Effect |
|---|---|---|
| manymux reaches a machine with `ssh <host> mm agent` and has no networking of its own | README "How it works" | etd connects an iroh stream to `mm agent`; trigkey's ssh keys do the rest |
| The protocol is generic over `AsyncRead`/`AsyncWrite` | `src/proto.rs` header | iroh streams implement both (noq 1.4), so no adapter is necessary |
| The client core builds without PTYs (`--no-default-features`), and manymux's own iOS app links it | `Cargo.toml`, `ios/README.md` | et-link links the manymux crate; one xcframework |
| Requests: `List`, `Spawn`, `Kill`, `Rename`, `Attach { history, read_only }`, `Events`, `Peek`, `Snapshot`, `Version` | `src/proto.rs` | Everything the app needs exists |
| A node's `Events` feed carries `HostedEvent { host, event }` for the machines it watches | `src/proto.rs` | etd subscribes once, to trigkey's node, for push from all machines |
| A node restart ends every session | README "Keeping it running" | The service must never restart on a deploy (`X-RestartIfChanged = false`), the same as tmux-server |
| `mm --socket <path>` selects the node | `src/main.rs` | Tests use their own socket. Never the default `/tmp/manymux-<uid>/manymux.sock` |
| Non-interactive ssh to the Mac mini has no `/etc/profiles/per-user/…` in `PATH` | `ssh mac-mini 'echo $PATH'` | On the Mac mini, `mm` goes in `environment.systemPackages` |
| License MPL-2.0, version 0.2.2, edition 2024, Rust 1.91 or later | `Cargo.toml` | Pin one git commit everywhere; building from source is allowed |

## 3. Design

```
iPhone (E.T.)                       trigkey                          gmktec / Mac mini
EtLink: manymux client  ──iroh──▶  etd ── Agent{host: None} ──▶ mm agent ─▶ trigkey's node
                                     ├── Agent{host: gmktec} ──▶ ssh gmktec mm agent ─▶ node
                                     ├── Agent{host: mac-mini} ─▶ ssh mac-mini mm agent ─▶ node
                                     ├── ExecOn{host, script}  ─▶ ssh <host> /bin/sh -c …
                                     └── Events on trigkey's node ─▶ et-notify ─▶ APNs
```

### 3.1 etd protocol `et/2`

etd accepts `et/2` and `et/1` (PLAN-iroh §5.1). New requests:

| Request | What etd does |
|---|---|
| `Agent { host: Option<String> }` | After `AgentStarted`, the stream is a byte pipe to `mm agent` (None: on trigkey) or `ssh -o BatchMode=yes <host> mm agent`. etd does not read the bytes. |
| `ExecOn { host: String, script }` | Like `Exec`, through `ssh -o BatchMode=yes <host> /bin/sh -c`. For features that read files on the session's machine: Copilot transcripts, read aloud, dictation names. |
| `Machines` | The machines that trigkey's node watches (`mm hosts`), plus trigkey itself. |

`host` must be one of `Machines`. etd refuses other names, so a paired phone cannot make trigkey ssh to any address.

### 3.2 Push

etd keeps one `Events` stream to trigkey's node. On `Bell` or `Notify` in a session that nobody is attached to, it runs `et-notify --manymux <host> <session> <title>` with the body text. et-notify keeps its rules: no push while E.T. is open (heartbeat file), one push for each session in 10 s. manymux's own desktop notifier is off (`mm daemon --no-notify`): trigkey has no desktop.

### 3.3 Images

On a manymux page, the image goes in manymux's own `PASTE` frame. The session's machine writes the file and the program gets the path. etd's `Upload` stays for tmux pages.

## 4. Who does what

### A. trigkey session (Claude on trigkey)

| # | Work | Result you can check | Estimate |
|---|---|---|---|
| A1 | nixos-config: manymux flake input (one pinned commit), package, `mm daemon --no-notify` user service with `X-RestartIfChanged = false` on trigkey and gmktec. `mm add gmktec`, `mm add mac-mini` on trigkey. Write the nix-darwin module for the Mac mini (deployed by B1). Deploy trigkey and gmktec. | `mm ls` on trigkey lists all three machines | 2–3 h |
| A2 | etd `et/2`: `Agent`, `ExecOn`, `Machines`; host allowlist. Tests use their own node (`mm --socket`). | `etd-probe agent gmktec` lists gmktec's sessions | 3 h |
| A3 | et-link: manymux API for Swift. `machines()`, `sessions(host)`, `spawn`, `kill`, `rename`, `peek`, `attach(host, name, size, history, readOnly)` → a session stream (output, input, resize, paste image, detach, exit, events), `execOn`. Linux tests against an isolated node. | Tests pass; Swift bindings generate | 4–5 h |
| A4 | Push: etd `Events` subscription, `et-notify --manymux` in nixos-config. | A bell in a gmktec session sends a push | 2 h |
| A5 | The prompts for B, in the order below. | | — |

### B. Mac mini agent (Apple builds, the app)

| # | Work | Result |
|---|---|---|
| B1 | `darwin-rebuild switch --flake ~/nixos-config#m1-mini` after A1: `mm` in `environment.systemPackages`, launchd agent for `mm daemon --no-notify`. | `ssh mac-mini mm --version` works from trigkey |
| B2 | Bump `Vendor/etd`, rebuild the xcframework. | Builds |
| B3 | Machines screen: sessions grouped by machine (title, idle, bell mark, attached count); tap opens a session page (SwiftTerm fed by the attach stream); swipe = next session on the machine; another gesture = next machine; long-press = rename, end, view-only; **+** = machine, then command. Image paste through `PASTE`. Overview thumbnails through `Peek`. TestFlight. | TestFlight build 1 |
| B4 | Parity on manymux pages: select mode history (`history` lines on attach), Copilot and read aloud through `ExecOn`, key row from the session's command or title. TestFlight. | TestFlight build 2 |

### C. You

| # | Work | When |
|---|---|---|
| C1 | Test TestFlight build 1 on the phone (list, open, type, new session on gmktec, view-only, image). | After B3 |
| C2 | Start your real sessions in manymux (`mm new claude`, `mm new gmktec claude`, …) and use them for a day. | After C1 |
| C3 | Decide when to stop the tmux session on trigkey. tmux stays installed. | After C2 |

### Order

A1 → B1 → A2 → A3 → B2 + B3 → C1 → A4 → B4 → C2 → C3.

Agent time: about 2 days on trigkey (A), and the Mac agent's time for B.

## 5. Rules

- Tests start their own manymux node with `mm --socket <temp>` and pass that socket to everything. Never the default socket, never `mm restart`, `mm stop`, or `mm update` on a real machine. (The same lesson as the tmux incident, PLAN-iroh §11.2.)
- One manymux commit for the Nix package and for et-link. A bump changes both, and the deploy order is: all nodes first, then the app.
- etd stays a byte pipe for manymux. It does not parse manymux frames, except on its own `Events` stream for push.

## 6. Risks

| Risk | What to do |
|---|---|
| manymux is young (0.2.2); its protocol changes | One pinned commit; manymux skips unknown frame tags, and its nodes answer old requests |
| A node restart ends every session | `X-RestartIfChanged = false`; restart only by hand, with `mm update --keep-sessions` |
| `ssh` from etd waits on a prompt (new host key, passphrase) | `BatchMode=yes`; the error reaches the app |
| E.T. features that need tmux | B4 moves them to manymux; until then they work on tmux pages only |
