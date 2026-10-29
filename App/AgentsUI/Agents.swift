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
            default: name.replacingOccurrences(of: "_", with: " ")
            }
        }
    }

    /// A running Claude process.
    struct Agent: Identifiable, Equatable, Sendable {
        var machine: String
        var pid: Int
        var ppid: Int
        var sessionId: String
        var cwd: String
        /// "busy", "idle" (Claude's "shell" and "waiting" are busy and idle).
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
        var agents: [Agent] = []
        /// The script failed or the machine did not answer.
        var error: String?
        /// No ~/.claude: Claude Code was never used here.
        var noClaude = false
        var fetched: Date?

        var id: String { name }
    }

    /// An account with its limits and the machines logged in with it.
    struct AccountUsage: Identifiable, Equatable, Sendable {
        var account: Account
        var plan: String?
        var limits: [Limit]
        var usageError: String?
        var machines: [String]
        var fetched: Date?

        var id: String { account.uuid }
    }

    /// By name.
    private(set) var machines: [Machine] = []
    /// The built-in agents on each machine, by machine name (PLAN-multi-agent).
    private(set) var installed: [String: [AgentOnMachine]] = [:]
    private(set) var refreshing = false
    private(set) var refreshed: Date?

    @ObservationIgnored private let hosts: @MainActor () -> [String: IrohHost]
    @ObservationIgnored private let log: @MainActor (String) -> Void
    /// The usage API is asked at most this often.
    private static let interval: Duration = .seconds(60)

    init(hosts: @escaping @MainActor () -> [String: IrohHost], log: @escaping @MainActor (String) -> Void) {
        self.hosts = hosts
        self.log = log
    }

    // MARK: - Lookups

    /// Every live agent that has a terminal.
    var running: [Agent] {
        machines.flatMap(\.agents).filter { !$0.isOrphan }
    }

    var accounts: [AccountUsage] {
        var byId: [String: AccountUsage] = [:]
        var order: [String] = []
        for machine in machines {
            guard let account = machine.account else { continue }
            if var known = byId[account.uuid] {
                known.machines.append(machine.name)
                // The newest answer has the newest limits.
                if (machine.fetched ?? .distantPast) > (known.fetched ?? .distantPast), !machine.limits.isEmpty {
                    known.limits = machine.limits
                    known.usageError = machine.usageError
                    known.fetched = machine.fetched
                }
                byId[account.uuid] = known
            } else {
                order.append(account.uuid)
                byId[account.uuid] = AccountUsage(account: account, plan: machine.plan, limits: machine.limits,
                                                  usageError: machine.usageError, machines: [machine.name], fetched: machine.fetched)
            }
        }
        return order.compactMap { byId[$0] }
    }

    func machine(_ name: String) -> Machine? {
        machines.first { $0.name == name }
    }

    /// The agent in a manymux session, if Claude runs there.
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
        let installedTask = Task {
            await withTaskGroup(of: Void.self) { group in
                for name in hosts.keys {
                    group.addTask { _ = await self.loadInstalled(on: name) }
                }
            }
        }
        await withTaskGroup(of: (String, Result<String, any Error>).self) { group in
            for (name, host) in hosts {
                group.addTask {
                    do {
                        let answer = try await Self.withTimeout(.seconds(30)) { try await host.run(Self.script) }
                        return (name, .success(answer.output))
                    } catch {
                        return (name, .failure(error))
                    }
                }
            }
            for await (name, result) in group {
                var machine = machine(name) ?? Machine(name: name)
                switch result {
                case .success(let output):
                    do {
                        machine = try Self.parse(output, machine: name)
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

    // MARK: - The script's answer

    private struct Answer: Decodable {
        var error: String?
        var noClaude: Bool?
        var account: Account?
        var plan: Plan?
        var usage: Usage?
        var agents: [RawAgent]?

        struct Plan: Decodable {
            var plan: String?
            var tier: String?
        }

        struct Usage: Decodable {
            var limits: [RawLimit]?
            var error: String?
        }

        struct RawLimit: Decodable {
            var name: String
            var percent: Double
            var resets: String?
        }

        struct RawAgent: Decodable {
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
        machine.usageError = answer.usage?.error
        machine.agents = (answer.agents ?? []).map {
            Agent(machine: name, pid: $0.pid, ppid: $0.ppid ?? 0, sessionId: $0.sessionId ?? "", cwd: $0.cwd ?? "",
                  status: status($0.status), version: $0.version,
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
    [ -d ~/.claude ] || { echo '{"noClaude":true}'; exit 0; }
    command -v jq >/dev/null || { echo '{"error":"jq is not installed on this machine"}'; exit 0; }
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
    if [ -n "$token" ]; then
      usage=$(curl -s -m 8 https://api.anthropic.com/api/oauth/usage -H "Authorization: Bearer $token" -H "anthropic-beta: oauth-2025-04-20" |
        jq -c 'if type == "object" and has("five_hour") then {limits: [to_entries[] | select((.key | test("^(five_hour|seven_day)")) and (.value | type) == "object" and .value.utilization != null) | {name: .key, percent: .value.utilization, resets: .value.resets_at}]} else {error: (.error.message? // "no usage answer")} end' 2>/dev/null)
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
    jq -n -c --argjson account "${acct:-null}" --argjson plan "${plan:-null}" --argjson usage "$usage" --argjson agents "${agents:-[]}" \
      '{account: $account, plan: $plan, usage: $usage, agents: $agents}'
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
