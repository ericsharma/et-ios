# Plan: Multi-agent — E.T. for every terminal AI agent, not only Claude Code

Status: 2026-10-29. D1–D9 ACCEPTED (owner). M0 started (A: trigkey, B: mac-mini installs done). Nothing built.

Follows [PLAN-agents.md](PLAN-agents.md) (AG1 built: the **Agents page** with each machine's Claude login, usage limits and running Claude agents; AG2: the same data from etd, a proposal) and [PLAN-logbook.md](PLAN-logbook.md) (D5: "Claude Code only, behind a `Reader` trait so Codex / Gemini come later"). Work split as in that plan: **A** = the trigkey Claude session (etd, et-proto, et-link), **B** = the Mac agent (apps, builds), **C** = the owner (tests).

## 1. Goal

E.T. works for "any tmux user" (SPEC §1). It must also work for any **agent** user. A person who runs Gemini CLI on one machine, Codex on another and Claude Code on a third gets the same E.T.:

| Where | What the user does | Result |
|---|---|---|
| **+** (new session) | Picks a machine, then an agent from the list of agents **installed on that machine** | The agent starts in a manymux session and opens, with its own key set |
| Machines list | Looks at the list | Each agent session has the agent's mark and a live state: busy, idle, **needs you**, finished (not read) |
| Push | Leaves the app | "Gemini on gmktec needs you: allow `rm -rf build`?" is a different push from "Codex on trigkey finished" |
| Select mode, Copilot, Speaker | Same gestures as in a Claude session today | The agent's own transcript and last reply, for every supported agent |
| Logbook | Opens a project | Sessions of all agents in one project; one report across all agents |
| **Agents page** (AG1, exists) | Looks at what works | A new **What works** section: per machine and per agent, installed, transcript, live state, alerts. A missing part shows how to turn it on. Running agents of every vendor, not only Claude |

### 1.1 Principles (the app's ethos, applied to agents)

1. **The terminal stays the agent's UI.** E.T. does not rebuild each agent's chat. It adds native help around the terminal, as control mode does for tmux (SPEC §2).
2. **One agent = one profile.** Code never compares a command with `"claude"`. Every Claude-only place today reads the session's profile.
3. **Show what works, honestly.** An agent that has no live state shows no state. It does not guess and it does not show a wrong "idle".
4. **Never change a user's config silently** (as "never create a session silently", SPEC §2.1). E.T. shows the exact hook lines with Copy, or a "Set up" button that shows the change before it writes.
5. **Same gestures for every agent.** Two-finger swipe, key wheel, mic, select mode, Send to session: no agent-specific gestures.
6. **No vendor logos.** A one-letter mark on a Catppuccin accent color. It keeps the app's look and avoids trademark use.
7. **The owner's setup is the first real user, not the design.** Built-in profiles cover the common agents. A user can add an agent with a file, with no app release.

## 2. Facts that decide the design

### 2.1 Checked in the code (2026-10-29)

| Fact | Where | Effect |
|---|---|---|
| The Agents page (AG1) runs a shell script with `jq` + `curl` on each machine; Claude only; it also shows `waiting` as idle | `App/AgentsUI/Agents.swift:288`, PLAN-agents §3 | Extend this page, do not add a second one. AG2 (etd does it) and this plan's `Request::Agents` are **one** request |
| Claude detection is a string test on command, name and title | et-ios `SessionController.swift:1143` (`preset(for:)` → `.claude`) | One function to replace with "which profile matches" |
| Claude-only behavior hangs on that preset: key set, bracketed paste for multi-line text, `@path` dictation, select mode transcript, Overview sparkle | `KeyRow.swift`, `SessionController.swift:1506`, `VocabMatcher.swift:78`, `SelectMode.swift:170`, `Overview.swift:96` | Each reads a profile field instead |
| Speaker finds Claude's reply by its `⏺` marker on screen | `Speaker.swift` (`ClaudeReply`) | Reply marker is a profile field; with a transcript, use the transcript |
| Select mode and Copilot **guess** the transcript with a shell script over `~/.claude/projects` | `ETCore/Transcript.swift:57` | Replace with the Logbook's exact transcript (etd knows it), for every agent |
| **+** offers Shell / Claude / Command | `MachinesView.swift:151` | Becomes Shell / installed agents / Command |
| AI prompts say "Claude Code" | `Copilot.swift:8`, `KeyRow.swift:531` | Agent name goes into the prompt |
| Logbook wire format is already agent-aware: `LogMeta.agent` | et-proto `logbook.rs:15` | **No protocol break** for the Logbook list |
| etd has `trait Reader { agent(), live(), resumed() }`, one impl: `Claude` | etd `logbook/claude.rs:29` | Add one `Reader` per agent |
| `Reader::live()` finds Claude from `~/.claude/sessions/<pid>.json` (pid, session id, cwd, status) | `claude.rs` | Other agents have no pid file (check in M0): they need another way to find "this process writes this file" |
| Capture tails append-only JSONL by byte offset | `logbook/capture.rs`, PLAN-logbook §4.1 | An agent that rewrites one JSON file needs a converter on the source machine (D4) |
| Watcher command is set by `ETD_WATCHER_COMMAND`, default `claude -p` | PLAN-logbook §4.3 | A different agent can write the report (D7) |
| Claude's `waiting` (a question to the owner) becomes `idle` | etd `claude.rs:164` | Keep `waiting` as **needs you** (D5) |
| Postcard has no field names: a new field in an existing struct breaks installed apps | PLAN-logbook D6 (the `NetworkInfo` lesson) | New data only in **new** `Request` / `Response` variants, appended (next: 33) |

### 2.2 From the web, NOT checked (M0 checks each on a real install)

| Agent | Transcript | Live state / hooks | Headless | Source |
|---|---|---|---|---|
| Codex CLI (OpenAI) | `~/.codex/sessions/YYYY/MM/DD/rollout-<time>-<uuid>.jsonl`, append-only JSONL, first line `session_meta` with `cwd` | Hooks (SessionStart, UserPromptSubmit, PreToolUse, PostToolUse, Stop) behind `codex_hooks = true`; older `notify` key | `codex exec` | third-party blogs |
| Gemini CLI (Google) | `~/.gemini/tmp/<project hash>/chats/`; JSONL in new versions, one `session-*.json` in old ones; deleted after 30 days by default | Hooks incl. `Notification` (matcher may be `ToolPermission`); `GEMINI_SESSION_ID` in hook env | `gemini -p` | geminicli.com docs |
| Grok Build (xAI) | Unknown | Unknown | `grok -p`; ACP with `grok agent stdio` | third-party guides |
| All three + Claude | — | Agent Client Protocol (ACP): Gemini native, Claude and Codex through Zed adapters, Grok native | — | agentclientprotocol.com |

## 3. Decisions

| # | Question | Proposal |
|---|---|---|
| D1 | Agents in v1 | **ACCEPTED (owner):** built-in profiles for Claude Code, Codex, Gemini CLI, Grok Build. Any other command works as today ("Command"), and a user profile file can add more (M5). |
| D2 | Where agent knowledge lives | **ACCEPTED (owner): in Rust** (et-link), one `AgentProfile` table shared by etd and both apps. The apps get data, not code. A machine can add or override profiles in `~/.config/etd/agents.toml`. |
| D3 | Who parses transcripts | **ACCEPTED (owner): Rust, one parser per agent** in et-link, to one `Turn` shape (prompt, reply text, tool calls). etd's watcher digests, the Mac app and iOS use the same parser. `ETCore/Transcript.swift` then only renders. The archive keeps raw bytes (PLAN-logbook D9). |
| D4 | Agents that rewrite a JSON file (old Gemini) | **ACCEPTED (owner):** the source `Reader` turns each new message into one synthetic JSONL line, so the archive stays append-only. If M0 shows current Gemini writes JSONL, drop this. |
| D5 | Live state | **ACCEPTED (owner): four states**: `busy`, `idle`, `needs-you`, `gone`. Source per agent, best first: (1) the agent's own state file (Claude), (2) hooks that call `etd hook <agent> <event>` (exact, also gives the question text), (3) the transcript's last event. No screen scraping. No state = no state shown (§1.1 rule 3). |
| D6 | Hook set-up | **ACCEPTED (owner):** `etd agents setup <agent>` prints the lines to add; the app's Agents screen shows them with Copy. An explicit "Set up" button shows the change, then writes it with a backup. Never automatic. |
| D7 | Who writes the Logbook report | **ACCEPTED (owner):** a setting on the archive, shown in the app ("Report written by"). Default: the first installed of Claude, Codex, Gemini, Grok. Each profile has its headless command. |
| D8 | Look | **ACCEPTED (owner):** one-letter mark on a Catppuccin Mocha accent: Claude **C** peach, Codex **X** green, Gemini **G** blue, Grok **K** mauve, user profiles **letter** on overlay. No vendor logos. |
| D9 | ACP (a protocol for driving an agent without its TUI) | **ACCEPTED (owner): not in v1.** It would replace the terminal with a native chat (against rule 1). Later, maybe as an optional "Chat" view for one session. |

## 4. Design

### 4.1 The profile (et-link, `agents.rs`)

```rust
#[derive(uniffi::Record)] pub struct AgentProfile {
    pub id: String,                 // "gemini"
    pub name: String,               // "Gemini CLI"
    pub mark: String,               // "G"
    pub accent: String,             // Catppuccin name: "blue"
    pub launch: Vec<String>,        // ["gemini"]
    pub processes: Vec<String>,     // exe names that mean "this agent runs": ["gemini", "node …gemini"]
    pub version_args: Vec<String>,  // ["--version"]
    pub keys: Vec<String>,          // key wheel set: ["esc", "⇧tab", "1", "2", "3", "↑", "↓", "enter", "^C"]
    pub multiline: String,          // "bracketed-paste" | "line-by-line"
    pub mention: Option<String>,    // "@": dictation "at <file>" → "@path"
    pub reply_marker: Option<String>, // screen fallback for Speaker: "⏺"
    pub headless: Vec<String>,      // ["gemini", "-p"]: watcher, digests
}
#[derive(uniffi::Record)] pub struct AgentOnMachine {
    pub id: String,
    pub version: Option<String>,    // None = not installed
    pub transcript: bool,           // a Reader exists and found its files
    pub state: String,              // "own" | "hooks" | "transcript" | "none"
    pub alerts: bool,               // needs-you reaches etd (state "own" or "hooks")
    pub setup_hint: Option<String>, // what to do for a missing part
}
pub fn agent_profiles() -> Vec<AgentProfile>;                        // built-ins
async fn agents(&self) -> Result<Vec<AgentOnMachine>, LinkError>;   // RemoteHost: Request::Agents (33)
fn parse_turns(agent: String, lines: Vec<String>) -> Vec<Turn>;     // D3
```

- `Request::Agents` (33) is **AG2, made multi-vendor**: one answer per machine with the installed agents (`Vec<AgentOnMachine>`), the running agents of every vendor, the machine's extra profiles from `agents.toml`, and AG1's Claude login + usage (other vendors' logins and limits: later, only where the vendor has an API). `Agents.refresh` moves from the script to it; the views stay. An old etd does not answer: the app then shows built-ins with "update etd for details", the same as the Logbook archive check.
- Session → profile: etd already knows each agent process under each manymux session (Logbook capture). Add `Request::SessionAgents` (34) → `[(mm session, agent id, state, question)]`. Fallback for an old etd: match `MmSession.command` against `processes`.

### 4.2 Screens

**New session (+)** — only what is installed on the chosen machine; versions show it is real:

```
New session on gmktec
  ○ Shell
  AGENTS
  ● (C) Claude Code     2.1.4
  ○ (G) Gemini CLI      0.12.0
  ○ (X) Codex           0.50.1
    Grok Build is not on gmktec
  ○ Command…
  Name (optional) [            ]
                         [Start]
```

**Machines row** — the mark replaces nothing; it goes before the title. State words, not only colors:

```
(G) fix login redirect                    gemini · 2 m · NEEDS YOU
(X) migrate store to sqlite               codex · busy ···
(C) PLAN-agents review                    claude · idle · ● new reply
    bash                                  shell · 14 m
```

- **needs you** = red, same red as the bell. **new reply** = blue dot (finished, not opened since). Both clear when the session is shown for 1 s.
- Sort option "Needs you first" (off by default).

**Agents page (AG1), new section "What works"** — answers "what works where". The running-agents list above it shows every vendor, each with its mark:

```
Agents                 trigkey     gmktec     mac-mini
(C) Claude Code        ✓ ✓ ✓       ✓ ✓ ✓      ✓ ✓ ✓
(X) Codex              ✓ ✓ ·       —          ✓ ✓ ·
(G) Gemini CLI         ✓ ✓ ·       ✓ ✓ ·      —
(K) Grok Build         —           —          ✓ · ·
                       installed · transcript · alerts
Tap a "·": what is missing and how to turn it on (Copy).
```

**Session page** — the header shows the mark next to the title. Key wheel set, bracketed paste and `@path` dictation follow the profile. Long-press ⋯ still changes the key set (remembered per session name, as today).

**Logbook** — filter chips at the top (All · Claude · Codex · Gemini · Grok, only agents that have sessions). Each session shows its mark. Report cards mix agents: "Codex on trigkey migrates the store; Claude on mac-mini updates the app."

**Logbook settings** — "Report written by: (C) Claude Code ▾" (D7), with the agents installed on the archive.

**Push** — title says the agent, machine and what it wants:
- needs you: "Gemini on gmktec needs you" / body: the question or the tool to allow.
- finished: "Codex on trigkey finished" / body: first line of the last reply.
- This also does SPEC §9 "separate needs input vs finished notifications".

### 4.3 etd

- `logbook/<agent>.rs`: one `Reader` per agent (`codex.rs`, `gemini.rs`, `grok.rs`), each a copy of the `claude.rs` shape.
- Find "process → transcript" for agents with no pid file, best first: (1) the file the process has open (`/proc/<pid>/fd` on Linux, `lsof -p` on macOS), (2) the newest transcript with the same `cwd`, written after the process started. M0 shows which works per agent.
- `etd hook <agent> <event>`: reads the hook's JSON on stdin and sends it to the local etd socket. etd keeps the last state per session, sends **needs you** / **finished** to `et-notify`, and answers `SessionAgents`.
- `etd agents` (CLI): the same table as the app's Agents screen. `etd agents setup <agent>`: the hook lines (D6).

## 5. Work

Times are for the agent that runs the step. ✅ = owner can see it work.

### Phase M0 — checks (A, ~2 h)

1. Install Codex, Gemini CLI and Grok Build on trigkey (nix or npm, user profile only) and on mac-mini (B). Log in to each (owner, C, ~10 min).
2. For each agent, run one short session in manymux and record: process name and tree, transcript path and format (JSONL or JSON, append-only or not), whether the process keeps the file open, how `/clear` and resume change the file, the terminal title it sets, the hook events and the exact JSON they get, the headless command, and the keys its TUI needs.
3. Replace §2.2 with a checked table. Change D4 and D5 if the facts say so.

**M0 results, part 1 (2026-10-29, A, trigkey, no login yet):**

| Check | Result | Effect on the design |
|---|---|---|
| Install | npm: Codex `@openai/codex` **0.166.0**, Gemini `@google/gemini-cli` **0.66.0**. Grok Build is not on npm; nixpkgs `grok-build` **0.2.11** (homepage x.ai/cli, binaries `grok` and `agent`). nixpkgs is far behind for the others (codex 0.92.0, gemini-cli 0.25.2). M0 install: `~/.local/share/agents-m0` (not in nixos-config). | Check facts on the npm versions. Version detection must handle npm, nix and other installs. |
| Codex storage | 0.166 has `codex migrate-rollouts` ("legacy local sessions to paginated thread history"), features `sqlite` (removed, on), `local_thread_store_compression` (in development), `background_paginated_rollout_migration` (in development). | The web facts (one append-only `rollout-*.jsonl` per session) may be **old**. D4 may need a Codex converter. Check after login. |
| Codex hooks | `codex features list`: `hooks` **stable, on**. | D5 source (2) works for Codex. |
| Codex sessions | `codex agents` (sessions on a "shared local app-server daemon"), `resume`, `fork`, `queue` (a message for an existing session), `archive`. | The app-server may give status and transcript without file reads: check it as a Codex `Reader` source. |
| Gemini headless | `-p`, `-o json|stream-json`, `--acp`, `--resume latest|<n>`, `--session-id <uuid>`, `--list-sessions`, `--approval-mode`. | `headless` = `gemini -p … -o json`. `--session-id` lets etd know the id when E.T. starts the session. |
| Grok headless | `grok -p` / `grok agent`, `--output-format`, `-r <session id>`, `-c` (continue for cwd), `sessions list|search`, `export` (Markdown), `import`. | `headless` = `grok -p`. `grok export` is a fallback transcript source. |
| Grok reads Claude's files | `grok inspect`: loads `~/.claude/CLAUDE.md`, permissions from `~/.claude/settings.local.json`, and all 26 Claude skills. Its flags name the Claude Code equivalents (`--allow` = `--allowedTools`). | Grok may accept Claude-format hooks: check. A Grok profile can reuse much of Claude's. |
| Logins (headless) | `codex login --device-auth`, `grok login --device-auth`, Gemini: login screen on first `gemini` run (or `GEMINI_API_KEY`). | Owner (C) logs in once per machine. The Agents page can show "not logged in" with the command. |

**M0 results, mac-mini (2026-10-29, B, no login yet):**

| Check | Result | Effect on the design |
|---|---|---|
| Install | All in `~/.local/share/agents-m0` (user profile, no nix-darwin change). Node 22.23.3 from nixpkgs (`node` link; the mini had no Node). npm: Codex **0.166.0**, Gemini **0.66.0**. Grok: nixpkgs here has `grok-build` **1.0.50**, not 0.2.11. trigkey's 0.2.11 is xAI's binary from `storage.googleapis.com/grok-build-public-artifacts/cli/grok-0.2.11-linux-x86_64`. On the mini: the same bucket's `grok-0.2.11-macos-aarch64`, built with `grok-build.nix` (`grok-result` link). `grok --version` = `grok 0.2.11 (3247ce8f833)`. | The npm installs need Node on PATH: a manymux command needs `env PATH=…` or a wrapper (as for `claude`, 2026-10-23). |
| Grok updates itself | The first run downloads **1.0.70** to `~/.grok/downloads/grok-1.0.70-macos-aarch64` and links `~/.grok/bin/grok` to it (`~/.grok/version.json`). The nix 0.2.11 stays in place. | A pinned Grok does not stay pinned. Version detection must ask the binary that runs, and `processes` must match `~/.grok/bin/grok` too. |
| Process tree, Codex (`mm new -d -n m0-codex env PATH=… codex`) | `63742 1 mm daemon --no-notify` → `74610 63742 …/@openai/codex-darwin-arm64/vendor/aarch64-apple-darwin/bin/codex`. No Node process stays: the native binary is the session leader's process. | `processes` = exe name `codex`. |
| Process tree, Gemini | `74625 63742 node …/agents-m0/bin/gemini` → `74645 74625 node --max-old-space-size=8192 …/agents-m0/bin/gemini` (it starts itself again with a bigger heap). | `processes` must match `node … gemini`, at two levels. The child is the one that works. |
| Process tree, Grok | `74640 63742 grok` (argv0 only, no path). | `processes` = exe name `grok`; the path is not in the command line. |
| Files, Codex | `~/.codex`: `config.toml`, `version.json`, `installation_id`, SQLite stores `state_5`, `logs_2`, `memories_1`, `queue_1`, `goals_1` (WAL), `skills/.system`, `tmp/`. No `sessions/` before login. | Supports part 1: Codex keeps state in SQLite. Check the transcript after login. |
| Files, Gemini | `~/.gemini`: `state.json` (+ `.bak`), `projects.json`, `installation_id`, `history/tmp`, `tmp/`. `--version` alone wrote two `projects.json.*.tmp` files. | No chats before login. |
| Files, Grok | `~/.grok`: `config.toml`, `version.json`, `agent_id`, `README.md`, `docs/`, `skills/`, `completions/`, `logs/`, `sessions/session_search.sqlite`, `bin/`, `downloads/`. | Sessions are in SQLite (search index); check the transcript after login. |

### Phase M1 — profiles, + and the session look (A ~½ day, B ~1 day)

1. A: `AgentProfile` table + `agent_profiles()`, `Request::Agents` (33) = AG2 + installed agents with versions, `etd agents`. **Installed agents DONE 2026-10-29** (etd f98347b, not released or deployed): `agent_profiles()`, `RemoteHost.agents() -> [AgentOnMachine]` as above; the answer is JSON (`Response::Agents { json }`), so AG2 fields (running agents, Claude login + usage) come later with no protocol break. On trigkey `etd agents` finds Claude 2.1.312, Codex 0.166.0, Gemini 0.66.0, Grok 0.2.11. B: bump `Vendor/etd` to f98347b (or later) and replace the stub.
2. B: replace `preset(for:)` with a profile lookup; key sets, multi-line paste, `@path`, Overview mark, prompts from the profile. **+** sheet with installed agents. Mark on rows and tabs.
3. ✅ From the phone: + → gmktec → Gemini CLI. The session opens with Gemini's key set and its mark in the list.

### Phase M2 — transcripts (A ~1½ days, B ~1 day)

1. A: `parse_turns` per agent in et-link (port `Transcript.parse`), fixture tests per agent version. `Reader` for Codex, Gemini, Grok. Logbook captures them.
2. B: select mode, Copilot and Speaker take the transcript from the Logbook (exact), with the screen as fallback. Delete the guessing script in `Transcript.swift`.
3. ✅ Select mode in a Codex session shows the whole transcript; Logbook shows a live Gemini session.

### Phase M3 — live state and needs-you (A ~1 day, B ~½ day)

1. A: `etd hook`, state per session, `SessionAgents` (34), Claude's `waiting` → needs-you, pushes with agent + machine + question.
2. B: state words and dots on rows, "Needs you first" sort, the Agents page's What works section with set-up hints and Copy.
3. ✅ A Gemini permission prompt on gmktec gives "Gemini on gmktec needs you" on the locked phone; the tap opens that session.

### Phase M4 — Logbook across agents (A ~½ day, B ~½ day)

1. A: digests read `Turn`s for every agent; watcher command from the chosen profile (D7).
2. B: filter chips, marks, "Report written by".
3. ✅ One project card holds a Codex session on trigkey and a Claude session on mac-mini.

### Phase M5 — user profiles + iOS parity (A ~½ day, B ~1 day)

1. A: `~/.config/etd/agents.toml` (add or override a profile); `Request::Agents` sends them.
2. B: iOS / iPad screens for all of the above. TestFlight.
3. ✅ Add `aider` in `agents.toml` on gmktec; it shows in **+** with its mark, no app release.

Total: A ~4½ days, B ~4 days, C ~1 h of tests.

## 6. Tests (owner, C)

1. On one machine, start one session of each installed agent from **+**. Each opens with the right key set and mark.
2. Make Gemini and Codex each ask for a permission while the app is closed. Two different "needs you" pushes arrive; each tap opens the right session.
3. Let a Codex task finish while you look at another session: its row gets the blue dot; showing it clears the dot.
4. Refresh the Logbook report with "Report written by" set to Gemini: the report is made, and it groups a Claude and a Codex session on one goal into one project.
5. Remove the hooks of one agent: its alerts column on the Agents page shows "·" with the set-up hint, and no wrong state shows on its rows.

## 7. Risks

| Risk | Effect | Mitigation |
|---|---|---|
| Agent CLIs change transcript formats often (fast release cycles) | Parse errors, empty views | Raw bytes on the archive (re-parse later); fixture per seen version; parser errors show "Can't read this <agent> version (<version>)", not an empty view |
| An agent keeps no file open and has no pid file | Wrong transcript for a session | Match by `cwd` + start time only when exactly one file fits; else mark the session "transcript: unsure" and do not capture |
| Gemini deletes chats after 30 days | Archive keeps them, the source does not | Fine: the archive is the record. Doc it on the Agents screen |
| Hook set-up writes to user configs | A broken config breaks the agent | Never automatic (D6); backup + show the change; `etd agents setup --undo` |
| Headless report on another vendor's account | Cost or limits on that account | The setting names the agent; show which account the report uses before the first run |
| Transcripts of more vendors on the archive | More secrets in one place | Same as PLAN-logbook §7: mode 0600, members only, Do not record |
| Old apps or old etd in the network | New requests get no answer | Only new variants (33, 34); the app shows "update etd on <machine> for agent details" — and names the machine and its version (lesson from 2026-10-29: the MacBook Air ran etd 0.0.2) |
