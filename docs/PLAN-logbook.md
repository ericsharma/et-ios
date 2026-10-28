# Plan: Logbook — every Claude session of the network, in one place

Status: 2026-10-28. D1–D10 ACCEPTED (D6 mechanism changed in L1, see §3). L0 DONE (results in §5, L0). A: L1 DEPLOYED 2026-10-28 (etd v0.0.8 = L1 + session-list fix; trigkey + gmktec, nixos-config 28201f4; trigkey is the archive). mac-mini: B runs darwin-rebuild. Next L2-A (read API in etd + et-link, then bump Vendor/etd). B: L2-B, L3-B and L4-B done on a stub (`App/Shared/LogbookStub.swift`): Mac sidebar Logbook, live transcript, report view with suggestions, Send to session. L5 (iOS/iPad) done on the stub, with 2 fixture transcripts; built, not run (no TestFlight until the stub is gone). The stub has A's accepted §4.5 changes 1–4 and 6 (LogChunk.live, line start, LogStream.close, LogEntry.title, `since`); 5 waits for the grouping schema. Views page: the last 3 MB first, then "Load earlier", 3 MB at a time. Next for B: swap the stub for the real API when A bumps Vendor/etd.

Follows [PLAN-network.md](PLAN-network.md) and [PLAN-files.md](PLAN-files.md). Work split as in those plans: **A** = the trigkey Claude session (etd, et-proto, et-link), **B** = the Mac agent (apps, builds), **C** = the owner (tests).

## 1. Goal

The owner works on one or two projects at the same time, with Claude sessions on different machines. The Logbook gives:

1. **One view of all sessions.** The full transcript of each Claude session on each machine, in the app, a few seconds behind.
2. **Projects, not machines.** The sessions are grouped by goal. Two sessions in different repos on one goal go in one project. Two sessions in one repo on different goals go in two projects.
3. **A network progress report**, on demand: what each project is about, what each session does for it, what is done, what is blocked, what is next.
4. **Context sharing**: send part of one session's transcript, or a part of the report, into a different session, in two taps.

| Where | What the owner does | Result |
|---|---|---|
| Mac app, sidebar **Logbook** | Click a project, then a session | Live transcript of that session (prompts, replies, tool calls folded) |
| Mac app or iOS | **Refresh report** | The watcher AI reads all sessions and writes the report (1–3 min) |
| Mac app or iOS | Accept / fix a grouping suggestion | The project list changes; the watcher keeps that choice from now on |
| Mac app or iOS | Select turns or a report section, **Send to session…**, pick a session | A Markdown file lands on that session's machine; its path is typed into the session (no Enter) |

## 2. Facts that decide the design (checked 2026-10-28)

| Fact | Where | Effect |
|---|---|---|
| Sessions now run in **manymux**, not tmux (tmux workspace removed 2026-10-22). manymux sends scrollback only on attach, with a size limit. No "capture" command. | `mm --help`, et-link `mm.rs:299` | Terminal scrollback is not a good source. D1: transcripts only. |
| Claude Code writes `~/.claude/sessions/<pid>.json` with `sessionId`, `cwd`, `status` (`busy`/idle), `updatedAt`. Present on trigkey, gmktec **and** mac-mini (macOS). | checked on all 3 | etd maps a Claude process to its transcript with no guessing. `status` gives live busy/idle for free. |
| The Claude process has `MM_SESSION=<name>` in its environment. `MmSession` in et-link has a `pid`. | `/proc/<pid>/environ`, `et-link/src/mm.rs:146` | Map Claude pid → manymux session by process tree (works on macOS too, where `/proc` does not exist). |
| The transcript is `~/.claude/projects/<cwd-slug>/<sessionId>.jsonl`, append-only. `/clear` and `--resume` start a new `sessionId` in the same manymux session. | `~/.claude/projects` | Tail by byte offset. One manymux session = a chain of transcripts. |
| The app already reads transcripts: `ETCore/Transcript.swift` (pick + parse turns), `Copilot.swift` (summaries with a model). It uses a shell script over `Exec` and **guesses** the file from a piece of the last prompt. | et-ios | Move the pick + parse into etd (Rust, exact). Reuse the turn view and the render-to-budget logic. |
| Files to a machine + typing a path into a session already work: `Share { path, to, session }`, `~/etd-downloads/`. | PLAN-files S1, F4 | Context sharing needs **no new transfer code**. |
| The `Request` enum ends at `Unshare` (23). Append at the end keeps `et/1`. | `et-proto/src/lib.rs` | New requests start at 24. |
| A network member is `State::Member { name, kind }`. It has no roles. | `et-proto/src/network.rs` | The "archive machine" role needs a place (D6). |
| The checkpoint files already record each Claude session's `--resume <id>`. | `~/.local/state/manymux/checkpoints/` | Not needed, but a cross-check in tests. |

