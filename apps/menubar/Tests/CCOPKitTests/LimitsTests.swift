import Foundation
import XCTest
@testable import CCOPKit

final class LimitsTests: XCTestCase {
    func d(_ s: String) -> Date { parseDate(s)! }

    /// The shape of `claude -p /usage` on 2026-11-03, with made-up names.
    let sample = """
    You are currently using your subscription to power your Claude Code usage

    Current week (all models): 97% used · resets Nov 3 at 7:59pm (Europe/London)
    Current week (Fable): 0% used · resets Nov 3 at 8pm (Europe/London)

    What's contributing to your usage?
    Approximate · sessions on this machine only · shares overlap

    Last 24h · 5581 requests · 39 sessions
      73%  Give "general-purpose" subagents a cheaper model
      72%  Start fresh when you switch tasks · run /clear
      35%  Stop sessions you no longer need · some ran 8 hours or more
      11%  Ask Read for less · up to 29k tokens, 27 times
      Top skills: /alpha 2%, /beta 1%
      Top subagents: general-purpose 42%, reviewer 2%

    Last 7d · 28185 requests · 359 sessions
      74%  Start fresh when you switch tasks · run /clear
      61%  Give "general-purpose" subagents a cheaper model
      21%  Stop sessions you no longer need · some ran 8 hours or more
      16%  Trim ~/code/harbor/AGENTS.md · 10k tokens per request
      Top MCP servers: browser 8%
    """

    func testTheWeeklyLimitsAndTheirResetTimes() throws {
        let l = try XCTUnwrap(UsageLimits.parse(sample, now: d("2026-11-03T14:00:00Z")))
        XCTAssertTrue(l.subscription)
        XCTAssertEqual(l.limits.map(\.title), ["Week · all models", "Week · Fable"])
        XCTAssertEqual(l.limits.map(\.usedPercent), [97, 0])
        // London is on GMT in November. "7:59pm" is the week's last minute:
        // it resets at 20:00. At 19:59 the week would take in the whole
        // 19:00 hour of the old week (ccop sums costs by the hour).
        XCTAssertEqual(l.limits.map(\.resetsAt), [d("2026-11-03T20:00:00Z"), d("2026-11-03T20:00:00Z")])
        XCTAssertEqual(l.week?.scope, "all models")
        XCTAssertEqual(l.week?.resetText, "Nov 3 at 7:59pm (Europe/London)")
    }

    func testTheTipsByPeriod() throws {
        let l = try XCTUnwrap(UsageLimits.parse(sample, now: d("2026-11-03T14:00:00Z")))
        XCTAssertEqual(l.periods.map(\.title), ["Last 24h", "Last 7d"])
        XCTAssertEqual(l.periods[1].summary, "28185 requests · 359 sessions")
        XCTAssertEqual(l.periods[0].tips.count, 4)
        XCTAssertEqual(l.periods[1].tips.first, UsageLimits.Tip(percent: 74, text: "Start fresh when you switch tasks · run /clear"))
        XCTAssertEqual(l.periods[0].extras, ["Top skills: /alpha 2%, /beta 1%", "Top subagents: general-purpose 42%, reviewer 2%"])
        XCTAssertEqual(l.periods[1].extras, ["Top MCP servers: browser 8%"])
    }

    func testATimeWithNoDateIsTheNextSuchTime() throws {
        let text = "Current session: 12% used · resets 4pm (Europe/London)"
        let before = try XCTUnwrap(UsageLimits.parse(text, now: d("2026-11-03T14:00:00Z")))
        XCTAssertEqual(before.limits.first?.title, "Session")
        XCTAssertNil(before.week)
        XCTAssertEqual(before.limits.first?.resetsAt, d("2026-11-03T16:00:00Z"))
        let after = try XCTUnwrap(UsageLimits.parse(text, now: d("2026-11-03T17:00:00Z")))
        XCTAssertEqual(after.limits.first?.resetsAt, d("2026-11-04T16:00:00Z"))
    }

