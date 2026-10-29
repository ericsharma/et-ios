import ETSSH
import Foundation
import Observation

/// The Claude agents on every machine (PLAN-agents): each machine's Claude
/// login with its usage limits (Claude's /status and /usage), and its
/// running Claude processes. A script on each machine answers. The login
/// token stays on that machine: the script sends it to api.anthropic.com
/// only.
@MainActor @Observable
final class Agents {
    /// A Claude login (`oauthAccount` in ~/.claude.json).
    struct Account: Equatable, Sendable, Decodable {
        var uuid: String
        var email: String?
        var name: String?
        var org: String?
    }

    /// One usage limit: "five_hour", "seven_day", "seven_day_opus", …
    struct Limit: Equatable, Sendable, Identifiable {
        var name: String
        var percent: Double
        var resets: Date?

        var id: String { name }

        var label: String {
            switch name {
            case "five_hour": "5-hour"
            case "seven_day": "Weekly"
            case "seven_day_opus": "Weekly · Opus"
            case "seven_day_sonnet": "Weekly · Sonnet"
            case "seven_day_oauth_apps": "Weekly · apps"
            // Antigravity CLI's quota groups, and Grok's one weekly pool.
            case "grok-weekly": "Weekly"
            case "gemini-5h": "Gemini · 5-hour"
            case "gemini-weekly": "Gemini · Weekly"
            case "3p-5h": "Claude + GPT · 5-hour"
            case "3p-weekly": "Claude + GPT · Weekly"
            default: name.replacingOccurrences(of: "_", with: " ")
            }
        }

        /// For a meter in a row: "5h", "wk".
        var compactLabel: String {
            if name == "five_hour" || name.hasSuffix("-5h") { return "5h" }
            if name == "seven_day" || name.hasSuffix("-weekly") { return "wk" }
            return label
        }

        var isFiveHour: Bool { name == "five_hour" || name.hasSuffix("-5h") }
    }

    /// A login of an agent other than Claude (Antigravity CLI, Grok Build)
    /// and its limits.
    struct AgentLogin: Equatable, Sendable {
        /// The profile id: "antigravity", "grok".
        var agent: String
        var machine: String
        var email: String?
        var plan: String?
        var limits: [Limit] = []
        var error: String?
        var rateLimited = false
        /// When `limits` came from the API.
        var limitsFetched: Date?

        /// One card per login; a login with no email is one per machine.
        var key: String { agent + ":" + (email ?? "?@" + machine) }
    }

    /// A running agent process: Claude Code or Antigravity CLI.
    struct Agent: Identifiable, Equatable, Sendable {
        var machine: String
        /// Its profile id (PLAN-multi-agent).
        var agent = "claude"
        var pid: Int
        var ppid: Int
        var sessionId: String
        var cwd: String
        /// "busy", "idle" (Claude's "shell" and "waiting" are busy and idle);
        /// empty when the agent has no state E.T. can read.
        var status: String
        var version: String?
        var updated: Date?
        /// The manymux session it runs in; empty if none.
        var mmSession: String
        /// The model of its last reply.
        var model: String?
        /// Tokens in the context at the last reply.
        var context: Int

        var id: String { "\(machine)/\(pid)" }
        var profile: AgentProfile? { AgentProfile.profile(id: agent) }
        /// Its manymux session ended; it lives on with no terminal.
        var isOrphan: Bool { ppid == 1 || mmSession.isEmpty }

        /// "Opus 5.5" from "claude-opus-5-5".
        var modelName: String? {
            guard let model else { return nil }
            let parts = model.split(separator: "-")
            guard parts.count >= 3, parts[0] == "claude" else { return model }
            let numbers = parts.dropFirst(2).prefix { $0.count <= 2 && $0.allSatisfy(\.isNumber) }
            guard !numbers.isEmpty else { return model }
            return parts[1].capitalized + " " + numbers.joined(separator: ".")
        }

        /// "181k tokens"
        var contextText: String? {
            guard context > 0 else { return nil }
            return context >= 1000 ? "\(context / 1000)k tokens" : "\(context) tokens"
        }
    }