## 3. Decisions

| # | Question | Decision |
|---|---|---|
| D1 | Source of history | **ACCEPTED (owner): agent transcripts only.** Plain shell sessions are not captured. |
| D2 | When to capture | **ACCEPTED (owner): always, all sessions**, streamed continuously. A per-session **Do not record** switch. |
| D3 | Watcher AI | **ACCEPTED (owner): headless Claude Code** (`claude -p`) on the archive machine, on the owner's subscription. |
| D4 | Grouping | **ACCEPTED (owner): AI proposes, owner confirms.** Hard signals first (git repo, cwd, mm group). Confirmed choices are fixed input for the next report. |
| D5 | Agents in v1 | **ACCEPTED (owner): Claude Code only**, behind a `Reader` trait so Codex / Gemini come later. |
| D6 | Where logs live | **ACCEPTED: archive machines the owner chooses** (1 or more). Default: trigkey. Mechanism CHANGED in L1 (2026-10-28): **not** in the network doc. The app's et-link also decodes that doc, so a new field there breaks the installed apps until they are rebuilt, and a signature adds no safety (every machine already has shell access to every other). Instead: `etd logbook archive on` on a machine (`logbook.json`), and `LogInfo` (any member asks any machine: "are you an archive?"). No coordinated deploy; an old etd simply does not answer. |
| D7 | Sharing | **ACCEPTED (owner): app "Send to session"** only. No agent pull (MCP) and no watcher push in v1. |
| D8 | Report cadence | **ACCEPTED (owner): on demand** (a Refresh button). Capture stays continuous, so the session view is live. |
| D9 | What is kept | **ACCEPTED:** the **full** JSONL lines (tool calls and tool output included) on the archive. Views filter; the watcher gets a digest. |
| D10 | Retention | **ACCEPTED:** keep forever, show disk use in `etd logbook status`. Revisit at 5 GB. |

## 4. Design

### 4.1 Data flow

```
each machine's etd                                   archive machine's etd (trigkey)
1. every 2 s: own mm node Ls → session pids
2. ~/.claude/sessions/<pid>.json (live pids) → walk up parents to a
   session pid from step 1; none = orphan, skip (L0)
3. re-read each pid file → sessionId (changes on /clear), cwd, status
4. tail ~/.claude/projects/<slug>/<id>.jsonl from offset
5. ── et/1 LogAppend { key, offset, bytes } ────────▶ append to logbook/<machine>/<id>.jsonl
6.                         ◀── LogAck { offset } ── fsync, update index.json
   (on reconnect: LogAck tells where to resume)

app ── LogSessions / LogFollow / Report / LogSend ──▶ archive etd
```

- **Key** = `(machine, claude sessionId)`. Metadata per key: manymux session name, cwd, git repo root + remote URL + branch (read once per new key), first/last time, `status`, previous key in the same manymux session (for `/clear` chains).
- Only Claude processes that are **inside a manymux session** are captured. The watcher's own `claude -p` runs outside manymux, so it never logs itself.
- **Do not record** (D2): a set of `(machine, mm session)` on the archive; the source etd asks for it at connect and skips those sessions. A paused session's bytes never leave its machine.
- Stream size: Claude JSONL grows ~1–5 MB per long session. Batches of max 256 KB; zstd on the wire is not needed in v1.

### 4.2 Protocol (et/1, appended)

```
Request::LogInfo                                          // 24 DONE (L1), any member → any machine
Request::LogAppend   { session_id, meta: LogMeta, offset: u64, bytes: Vec<u8> } // 25 DONE (L1), machine → archive
Request::LogSessions { since: u64 }                       // 26, list keys + meta + status
Request::LogRead     { key: LogKey, from: u64 }           // 27, bytes from offset; then follows (live)
Request::LogPause    { machine: String, session: String, paused: bool }  // 28
Request::Report      { refresh: bool }                    // 29, Progress frames, then the report JSON
Request::Grouping    { change: GroupChange }              // 30, owner confirms / fixes
Request::LogSend     { selection: LogSelection, to: String, session: String } // 31
Response::LogInfo { archive, paused }, LogAck { offset } (DONE); LogList(Vec<LogEntry>), LogBytes(Vec<u8>), ReportJson(String)
```