    func testADateWithNoYearIsTheNearestOneAhead() throws {
        let text = "Current week (all models): 40% used · resets Jan 2 at 9am (UTC)"
        let l = try XCTUnwrap(UsageLimits.parse(text, now: d("2026-12-30T10:00:00Z")))
        XCTAssertEqual(l.week?.resetsAt, d("2027-01-02T09:00:00Z"))
    }

    func testSummerTimeIsTheZonesOwn() throws {
        // London is on BST (UTC+1) in June.
        let text = "Current week (all models): 5% used · resets Jun 4 at 7:59pm (Europe/London)"
        let l = try XCTUnwrap(UsageLimits.parse(text, now: d("2026-06-01T10:00:00Z")))
        XCTAssertEqual(l.week?.resetsAt, d("2026-06-04T19:00:00Z"))
    }

    func testTextWithNoLimitIsNotRead() {
        XCTAssertNil(UsageLimits.parse("Unknown command: /usage", now: Date()))
        XCTAssertNil(UsageLimits.parse("", now: Date()))
    }

    func testAReadSetsTheResetAndTheWeeklyLimit() throws {
        let limits = try XCTUnwrap(UsageLimits.parse(
            "Current week (all models): 40% used · resets Nov 5 at 6pm (UTC)", now: d("2026-11-03T12:00:00Z")))
        // The week started Thu 29 Oct 18:00; $2 an hour for 20 hours since then = $40.
        let hours = (0 ..< 20).map { UsageReport.Hour(start: d("2026-11-02T00:00:00Z").addingTimeInterval(Double($0) * 3600), costMicros: 2_000_000) }
        let report = UsageReport(generatedAt: d("2026-11-03T12:00:00Z"), hours: hours)
        let (s, calibrated) = Plan.applying(limits, to: PlanSettings(), report: report)
        XCTAssertTrue(calibrated)
        XCTAssertEqual(s.resetAnchor, d("2026-11-05T18:00:00Z"))
        XCTAssertEqual(s.weeklyBudgetMicros, 100_000_000)
        XCTAssertEqual(s.calibratedAt, d("2026-11-03T12:00:00Z"))
    }

    func testASmallPercentKeepsTheOldLimit() throws {
        let limits = try XCTUnwrap(UsageLimits.parse(
            "Current week (all models): 2% used · resets Nov 5 at 6pm (UTC)", now: d("2026-11-03T12:00:00Z")))
        let report = UsageReport(generatedAt: d("2026-11-03T12:00:00Z"),
                                 hours: [UsageReport.Hour(start: d("2026-11-03T10:00:00Z"), costMicros: 1_000_000)])
        let old = PlanSettings(weeklyBudgetMicros: 70_000_000)
        let (s, calibrated) = Plan.applying(limits, to: old, report: report)
        XCTAssertFalse(calibrated)
        XCTAssertEqual(s.weeklyBudgetMicros, 70_000_000)
        XCTAssertEqual(s.resetAnchor, d("2026-11-05T18:00:00Z"))
    }

