// Gets the sessions by running `ccop sessions --json`. The CLI keeps an
// index, so a refresh reads only what the transcripts got since the last one.

import Foundation

public protocol SessionSource: Sendable {
    func load() throws -> [Session]
    /// What one session did: `ccop anatomy <id> --json`.
    func anatomy(_ sessionID: String) throws -> Anatomy
    /// The full texts of one lane: `main` or a subagent's id.
    func chat(_ sessionID: String, lane: String) throws -> LaneChat
    /// One tool call in full.
    func call(_ sessionID: String, toolUseID: String) throws -> ToolCall
    /// Tokens and API-equivalent cost by hour: `ccop usage --json`.
    func usage(days: Int) throws -> UsageReport
    /// The instructions for agents: `ccop guide`.
    func guide() throws -> String
}

public enum SessionSourceError: Error, LocalizedError, Equatable {
    case cliNotFound
    case failed(status: Int32, message: String)

    public var errorDescription: String? {
        switch self {
        case .cliNotFound:
            "The ccop command-line tool was not found. Build the app with scripts/build-app.sh, or set CCOP_CLI."
        case let .failed(status, message):
            "ccop failed (exit \(status)): \(message)"
        }
    }
}

public struct CLISessionSource: SessionSource {
    public var cli: URL

    public init(cli: URL) {
        self.cli = cli
    }

    /// `CCOP_CLI`, else `Contents/Helpers/ccop` in the app bundle, else the
    /// release build of a checkout next to `swift run` (for development).
    public static func locate(bundle: Bundle = .main, environment: [String: String] = ProcessInfo.processInfo.environment,
                              fileManager: FileManager = .default) -> URL? {
        var candidates: [URL] = []
        if let path = environment["CCOP_CLI"], !path.isEmpty { candidates.append(URL(fileURLWithPath: path)) }
        candidates.append(bundle.bundleURL.appendingPathComponent("Contents/Helpers/ccop"))
        // apps/menubar/.build/<config>/CCOP → <repo>/target/release/ccop
        let exe = URL(fileURLWithPath: CommandLine.arguments.first ?? "").resolvingSymlinksInPath()
        var dir = exe.deletingLastPathComponent()
        for _ in 0 ..< 6 {
            candidates.append(dir.appendingPathComponent("target/release/ccop"))
            dir = dir.deletingLastPathComponent()
        }
        return candidates.first { fileManager.isExecutableFile(atPath: $0.path) }
    }

    public func load() throws -> [Session] {
        try Session.decodeList(run(["sessions", "--json"]))
    }

    public func anatomy(_ sessionID: String) throws -> Anatomy {
        try Anatomy.decode(run(["anatomy", sessionID, "--json"]))
    }

    public func chat(_ sessionID: String, lane: String) throws -> LaneChat {
        try LaneChat.decode(run(["chat", sessionID, "--lane", lane, "--json"]))
    }

    public func call(_ sessionID: String, toolUseID: String) throws -> ToolCall {
        try ToolCall.decode(run(["call", sessionID, toolUseID, "--json"]))
    }

    public func usage(days: Int) throws -> UsageReport {
        try UsageReport.decode(run(["usage", "--json", "--days", String(days)]))
    }

    public func guide() throws -> String {
        String(decoding: try run(["guide"]), as: UTF8.self)
    }

    /// Runs the CLI and returns what it printed; throws with its stderr when it fails.
    public func run(_ arguments: [String]) throws -> Data {
        let p = Process()
        p.executableURL = cli
        p.arguments = arguments
        let out = Pipe()
        let err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice
        try p.run()
        // Read both pipes while it runs, so a full pipe cannot block it.
        nonisolated(unsafe) var errData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            errData = err.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let message = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw SessionSourceError.failed(status: p.terminationStatus, message: message)
        }
        return data
    }
}

/// Resuming a session: `cd <folder> && claude --resume <id>`.
public enum Resume {
    /// Quotes one argument for a POSIX shell: `it's` becomes `'it'\''s'`.
    public static func shellQuote(_ s: String) -> String {
        if !s.isEmpty, s.allSatisfy({ ($0.isLetter || $0.isNumber || "-_./=:@".contains($0)) && $0.isASCII }) {
            return s
        }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    public static func command(_ s: Session) -> String {
        "cd \(shellQuote(s.projectDir)) && claude --resume \(shellQuote(s.id))"
    }

    /// A `.command` file: Terminal runs it when it is opened. It runs the
    /// user's login shell, so `claude` is found as in a new terminal window.
    public static func script(_ s: Session) -> String {
        "#!/bin/sh\nexec \"${SHELL:-/bin/zsh}\" -l -i -c \(shellQuote(command(s)))\n"
    }
}