    /// One machine's answer.
    struct Machine: Identifiable, Equatable, Sendable {
        var name: String
        var account: Account?
        /// "Pro", "Max 20x", …
        var plan: String?
        var limits: [Limit] = []
        var usageError: String?
        /// The usage API said "rate limited".
        var rateLimited = false
        /// When `limits` came from the usage API; older limits are kept
        /// when a later ask fails or is skipped.
        var limitsFetched: Date?
        /// Antigravity CLI and Grok Build logins.
        var logins: [AgentLogin] = []
        var agents: [Agent] = []
        /// The script failed or the machine did not answer.
        var error: String?
        /// No ~/.claude: Claude Code was never used here.
        var noClaude = false
        var fetched: Date?

        var id: String { name }
        var claudeKey: String? { account.map { "claude:" + $0.uuid } }
    }

    /// An account with its limits and the machines logged in with it.
    struct AccountUsage: Identifiable, Equatable, Sendable {
        var account: Account
        var plan: String?
        var limits: [Limit]
        var usageError: String?
        var machines: [String]
        /// When the limits came from the API.
        var fetched: Date?
        /// "claude" or "antigravity".
        var agent = "claude"

        var id: String { account.uuid }
        /// Older than 3 minutes: shown with "as of".
        var isStale: Bool { fetched.map { Date().timeIntervalSince($0) > 180 } ?? false }
    }

    /// By name.
    private(set) var machines: [Machine] = []
    /// The built-in agents on each machine, by machine name (PLAN-multi-agent).
    private(set) var installed: [String: [AgentOnMachine]] = [:]
    private(set) var refreshing = false
    private(set) var refreshed: Date?

    @ObservationIgnored private let hosts: @MainActor () -> [String: IrohHost]
    @ObservationIgnored private let log: @MainActor (String) -> Void
    /// Logins the user hid (old ones), by AccountUsage id. On this device
    /// only, like nicknames. A hidden login's usage is not asked.
    private(set) var hidden: Set<String> = Set(UserDefaults.standard.stringArray(forKey: Agents.hiddenKey) ?? [])
    private static let hiddenKey = "agents.hiddenAccounts"
    /// An account the usage API rate-limited is not asked until then.
    @ObservationIgnored private var backoff: [String: Date] = [:]
    /// The usage API is asked at most this often.
    private static let interval: Duration = .seconds(60)
    private static let rateLimitWait: TimeInterval = 300

    init(hosts: @escaping @MainActor () -> [String: IrohHost], log: @escaping @MainActor (String) -> Void) {
        self.hosts = hosts
        self.log = log
    }

    // MARK: - Lookups

    /// Every live agent that has a terminal.
    var running: [Agent] {
        machines.flatMap(\.agents).filter { !$0.isOrphan }
    }

    /// The logins shown: all but the hidden ones.
    var accounts: [AccountUsage] {
        allAccounts.filter { !hidden.contains($0.id) }
    }

    var hiddenAccounts: [AccountUsage] {
        allAccounts.filter { hidden.contains($0.id) }
    }

    func setHidden(_ usage: AccountUsage, _ hide: Bool) {
        if hide { hidden.insert(usage.id) } else { hidden.remove(usage.id) }
        UserDefaults.standard.set(hidden.sorted(), forKey: Self.hiddenKey)
        log("Agents: \(hide ? "hid" : "showed") \(usage.account.email ?? usage.id)")
        if !hide { refreshed = nil }
    }

    /// Claude logins, then Antigravity CLI and Grok logins, each once with
    /// the machines that use it.
    private var allAccounts: [AccountUsage] {
        var byId: [String: AccountUsage] = [:]
        var order: [String] = []
        func add(_ usage: AccountUsage, machine: String) {
            guard var known = byId[usage.id] else {
                order.append(usage.id)
                byId[usage.id] = usage
                return
            }
            known.machines.append(machine)
            // The newest limits win; a newer error shows with them.
            if !usage.limits.isEmpty, (usage.fetched ?? .distantPast) > (known.fetched ?? .distantPast) {
                known.limits = usage.limits
                known.fetched = usage.fetched
            }
            known.usageError = known.usageError ?? usage.usageError
            known.plan = known.plan ?? usage.plan
            byId[usage.id] = known
        }
        for machine in machines {
            guard let account = machine.account else { continue }
            add(AccountUsage(account: account, plan: machine.plan, limits: machine.limits, usageError: machine.usageError,
                             machines: [machine.name], fetched: machine.limitsFetched), machine: machine.name)
        }
        for agent in ["antigravity", "grok"] {
            for machine in machines {
                guard let login = machine.logins.first(where: { $0.agent == agent }) else { continue }
                add(AccountUsage(account: Account(uuid: login.key, email: login.email, name: nil,
                                                  org: AgentProfile.profile(id: agent)?.name),
                                 plan: login.plan, limits: login.limits, usageError: login.error, machines: [machine.name],
                                 fetched: login.limitsFetched, agent: agent), machine: machine.name)
            }
        }
        return order.compactMap { byId[$0] }
    }