As built in L1 (etd `PROTOCOL.md`, "Logbook"): the archive keys a transcript by the **sender's member name** (a source cannot write as another machine). `offset` is in the source's file. Empty `bytes` = "where are you?" (and a `meta` update). An `offset` above the archive's = skipped bytes, stored as one line `{"type":"etd-gap","skipped":N}`: this is how **Do not record** works (the lines never leave the machine). Readers (Swift `Transcript.parse`) must ignore that line type.

- `LogRead` follows: after the stored bytes it keeps the stream open and sends new bytes as they arrive (near real time, D2).
- `LogSend`: the archive writes the selection as Markdown to `~/etd-downloads/logbook/<time>-<from>.md`, then runs the existing `Share { path, to, session }`. Nothing new on the target machine.
- Members only, as every other request. `LogAppend` from machines only.

### 4.3 etd

- `crates/etd/src/logbook/` new module: `capture.rs` (steps 1–5), `store.rs` (files + `index.json`), `reader.rs` (`trait Reader` + `ClaudeReader`), `watcher.rs`, `send.rs`.
- Store: `$ETD_HOME/../logbook/` → `~/.local/share/etd/logbook/<machine>/<sessionId>.jsonl` + `index.json` + `projects.json` (confirmed groups) + `reports/<time>.json`.
- `etd logbook status` (disk, keys, lag per machine), `etd logbook pause <machine>/<session>`.
- Never hardcode `claude`'s path (mac-mini differs). The watcher command is `ETD_WATCHER_COMMAND` (default `claude -p --output-format json`).

### 4.4 Watcher (on demand, D3 + D8)

Two stages, so a refresh costs only what changed:

1. **Per-session digest.** For each key that grew since the last report: `claude -p` gets the new turns (prompts + Claude text, tool calls as one-line summaries; Rust port of `Transcript.parse` + `render(budget:)`) and its last digest. It returns ≤ 300 words: goal, done, open, blocked. Cached by offset.
2. **Network report.** `claude -p` gets all digests + hard signals (machine, mm session, repo, branch, mm group) + `projects.json` (confirmed, fixed) and returns JSON:

```json
{ "projects": [ { "id": "...", "name": "...", "goal": "...", "status": "active|blocked|done",
    "sessions": [ { "key": "...", "role": "what this session does for the goal" } ],
    "progress": "...", "next": ["..."] } ],
  "unassigned": ["key"],
  "proposals": [ { "kind": "merge|split|move|rename", "detail": "...", "why": "..." } ] }
```

- The prompt says the core rule: **same goal → one project, even across repos; same repo with different goals → two projects.**
- Runs in `~/.local/share/etd/logbook/watcher/` as `claude -p --tools "" --no-session-persistence --strict-mcp-config --output-format json`, prompt on stdin (L0: no tools, no transcript of its own, ~2 min for 50 digests). Not `--bare` (no login there).
- One report at a time; a second Refresh joins the running one.

### 4.5 et-link (Rust, shared by both apps)

The app finds the archive machine in `NetworkInfo.archive` and connects to it directly, as for any machine. (et-link fills `archive` by sending `LogInfo` to each machine, in parallel with a short time limit; the Swift contract does not change with the D6 mechanism change.) This is the contract between A and B. The Mac agent writes a Swift stub with these exact names first (as `SendFilesStub.swift` in PLAN-files), and A makes the real one match.

```rust
// NetworkInfo gains:
pub archive: Vec<String>,                 // machine names, first = the one to use

#[derive(uniffi::Record)] pub struct LogKey { pub machine: String, pub session_id: String }
#[derive(uniffi::Record)] pub struct LogEntry {
    pub key: LogKey,
    pub mm_session: String,               // manymux session name on that machine
    pub cwd: String,
    pub repo: Option<String>,             // git remote URL, else repo root path
    pub branch: Option<String>,
    pub status: String,                   // "busy" | "idle" | "gone"
    pub first: u64, pub last: u64,        // unix seconds
    pub bytes: u64,
    pub previous: Option<String>,         // session_id before /clear or --resume
    pub paused: bool,                     // Do not record
}
#[derive(uniffi::Record)] pub struct LogChunk { pub offset: u64, pub lines: Vec<String> } // whole JSONL lines only
#[derive(uniffi::Enum)] pub enum LogSelection {
    Turns { key: LogKey, turn_ids: Vec<String> },          // Claude entry uuids of the prompts
    ReportSection { report_id: String, project_id: String },
}
#[uniffi::export(with_foreign)] pub trait ReportProgress: Send + Sync {
    fn on_progress(&self, stage: String, done: u32, total: u32);
}

// RemoteHost (on the archive machine):
async fn logbook_sessions(&self, since: u64) -> Result<Vec<LogEntry>, LinkError>;
async fn logbook_follow(&self, key: LogKey, from: u64) -> Result<Arc<LogStream>, LinkError>;
    // LogStream::next() -> Result<LogChunk, LinkError>: stored bytes first, then live
async fn logbook_pause(&self, machine: String, mm_session: String, paused: bool) -> Result<(), LinkError>;
async fn report(&self, refresh: bool, progress: Arc<dyn ReportProgress>) -> Result<String, LinkError>; // §4.4 JSON + "id", "taken"
async fn grouping(&self, change_json: String) -> Result<(), LinkError>; // one §4.4 proposal, accepted or edited
async fn logbook_send(&self, selection: LogSelection, to: String, session: String,
                      progress: Arc<dyn SendProgress>) -> Result<Delivered, LinkError>;
```