    /// A home folder with a made-up `claude` that prints one limit, and the
    /// environment of an app opened from Finder: a short PATH.
    private func fakeHome(claudeAt path: String, zshrc: String? = nil,
                          script: String = "#!/bin/sh\necho 'Current week (all models): 12% used'\n") throws -> (home: URL, environment: [String: String]) {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        let claude = home.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: claude.deletingLastPathComponent(), withIntermediateDirectories: true)
        try script.write(to: claude, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: claude.path)
        if let zshrc { try zshrc.write(to: home.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8) }
        return (home, ["HOME": home.path, "ZDOTDIR": home.path, "SHELL": "/bin/zsh", "PATH": "/usr/bin:/bin"])
    }

    func testClaudeThatOnlyAnInteractiveShellFindsIsRead() throws {
        let (_, env) = try fakeHome(claudeAt: "tools/claude", zshrc: "export PATH=\"$HOME/tools:$PATH\"\n")
        let limits = try LimitsReader.read(environment: env)
        XCTAssertEqual(limits.week?.usedPercent, 12)
    }

    func testClaudeFromAnAliasInTheShellFileIsRead() throws {
        let (_, env) = try fakeHome(claudeAt: "tools/claude", zshrc: "alias claude=\"$HOME/tools/claude\"\n")
        let limits = try LimitsReader.read(environment: env)
        XCTAssertEqual(limits.week?.usedPercent, 12)
    }

    func testClaudeThatNoShellFindsIsReadFromItsInstallFolder() throws {
        let (_, env) = try fakeHome(claudeAt: ".local/bin/claude")
        let limits = try LimitsReader.read(environment: env)
        XCTAssertEqual(limits.week?.usedPercent, 12)
    }

    func testNoClaudeAnywhereSaysSoInPlainWords() throws {
        let (_, env) = try fakeHome(claudeAt: "elsewhere/claude")
        XCTAssertThrowsError(try LimitsReader.read(environment: env)) { error in
            XCTAssertEqual(error as? LimitsReaderError, .notFound)
            XCTAssertFalse(error.localizedDescription.contains("zsh:"))
        }
    }

    func testAChosenPathIsUsedEvenWhenNoShellFindsClaude() throws {
        let (home, env) = try fakeHome(claudeAt: "elsewhere/claude")
        let limits = try LimitsReader.read(claudePath: home.appendingPathComponent("elsewhere/claude").path, environment: env)
        XCTAssertEqual(limits.week?.usedPercent, 12)
    }

    func testAChosenPathWithASpaceAndAQuoteIsUsed() throws {
        let (home, env) = try fakeHome(claudeAt: "my tools's/claude")
        let limits = try LimitsReader.read(claudePath: home.appendingPathComponent("my tools's/claude").path, environment: env)
        XCTAssertEqual(limits.week?.usedPercent, 12)
    }

    func testAChosenPathThatIsGoneIsAnErrorAndNotAnotherClaude() throws {
        let (home, env) = try fakeHome(claudeAt: ".local/bin/claude")
        let gone = home.appendingPathComponent("versions/2.1.0").path
        XCTAssertThrowsError(try LimitsReader.read(claudePath: gone, environment: env)) { error in
            XCTAssertEqual(error as? LimitsReaderError, .chosenPathMissing(gone))
        }
    }

    /// Like Claude Code: with an API key, /usage prints only the cost.
    private let keyAwareClaude = """
        #!/bin/sh
        if [ -n "$ANTHROPIC_API_KEY" ]; then
          printf 'Total cost:            $0.0000\\nkey=%s\\n' "$ANTHROPIC_API_KEY"
          exit 0
        fi
        echo 'Current week (all models): 12% used'

        """

    func testAKeyFromTheShellFileGivesAPlainError() throws {
        let (_, env) = try fakeHome(claudeAt: "tools/claude", zshrc: "export ANTHROPIC_API_KEY=sk-shell\nexport PATH=\"$HOME/tools:$PATH\"\n",
                                    script: keyAwareClaude)
        XCTAssertThrowsError(try LimitsReader.read(environment: env)) { error in
            XCTAssertEqual(error as? LimitsReaderError, .apiKeyUsed)
        }
    }

    func testAnEmptyKeyWinsOverTheKeyInTheShellFile() throws {
        let (_, env) = try fakeHome(claudeAt: "tools/claude", zshrc: "export ANTHROPIC_API_KEY=sk-shell\nexport PATH=\"$HOME/tools:$PATH\"\n",
                                    script: keyAwareClaude)
        let limits = try LimitsReader.read(apiKey: .empty, environment: env)
        XCTAssertEqual(limits.week?.usedPercent, 12)
    }

    func testAChosenKeyReachesClaudeButNotItsArguments() throws {
        let (home, env) = try fakeHome(claudeAt: "tools/claude", zshrc: "export ANTHROPIC_API_KEY=sk-shell\n", script: keyAwareClaude)
        let claude = home.appendingPathComponent("tools/claude").path
        // The fake prints the key it got, and "Total cost:", so the read fails;
        // the run's output is not in the error, so check the shell's lines.
        XCTAssertThrowsError(try LimitsReader.read(claudePath: claude, apiKey: .key("sk-chosen 'x'"), environment: env))
        for arguments in LimitsReader.attempts(claudePath: claude, apiKey: .key("sk-chosen 'x'"), environment: env) {
            XCTAssertFalse(arguments.joined(separator: " ").contains("sk-chosen"))
        }
        var e = env
        e["CCOP_ANTHROPIC_API_KEY"] = "sk-chosen 'x'"
        let script = LimitsReader.attempts(claudePath: claude, apiKey: .key("sk-chosen 'x'"), environment: env)[1]
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = script
        p.environment = e
        let out = Pipe()
        p.standardOutput = out
        try p.run()
        p.waitUntilExit()
        let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertTrue(text.contains("key=sk-chosen 'x'"), text)
    }

    func testTheShellSettingChangesNothing() {
        let env = ["HOME": "/Users/demo"]
        XCTAssertEqual(LimitsReader.attempts(claudePath: "/opt/claude", apiKey: .shell, environment: env),
                       LimitsReader.attempts(claudePath: "/opt/claude", environment: env))
        XCTAssertFalse(LimitsReader.attempts(claudePath: "/opt/claude", environment: env)[0][2].contains("ANTHROPIC_API_KEY"))
        XCTAssertEqual(LimitsReader.shownCommand(.empty), "ANTHROPIC_API_KEY=\"\" claude -p /usage")
    }

    func testTheKeyIsKeptInTheKeychainAndTheModeInDefaults() throws {
        let suite = "ccop-test-" + UUID().uuidString
        let store = ApiKeyStore(service: "ccop-test-" + UUID().uuidString, defaultsSuite: suite)
        addTeardownBlock {
            try? store.save(.shell)
            UserDefaults().removePersistentDomain(forName: suite)
        }
        XCTAssertEqual(store.load(), .shell)
        try store.save(.key("sk-one"))
        XCTAssertEqual(store.load(), .key("sk-one"))
        XCTAssertEqual(try store.readKey(), "sk-one")
        XCTAssertFalse(UserDefaults(suiteName: suite)?.dictionaryRepresentation().values
            .contains { "\($0)".contains("sk-one") } ?? true)
        try store.save(.key("sk-two"))
        XCTAssertEqual(store.load(), .key("sk-two"))
        try store.save(.empty)
        XCTAssertEqual(store.load(), .empty)
        XCTAssertNil(try store.readKey())
        try store.save(.shell)
        XCTAssertEqual(store.load(), .shell)
    }

    func testATypedPathIsCleanedUp() {
        let env = ["HOME": "/Users/demo"]
        XCTAssertEqual(LimitsReader.chosenPath(" ~/bin/claude \n", environment: env), "/Users/demo/bin/claude")
        XCTAssertEqual(LimitsReader.chosenPath("/opt/claude", environment: env), "/opt/claude")
        XCTAssertNil(LimitsReader.chosenPath("   ", environment: env))
    }

    func testAReadSavesNoSession() {
        // Without the flag each read left a "/usage" session with 0 tokens
        // in ~/.claude/projects, and it showed in the session list.
        XCTAssertTrue(LimitsReader.command.contains("--no-session-persistence"))
        XCTAssertTrue(LimitsReader.command.hasSuffix(" /usage"))
    }

    func testTimes() {
        XCTAssertEqual(UsageLimits.parseTime("7:59pm").map { [$0.0, $0.1] }, [19, 59])
        XCTAssertEqual(UsageLimits.parseTime("12am").map { [$0.0, $0.1] }, [0, 0])
        XCTAssertEqual(UsageLimits.parseTime("12pm").map { [$0.0, $0.1] }, [12, 0])
        XCTAssertEqual(UsageLimits.parseTime("19:05").map { [$0.0, $0.1] }, [19, 5])
        XCTAssertNil(UsageLimits.parseTime("13pm"))
        XCTAssertNil(UsageLimits.parseTime("soon"))
    }
}