    /// The limits of the login an agent on this machine uses (the
    /// account's newest, also when another machine asked for them).
    func limits(machine name: String, agent: String = "claude") -> [Limit] {
        guard let machine = machine(name) else { return [] }
        let key = agent == "claude" ? machine.account?.uuid : machine.logins.first { $0.agent == agent }?.key
        guard let key else { return [] }
        return accounts.first { $0.id == key }?.limits ?? []
    }

    func machine(_ name: String) -> Machine? {
        machines.first { $0.name == name }
    }

    /// The agent in a manymux session, if one runs there.
    func agent(machine: String, mmSession: String) -> Agent? {
        self.machine(machine)?.agents
            .filter { !$0.isOrphan && $0.mmSession == mmSession }
            .max { ($0.updated ?? .distantPast) < ($1.updated ?? .distantPast) }
    }

    // MARK: - Refresh

    /// Refreshes now, then every minute until the caller's task ends
    /// (a view's `.task`). Several watchers share the refreshes.
    func watch() async {
        while !Task.isCancelled {
            if refreshed.map({ Date().timeIntervalSince($0) > 50 }) ?? true { await refresh() }
            try? await Task.sleep(for: Self.interval)
        }
    }

    /// The agents installed on one machine, asked now; nil when it can't
    /// be asked (not a direct host, or no answer).
    func loadInstalled(on machine: String) async -> [AgentOnMachine]? {
        guard let host = hosts()[machine] else { return nil }
        do {
            let found = try await Self.withTimeout(.seconds(30)) { try await host.agents() }
            installed[machine] = found
            return found
        } catch {
            log("Agents: installed agents on \(machine): \(Self.describe(error))")
            return installed[machine]
        }
    }

