# Plan: the etd network (one install per machine, out of the box)

Status: draft, 2026-10-22. Not started. The decisions in §8 need the owner's answer before N1.

Follows [PLAN-iroh.md](PLAN-iroh.md) and [PLAN-manymux.md](PLAN-manymux.md). Replaces the hub design of PLAN-manymux §3 (trigkey reaches the other machines with ssh) when N6 is done.

## 1. Goal

A user installs `etd` on each machine and gets everything, with no other setup:

1. First machine: `etd install`, then `etd invite`. Scan the QR code with the phone.
2. Each further machine: `etd install`, then `etd join <link>`, with a link from `etd invite` on any machine already in the network (or from the app).
3. Each further phone or tablet: scan an invite.

Then:

- The phone shows every machine's sessions and connects to each machine **directly** over iroh. There is no hub: when one machine is down, the others still work.
- In a terminal on any machine, `mm ls` and `mm attach` reach every machine in the network. No ssh keys, no `~/.ssh/config`, no `mm add`, no `PATH` changes.
- Bells reach the phone from every machine.
- A revoke on any machine removes the device everywhere.

## 2. Why the current setup does not meet the goal

| What a new user would have to do today | Why |
|---|---|
| Install `mm` on every machine, apart from `etd` | etd only runs on the hub |
| Password-free ssh keys and `~/.ssh/config` names, hub → every machine | manymux reaches machines with `ssh <host> mm agent` |
| `mm add` each machine on the hub | the hub's node watches only listed machines |
| Fix service `PATH`s (as for `ssh`, nixos-config 9992672) | services start with a small `PATH` |
| Accept the hub as a single point of failure | the phone talks only to the hub's etd |

## 3. Facts that decide the design (checked 2026-10-22)

| Fact | Where | Effect |
|---|---|---|
| manymux runs `$MM_SSH -T -o … <host> -- mm agent` for sessions, `$MM_SSH … <host> -- <script>` for checkpoint reads, `$MM_SSH … <host> -- true` to greet | manymux `src/ssh.rs` | `etd-ssh` must handle these three forms and can ignore `-T`, `-t` and `-o` options |
| `MM_SSH` replaces only the program name | manymux `src/ssh.rs` | manymux needs no change |
| A manymux node answers one request per stream, except `Attach` and `Events` | manymux `src/node/mod.rs` | `etd-ssh` opens one etd `Agent` stream for each manymux connection |
| etd `Agent { host: None }` already pipes a stream to the local `mm agent` | etd `server.rs` | The machine-to-machine path is `etd-ssh` → the target's etd → `Agent { host: None }` |
| A paired device already has an iroh key, an allowlist check and a revoke | etd `config.rs`, `server.rs` | A network is the same idea, shared between machines |
| A node restart ends every session | PLAN-manymux §2 | The manymux node stays a separate process; an etd update must not restart it |
| Rayfish has closed networks with one-time invites, approval and member removal | rayfish README | A model to compare against in N0 |

## 4. Design

### 4.1 The network document

Each etd keeps one network: `~/.config/etd/network.json` (or the platform config directory).

```
Network {
  id: [u8; 16],                 // random, made by the first machine
  name: String,                 // for display
  members: [Member { id: EndpointId, name, kind: Machine | Device, added_by, added_at }],
  removed: [Removal { id: EndpointId, removed_by, at }],
}
```

- Each change is signed by the member that made it. A receiver accepts a change only from a current member who may make it (§8, D1).
- Merge: the union of members by id. For one id, the newest record (add or removal) wins. A removed device needs a new invite to come back.
- `clients.json` is replaced. On the first start of the new etd, the existing paired devices and the machine itself become the first members, so no device must pair again.

### 4.2 Sync

- On a change, etd sends the document to every machine member that it can reach (`NetworkUpdate`).
- On every connection from a member, both ends compare a hash of their documents and send the newer one if they differ.
- A machine that was offline gets the changes the next time it connects to, or hears from, any member.
- Phones read the document from any machine (`Network`).

### 4.3 Invite and join

- `etd invite [--machine | --device]` shows a QR code and a link, as `etd pair` does now: the inviting machine's address, a one-time secret (10 minutes), the network id and name.
- A phone scans it and sends `Join { secret, name, kind: Device }`. This replaces `Pair`.
- A machine runs `etd join <link>`. Its etd sends `Join { secret, name, kind: Machine }`, gets the document back, saves it, and the inviting machine sends the change to everyone.
- The app can also make an invite through any connected machine (`Invite` request), so a laptop can join from a link shown on the phone.

### 4.4 Sessions on other machines: `etd-ssh`

- etd installs `etd-ssh` and sets `MM_SSH=etd-ssh` for the manymux node and for the user's shells.
- `etd-ssh [-T | -t] [-o …]… <name> -- <command…>`:
  - `<name>` is a machine member's name. etd-ssh connects to that machine's etd over iroh, with the local machine's key.
  - `mm agent` → `Agent { host: None }` on the target, as a byte pipe.
  - `true` → exit 0 when the target answers `Ping`.
  - Anything else → `Exec { script }` on the target; the output goes to stdout, and the exit code becomes etd-ssh's exit code.