Parsing the JSONL lines into turns stays in Swift (`ETCore/Transcript.swift`), extended to keep tool calls (name + one-line input, full output on tap).

### 4.6 Apps

**Mac (ET-mac)** — sidebar section **Logbook**, under Files:

```
Logbook                      ┌──────────────────────────────────────────┐
  ▸ etd logbook  ●2          │ trigkey/claude · ~/etd · main · busy      │
      trigkey/claude  busy   │ ▸ You: add LogAppend to et-proto          │
      mac-mini/claude2 idle  │   Claude: done, tests pass …              │
  ▸ nixos-config  ●1         │   ▸ 3 tool calls                          │
  ⚠ 2 suggestions            │ [Send to session…]  [Do not record]       │
  Report (12 min ago) ↻      └──────────────────────────────────────────┘
```

- Session view = live transcript (reuse Copilot's turn rows; tool calls folded, tap to open the full output).
- Report view = projects as cards: goal, sessions with their role, progress, next. **Refresh** with progress.
- Suggestions: Accept / Reject / Edit (rename, move a session).

**iOS / iPad** — `…` menu → **Logbook** (same place as Files): project list → session transcript; report screen; Send to session. Same et-link calls.

## 5. Work

Times are for the agent that runs the step. ✅ = owner can see it work.

### Phase L0 — checks (A, ~1 h)

1. Confirm `MmSession.pid` is the session's root process, and that the Claude pid is its descendant on Linux and macOS (`etd-ssh mac-mini`).
2. Measure transcript growth: bytes/day over the existing `~/.claude/projects` on the 3 machines.
3. Run `claude -p` with a 50-digest prompt on trigkey: time, and whether `--allowedTools ""` blocks all tools.

**L0 results (2026-10-28, A):**

| Check | Result | Effect on the design |
|---|---|---|
| Process tree, trigkey + gmktec | `claude` is the **direct child** of the `mm` node (the session leader, started by `ws`). | Simple case works. |
| Process tree, mac-mini | Live session: `claude` ← `sh -mc …` ← `mm` node (one wrapper level). Also **2 orphan `claude` processes** with PPID 1, no tty, from sessions that ended on 2026-10-23. Their pid files still say `status: busy`. One orphan has `MM_SESSION=claude2`, the same as the live session. | Map by **walking up the parents until a live manymux session leader** (from the node's `List`). Do **not** use `MM_SESSION`: orphans keep it. A Claude process with no live session above it is skipped. |
| Session id | The pid file's `sessionId` **changes** while the process runs (after `/clear`), and `--resume <id>` starts with a **new** id. Example mac-mini pid 4435: started `--resume 14bbbb56…`, now `fcca3b1b…` (new file, 2026-10-28). | Read the pid file again at each poll. A new id under the same (machine, mm session) = a new key with `previous` = the old id. |
| Transcript size | Largest seen: **12.2 MB** (one mac-mini session). Total: trigkey 114 MB / 36 files, mac-mini 183 MB / 35, gmktec 10 MB / 14. Written in the last 7 days: 44 + 66 + 0.6 MB ≈ **16 MB/day** for the network. | Archive reaches the D10 mark (5 GB) in about 10 months. First sync of old transcripts: do **not** back-fill; start at the files that are live when L1 is deployed. |
| `claude -p --tools ""` | Blocks every tool: it could not read a file or run `hostname`, and said so. | Use it for the watcher. |
| `claude -p --bare` | Fails: `Not logged in` (bare mode does not use the subscription login). | Do not use `--bare`. |
| 50-digest report (7.7k words in) | **104 s**, 25.7k tokens in, 11.5k tokens out, 1 turn, valid JSON with no code fence. 19 projects, 2 unassigned, 5 sensible proposals (split / merge / close). API-equal cost $0.42 (on the subscription: counts against its limits). | Watcher command: `claude -p --tools "" --no-session-persistence --strict-mcp-config --output-format json`, prompt on stdin. Time goes mostly to output: keep fields short. Progress UI must allow ~2 min. |
| Owner's `~/.claude/CLAUDE.md` | Loads into `claude -p` (the no-tools answer ended with "Next: …" in the owner's style). The JSON report was still clean. | Keep it (the report then uses the owner's writing style). Validate the JSON; on a parse error, retry once with "JSON only". |

### Phase L1 — capture + archive (A, ~1 day) — DONE + DEPLOYED 2026-10-28 (etd v0.0.8, trigkey + gmktec)

etd v0.0.7 (fa5d74a) + v0.0.8 fix (692d667: list sessions on the node socket, one connection per list): `crates/etd/src/logbook/` (capture.rs, claude.rs, store.rs, mod.rs), `LogInfo` (24) + `LogAppend` (25), `etd logbook`, `etd logbook archive on|off`. Tests: unit tests + `tests/logbook.rs` (real `sh` leader + `sleep` agent: orphan skipped, half lines wait, restart sends nothing twice, pause leaves a gap, end = `gone`). Live check on trigkey with a throwaway `ETD_HOME`: this session's transcript (2.6 MB) archived in < 1 s, byte-identical, mode 0600. Archive store: `~/.local/share/etd/logbook/<machine>/<session id>.jsonl` + `index.json`. Not done: back-fill of the transcript before a `--resume` (only live transcripts are sent).

1. ~~Network settings record with `archive` (D6) + `etd archive <machine>` command.~~ Built as `etd logbook archive on` + `LogInfo` (D6 change).
2. `logbook/capture.rs` + `ClaudeReader`, unit tests with fixture JSONL and a fake process tree.
3. `LogAppend` / `LogAck` + `store.rs`; resume after a dropped connection (test: cut mid-batch).
4. `etd logbook status`. Deploy trigkey + gmktec (nixos-config); mac-mini needs darwin-rebuild (B). ✅ `etd logbook status` on trigkey shows sessions from all 3 machines.

### Phase L2 — read API + Mac live view (A ~½ day, B ~1 day)

1. A: `LogSessions`, `LogRead` with follow, `LogPause`; et-link API + Swift check.
2. B: Mac sidebar Logbook (sessions grouped by repo for now) + live transcript view. ✅ Type in a Claude session on gmktec, see it on the Mac in < 5 s.

### Phase L3 — watcher + report (A ~1 day, B ~½ day)

1. A: digests (stage 1), report (stage 2), `Report` request with Progress, `projects.json`, `Grouping`.
2. B: report view, Refresh, suggestions with Accept / Reject / Edit on Mac. ✅ Two sessions on one goal in two repos show as one project.

### Phase L4 — Send to session (A ~2 h, B ~½ day)

1. A: `LogSend` (Markdown file + existing `Share`).
2. B: select turns / report section → Send to session… on Mac. ✅ The path shows in the target Claude prompt.

### Phase L5 — iOS / iPad (B, ~1 day)

1. Logbook screen, transcript, report, Send to session. TestFlight. ✅

## 6. Tests (owner, C)

1. Start 2 Claude sessions on one goal on two machines, and 1 on a different goal in the same repo as one of them. Refresh: expect 2 projects, correct split.
2. `/clear` in a session: the Logbook keeps one session with two parts.
3. Turn on **Do not record** for one session: nothing new appears on trigkey (`etd logbook status`).
4. Stop etd on gmktec for 5 min while Claude works there, start it again: no gap in the transcript.
5. Send a report section into a session on mac-mini: the path is typed, the file opens.

## 7. Risks

| Risk | Effect | Mitigation |
|---|---|---|
| Transcripts contain secrets (tool output of `sops -d`, tokens, `.env`) and are now copied to the archive | A second place to leak from | Archive files mode 0600; members only (same trust as shell access, SECURITY.md); **Do not record**; doc the risk in SECURITY.md. No redaction in v1 (owner wants full output). |
| `claude -p` reports use subscription limits | Refresh can fail or slow down other sessions | Stage-1 cache; show the last report and the error; on demand only (D8). |
| Claude Code changes its JSONL or `sessions/*.json` format | Capture stops or parses badly | Store raw bytes (parsing is only for views); reader logs the Claude `version`; a fixture test per seen version. |
| Large transcripts (12 MB seen) on a phone | Slow view, high data use | `LogRead` with a `from` offset; iOS loads the last 200 turns first. |
| Network doc change (D6) needs all machines updated together | A machine on old etd cannot read the doc | Deploy trigkey + gmktec + mac-mini in one go; m1-air / others re-install. |