    /// Asks every connected machine; each answer shows as it comes.
    func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        defer {
            refreshing = false
            refreshed = Date()
        }
        let hosts = hosts()
        // Machines that left the network go.
        machines.removeAll { hosts[$0.name] == nil }
        installed = installed.filter { hosts[$0.key] != nil }
        let skips = usageSkips(hosts: hosts)
        let installedTask = Task {
            await withTaskGroup(of: Void.self) { group in
                for name in hosts.keys {
                    group.addTask { _ = await self.loadInstalled(on: name) }
                }
            }
        }
        await withTaskGroup(of: (String, Result<String, any Error>).self) { group in
            for (name, host) in hosts {
                let skip = skips[name] ?? ""
                group.addTask {
                    do {
                        let answer = try await Self.withTimeout(.seconds(30)) { try await host.run(skip + Self.script) }
                        return (name, .success(answer.output))
                    } catch {
                        return (name, .failure(error))
                    }
                }
            }
            for await (name, result) in group {
                let old = machine(name)
                var machine = old ?? Machine(name: name)
                switch result {
                case .success(let output):
                    do {
                        machine = try Self.parse(output, machine: name)
                        keepLimits(&machine, from: old)
                    } catch {
                        machine.error = "Unexpected answer: \(error)"
                        log("Agents: \(name): \(error); output \(output.prefix(300))")
                    }
                case .failure(let error):
                    machine.error = Self.describe(error)
                }
                machine.fetched = Date()
                if let i = machines.firstIndex(where: { $0.name == name }) {
                    machines[i] = machine
                } else {
                    machines.append(machine)
                    machines.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                }
            }
        }
        await installedTask.value
    }

    /// Each login's usage is asked from one machine only (the first by
    /// name), and not while the API rate-limits it. Returns the shell
    /// lines that turn the asks off, per machine.
    private func usageSkips(hosts: [String: IrohHost]) -> [String: String] {
        var asker: [String: String] = [:]
        for machine in machines where hosts[machine.name] != nil {
            for key in [machine.claudeKey].compactMap({ $0 }) + machine.logins.map(\.key) where asker[key] == nil {
                asker[key] = machine.name
            }
        }
        func skip(_ key: String?, _ name: String) -> Bool {
            guard let key else { return false }
            let id = key.hasPrefix("claude:") ? String(key.dropFirst(7)) : key
            return hidden.contains(id) || asker[key] != name || (backoff[key] ?? .distantPast) > Date()
        }
        var skips: [String: String] = [:]
        for machine in machines {
            var lines = ""
            if skip(machine.claudeKey, machine.name) { lines += "SKIP_CLAUDE_USAGE=1\n" }
            for login in machine.logins where skip(login.key, machine.name) {
                lines += login.agent == "grok" ? "SKIP_GROK_USAGE=1\n" : "SKIP_AGY_QUOTA=1\n"
            }
            skips[machine.name] = lines
        }
        return skips
    }

    /// A failed or skipped ask keeps the limits from before (shown "as
    /// of"); a rate limit waits 5 minutes before the next ask.
    private func keepLimits(_ machine: inout Machine, from old: Machine?) {
        if machine.rateLimited, let key = machine.claudeKey {
            backoff[key] = Date().addingTimeInterval(Self.rateLimitWait)
            log("Agents: \(machine.name): Claude usage rate-limited; next ask in 5 min")
        }
        for login in machine.logins where login.rateLimited {
            backoff[login.key] = Date().addingTimeInterval(Self.rateLimitWait)
            log("Agents: \(machine.name): \(login.agent) usage rate-limited; next ask in 5 min")
        }
        guard let old else { return }
        if machine.limits.isEmpty, old.account?.uuid == machine.account?.uuid {
            machine.limits = old.limits
            machine.limitsFetched = old.limitsFetched
        }
        for i in machine.logins.indices where machine.logins[i].limits.isEmpty {
            let login = machine.logins[i]
            guard let previous = old.logins.first(where: { $0.agent == login.agent && $0.email == login.email }) else { continue }
            machine.logins[i].limits = previous.limits
            machine.logins[i].limitsFetched = previous.limitsFetched
        }
    }

    // MARK: - The script's answer

    private struct Answer: Decodable {
        var error: String?
        var noClaude: Bool?
        var account: Account?
        var plan: Plan?
        var usage: Usage?
        var agents: [RawAgent]?
        var agy: Login?
        var grok: Login?

        struct Login: Decodable {
            var email: String?
            var plan: String?
            var quota: Usage?
        }

        struct Plan: Decodable {
            var plan: String?
            var tier: String?
        }

        struct Usage: Decodable {
            var limits: [RawLimit]?
            var error: String?
            var rateLimited: Bool?
        }

        struct RawLimit: Decodable {
            var name: String
            var percent: Double
            var resets: String?
        }

        struct RawAgent: Decodable {
            var agent: String?
            var pid: Int
            var ppid: Int?
            var sessionId: String?
            var cwd: String?
            var status: String?
            var version: String?
            var updatedAt: Double?
            var mmSession: String?
            var model: String?
            var context: Int?
        }
    }

    nonisolated static func parse(_ output: String, machine name: String) throws -> Machine {
        // The JSON is the last line (a login shell may print before it).
        let line = output.split(whereSeparator: \.isNewline).last { $0.hasPrefix("{") } ?? Substring(output)
        let answer = try JSONDecoder().decode(Answer.self, from: Data(line.utf8))
        var machine = Machine(name: name)
        machine.noClaude = answer.noClaude ?? false
        if let error = answer.error {
            machine.error = error
            return machine
        }
        machine.account = answer.account
        machine.plan = planName(answer.plan?.plan, tier: answer.plan?.tier)
        machine.limits = (answer.usage?.limits ?? []).map {
            Limit(name: $0.name, percent: $0.percent, resets: $0.resets.flatMap(date))
        }
        if !machine.limits.isEmpty { machine.limitsFetched = Date() }
        machine.usageError = answer.usage?.error
        machine.rateLimited = answer.usage?.rateLimited ?? false
        for (agent, raw) in [("antigravity", answer.agy), ("grok", answer.grok)] {
            guard let raw else { continue }
            let limits = (raw.quota?.limits ?? []).map {
                Limit(name: $0.name, percent: $0.percent, resets: $0.resets.flatMap(date))
            }
            // Gemini's first, and 5-hour before weekly in each group, as for Claude.
            .enumerated().sorted { a, b in
                let ga = a.element.name.hasPrefix("gemini") ? 0 : 1, gb = b.element.name.hasPrefix("gemini") ? 0 : 1
                if ga != gb { return ga < gb }
                if a.element.isFiveHour != b.element.isFiveHour { return a.element.isFiveHour }
                return a.offset < b.offset
            }
            .map(\.element)
            machine.logins.append(AgentLogin(agent: agent, machine: name, email: raw.email, plan: raw.plan, limits: limits,
                                             error: raw.quota?.error, rateLimited: raw.quota?.rateLimited ?? false,
                                             limitsFetched: limits.isEmpty ? nil : Date()))
        }
        machine.agents = (answer.agents ?? []).map {
            let agent = $0.agent ?? "claude"
            // Only Claude tells its state; no state is shown for the others.
            return Agent(machine: name, agent: agent, pid: $0.pid, ppid: $0.ppid ?? 0, sessionId: $0.sessionId ?? "", cwd: $0.cwd ?? "",
                  status: agent == "claude" ? status($0.status) : "", version: $0.version,
                  updated: $0.updatedAt.map { Date(timeIntervalSince1970: $0 / 1000) },
                  mmSession: $0.mmSession ?? "", model: $0.model, context: $0.context ?? 0)
        }
        .sorted { ($0.updated ?? .distantPast) > ($1.updated ?? .distantPast) }
        return machine
    }

    /// Claude's "shell" (a command runs) is busy; "waiting" (for an answer) is idle.
    nonisolated static func status(_ raw: String?) -> String {
        switch raw {
        case "busy", "shell": "busy"
        default: "idle"
        }
    }

    /// "Pro", or "Max 20x" from plan "max" and tier "default_claude_max_20x".
    nonisolated static func planName(_ plan: String?, tier: String?) -> String? {
        guard let plan, !plan.isEmpty else { return nil }
        let size = tier?.split(separator: "_").last.flatMap { $0.hasSuffix("x") && $0.dropLast().allSatisfy(\.isNumber) ? " \($0)" : nil } ?? ""
        return plan.capitalized + size
    }

    /// "2026-10-28T23:00:00.138070+00:00" (the fraction has 6 digits).
    nonisolated static func date(_ text: String) -> Date? {
        let plain = text.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        return try? Date(plain, strategy: .iso8601)
    }

    nonisolated static func describe(_ error: any Error) -> String {
        guard let error = error as? HostError else { return String(describing: error) }
        return switch error {
        case .notPaired: "not paired"
        case .unreachable(let text), .closed(let text), .other(let text): text
        }
    }

    private struct Timeout: Error, CustomStringConvertible {
        var description: String { "No answer in 30 s" }
    }

    nonisolated private static func withTimeout<T: Sendable>(_ limit: Duration, _ work: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(for: limit)
                throw Timeout()
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    /// Runs on each machine with etd's exec. Needs jq and curl.
    nonisolated static let script = #"""
    command -v jq >/dev/null || { echo '{"error":"jq is not installed on this machine"}'; exit 0; }
    noClaude=true acct=null plan=null usage=null agents='[]'
    if [ -d ~/.claude ]; then
    noClaude=false
    acct=$(jq -c '.oauthAccount // null | if . == null then null else {uuid: .accountUuid, email: .emailAddress, name: .displayName, org: .organizationName} end' ~/.claude.json 2>/dev/null)
    if [ "$(uname)" = Darwin ]; then
      creds=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null)
    else
      creds=$(cat ~/.claude/.credentials.json 2>/dev/null)
    fi
    plan=$(printf %s "$creds" | jq -c '.claudeAiOauth | {plan: .subscriptionType, tier: .rateLimitTier}' 2>/dev/null)
    token=$(printf %s "$creds" | jq -r '.claudeAiOauth.accessToken // empty' 2>/dev/null)
    unset creds
    usage='{"error":"not logged in with a Claude account"}'
    if [ -n "$token" ] && [ -n "$SKIP_CLAUDE_USAGE" ]; then
      usage='{}'
    elif [ -n "$token" ]; then
      usage=$(curl -s -m 8 https://api.anthropic.com/api/oauth/usage -H "Authorization: Bearer $token" -H "anthropic-beta: oauth-2025-04-20" |
        jq -c 'if type == "object" and has("five_hour") then {limits: [to_entries[] | select((.key | test("^(five_hour|seven_day)")) and (.value | type) == "object" and .value.utilization != null) | {name: .key, percent: .value.utilization, resets: .value.resets_at}]} else {error: (.error.message? // "no usage answer"), rateLimited: (.error.type? == "rate_limit_error")} end' 2>/dev/null)
      [ -n "$usage" ] || usage='{"error":"usage request failed"}'
    fi
    unset token
    agents=$(for f in ~/.claude/sessions/*.json; do
      [ -f "$f" ] || continue
      pid=$(jq -r .pid "$f" 2>/dev/null)
      kill -0 "$pid" 2>/dev/null || continue
      sid=$(jq -r .sessionId "$f")
      ppid=$(ps -o ppid= -p "$pid" | tr -d ' ')
      if [ "$(uname)" = Darwin ]; then
        mm=$(ps -E -p "$pid" -o command= | tr ' ' '\n' | sed -n 's/^MM_SESSION=//p' | head -1)
      else
        mm=$(tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null | sed -n 's/^MM_SESSION=//p' | head -1)
      fi
      t=$(ls ~/.claude/projects/*/"$sid".jsonl 2>/dev/null | head -1)
      last=
      [ -n "$t" ] && last=$(tail -c 2000000 "$t" | grep '"type":"assistant"' | grep -v '"model":"<synthetic>"' | tail -1 |
        jq -c '{model: .message.model, usage: .message.usage}' 2>/dev/null)
      jq -c --arg mm "$mm" --argjson ppid "${ppid:-0}" --argjson last "${last:-null}" '{pid, sessionId, cwd, status, version, updatedAt, ppid: $ppid, mmSession: $mm, model: $last.model?, context: (($last.usage? // {}) | (.input_tokens // 0) + (.cache_read_input_tokens // 0) + (.cache_creation_input_tokens // 0))}' "$f"
    done | jq -s -c .)
    fi
    # Antigravity CLI: its login, its quota (the call its /usage makes; the
    # token is agy's own and is never refreshed here) and its processes.
    agy=null
    f=~/.gemini/antigravity-cli/antigravity-oauth-token
    if [ -f "$f" ] || command -v agy >/dev/null 2>&1; then
      email=$(jq -r '.id_token_email // empty' "$f" 2>/dev/null)
      quota='{}'
      if [ ! -f "$f" ] && [ "$(uname)" = Darwin ]; then
        quota='{"error":"Antigravity CLI keeps its login in the Keychain here: E.T. cannot read its quota on this machine yet"}'
      elif [ ! -f "$f" ]; then
        quota='{"error":"Antigravity CLI is not logged in here: run agy to log in"}'
      elif [ -z "$SKIP_AGY_QUOTA" ]; then
        t=$(jq -r '.token.access_token // empty' "$f" 2>/dev/null)
        project=$(cat ~/.gemini/antigravity-cli/cache/default_project_id.txt 2>/dev/null)
        quota=$(curl -s -m 8 -X POST https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary \
          -H "Authorization: Bearer $t" -H "Content-Type: application/json" \
          -H "User-Agent: antigravity/hub/2.9.1 $(uname -s | tr A-Z a-z)/$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')" \
          -d "{\"project\":\"${project:-default-cli-project}\"}" |
          jq -c '(.response // .) as $r | if ($r.groups | type) == "array" then {limits: [$r.groups[].buckets[] | select(.remainingFraction != null) | {name: .bucketId, percent: ((1 - .remainingFraction) * 100), resets: .resetTime}]} elif .error.code? == 401 then {error: "Antigravity CLI login expired: open agy here to renew it"} else {error: (.error.message? // "no quota answer"), rateLimited: (.error.code? == 429)} end' 2>/dev/null)
        unset t
        [ -n "$quota" ] || quota='{"error":"quota request failed"}'
      fi
      agy=$(jq -n -c --arg email "$email" --argjson quota "$quota" '{email: (if $email == "" then null else $email end), quota: $quota}')
      more=$(for pid in $(pgrep -x agy 2>/dev/null); do
        ppid=$(ps -o ppid= -p "$pid" | tr -d ' ')
        if [ "$(uname)" = Darwin ]; then
          mm=$(ps -E -p "$pid" -o command= | tr ' ' '\n' | sed -n 's/^MM_SESSION=//p' | head -1)
          cwd=$(lsof -a -p "$pid" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' | head -1)
        else
          mm=$(tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null | sed -n 's/^MM_SESSION=//p' | head -1)
          cwd=$(readlink "/proc/$pid/cwd" 2>/dev/null)
        fi
        jq -n -c --argjson pid "$pid" --argjson ppid "${ppid:-0}" --arg mm "$mm" --arg cwd "$cwd" \
          '{agent: "antigravity", pid: $pid, ppid: $ppid, mmSession: $mm, cwd: $cwd}'
      done | jq -s -c .)
      agents=$(jq -n -c --argjson a "${agents:-[]}" --argjson b "${more:-[]}" '$a + $b')
    fi
    # Grok Build: its login (~/.grok/auth.json), its weekly pool (the call
    # its usage panel makes; the token is grok's own, never refreshed here)
    # and its sessions (~/.grok/active_sessions.json).
    grok=null
    if [ -f ~/.grok/auth.json ]; then
      email=$(jq -r 'to_entries[0].value.email // empty' ~/.grok/auth.json 2>/dev/null)
      gplan=
      quota='{}'
      if [ -z "$SKIP_GROK_USAGE" ]; then
        t=$(jq -r 'to_entries[0].value.key // empty' ~/.grok/auth.json 2>/dev/null)
        quota=$(curl -s -m 8 "https://cli-chat-proxy.grok.com/v1/billing?format=credits" -H "Authorization: Bearer $t" \
          -H "x-xai-token-auth: xai-grok-cli" -H "accept: application/json" -w '\n%{http_code}' |
          jq -R -s -c 'split("\n") as $p | ($p[-1] | tonumber? // 0) as $code | ($p[:-1] | join("\n") | fromjson? // {}) as $b |
            if $b.config.currentPeriod.type? == "USAGE_PERIOD_TYPE_WEEKLY" then {limits: [{name: "grok-weekly", percent: ($b.config.creditUsagePercent // 0), resets: $b.config.billingPeriodEnd}]}
            elif $code == 401 then {error: "Grok login expired: open grok here to renew it"}
            else {error: ($b.error.message? // $b.message? // "no usage answer (HTTP \($code))"), rateLimited: ($code == 429)} end' 2>/dev/null)
        gplan=$(curl -s -m 8 "https://cli-chat-proxy.grok.com/v1/settings" -H "Authorization: Bearer $t" -H "x-xai-token-auth: xai-grok-cli" |
          jq -r '.subscription_tier_display // empty' 2>/dev/null)
        unset t
        [ -n "$quota" ] || quota='{"error":"usage request failed"}'
      fi
      grok=$(jq -n -c --arg email "$email" --arg plan "$gplan" --argjson quota "$quota" \
        '{email: (if $email == "" then null else $email end), plan: (if $plan == "" then null else $plan end), quota: $quota}')
      more=$(jq -c '.[]' ~/.grok/active_sessions.json 2>/dev/null | while read -r s; do
        pid=$(printf %s "$s" | jq -r .pid)
        kill -0 "$pid" 2>/dev/null || continue
        ppid=$(ps -o ppid= -p "$pid" | tr -d ' ')
        if [ "$(uname)" = Darwin ]; then
          mm=$(ps -E -p "$pid" -o command= | tr ' ' '\n' | sed -n 's/^MM_SESSION=//p' | head -1)
        else
          mm=$(tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null | sed -n 's/^MM_SESSION=//p' | head -1)
        fi
        printf %s "$s" | jq -c --argjson ppid "${ppid:-0}" --arg mm "$mm" \
          '{agent: "grok", pid, ppid: $ppid, sessionId: .session_id, cwd, mmSession: $mm}'
      done | jq -s -c .)
      agents=$(jq -n -c --argjson a "${agents:-[]}" --argjson b "${more:-[]}" '$a + $b')
    fi
    jq -n -c --argjson noClaude "$noClaude" --argjson account "${acct:-null}" --argjson plan "${plan:-null}" --argjson usage "${usage:-null}" \
      --argjson agents "${agents:-[]}" --argjson agy "${agy:-null}" --argjson grok "${grok:-null}" \
      '{noClaude: $noClaude, account: $account, plan: $plan, usage: $usage, agents: $agents, agy: $agy, grok: $grok}'
    """#
}

extension Logbook {
    /// Claude's title for an agent: its transcript's, else the live one in
    /// its manymux session (the session id changes on /clear).
    func title(for agent: Agents.Agent) -> String? {
        sessions.first { $0.key.machine == agent.machine && $0.key.sessionId == agent.sessionId }?.title
            ?? sessions.first { $0.key.machine == agent.machine && $0.mmSession == agent.mmSession && $0.isLive && !agent.mmSession.isEmpty }?.title
    }
}