- etd keeps manymux's machine list (`~/.config/manymux/hosts.toml`) equal to the network's machines, so `mm ls` covers all of them with no `mm add`.

### 4.5 The manymux node

- The etd package also contains `mm` (one pinned version). `etd install` installs and starts both services: etd, and `mm daemon --no-notify` with `MM_SSH=etd-ssh`.
- They are separate processes: an etd update or restart does not end any session. The node service never restarts on an update (as now: `X-RestartIfChanged = false`).
- The Nix module gets `services.etd.manymux.enable` (default on), which replaces `home/optional/manymux.nix`.

### 4.6 Push

- Each etd follows its own node's events (no node watches other machines any more).
- For a bell nobody saw, etd sends `Notify { note }` to the members that send pushes (D3). There, etd runs `ETD_NOTIFY_COMMAND` as now.
- "E.T. is open": the app sends `Foreground { until }` (now + 60 s) every 20 s to those members. They skip pushes until then. This replaces the heartbeat file for manymux sessions; the file stays for tmux.
- For other people, the push command is the push gateway (PLAN-iroh §10.3).

### 4.7 The app

- The member list comes from any connected machine (`Network`). The app connects to each machine member directly, with one `RemoteHost` each.
- The Machines screen and the ring: one section per machine member. Each machine's sessions come from that machine's own etd (`Agent { host: None }`). `exec` runs on the machine itself; `ExecOn` is no longer used.
- "Add device": an `Invite` QR code from a machine, shown in the app. "Devices": the member list, with Revoke.
- Restore sessions: `mm checkpoint restore` runs on a machine that is in the network (all machines are reached through `etd-ssh`).

### 4.8 Protocol additions (et/1, appended)

| Request | Response |
|---|---|
| `Join { secret, name, kind }` | `Joined { network }` or `Rejected(reason)` |
| `Network` | `NetworkDoc(network)` |
| `NetworkUpdate { network }` | `Pong` (sent between machines) |
| `Invite { kind }` | `Invitation { url }` |
| `Notify { note }` | `Pong` (machine → push member) |
| `Foreground { until }` | `Pong` (app → push member) |

`Agent { host: Some }`, `ExecOn` and `Machines` become unused after N6. With no users, they are removed then, with an ALPN change to `et/2`.

## 5. Phases

| # | Phase | Who | Result | Estimate |
|---|---|---|---|---|
| N0 | Read rayfish's membership model; answer §8; check manymux's `hosts.toml` format | me | Decisions written here | 1–2 h |
| N1 | Network document, sign, merge, sync, `invite`, `join`, revoke everywhere; `clients.json` migrated. Tests: 3 etds in one process | me | `etd join` works between two machines | 1.5–2 days |
| N2 | `etd-ssh`, manymux machine list kept equal to the network | me | `MM_SSH=etd-ssh mm ls` lists a second machine's sessions with no ssh keys | ½ day |
| N3 | etd installs and supervises the manymux node (`etd install`, Nix module) | me | One install gives both services | ½ day |
| N4 | Push: `Notify`, `Foreground`, events from every machine | me | A bell on any machine reaches the phone with no node watching others | ½ day |
| N5 | App: members, direct connections, invite and revoke screens | Mac agent | TestFlight build | 1–2 days |
| N6 | Your machines: etd on gmktec and the Mac mini, `etd join`; remove the ssh names, `mm add` list, `ws` changes; laptop by `etd join` | me + you | Your setup runs on the network | ½ day |
| N7 | Docs: README, PROTOCOL.md, PLAN-iroh §10 install story | me | | 2 h |

About 4–5 days. Your current setup keeps working until N6.

## 6. Rules

- Tests start their own etds, tmux servers and manymux nodes (`mm --socket <temp>`, private config and log directories, `$TMUX` removed). Never the real sessions.
- One manymux version everywhere, shipped with etd.
- Every member can run commands on every machine. Say so in the README and the app.

## 7. Risks

| Risk | What to do |
|---|---|
| A revoked device can still reach a machine that was offline during the revoke | Sync on every connection; a machine refuses a device that any member it talks to has removed; show "last synced" per machine |
| Clock differences break "newest record wins" | Add a counter per member to each record; time is only a tie-breaker |
| A stolen phone could revoke everyone | D1: only machines may revoke |
| manymux changes how it calls ssh | One pinned version; a test runs `mm ls` and `mm attach` through `etd-ssh` |
| Two machines with the same name | `join` refuses a name already in use |

## 8. Decisions for the owner

| # | Question | Recommendation |
|---|---|---|
| D1 | Who may invite, and who may revoke? | Machines and devices may invite; only machines may revoke |
| D2 | Approval: does a join need a "yes" on another device, or is the one-time secret enough? | The secret is enough (it already needs physical access to the QR code); add approval later for public networks |
| D3 | Which members send pushes? | Every machine with `ETD_NOTIFY_COMMAND` set; the app sends `Foreground` to all of them |
| D4 | More than one network per etd? | No: one network per etd |
| D5 | Does `etd install` also set `MM_SSH` in the user's shell startup file (as manymux's installer does for `PATH`)? | Yes, one line in `~/.zshenv` or `~/.profile`, and `etd uninstall` removes it |
