import Foundation

/// Links the app's `ccop` into `~/.local/bin`, so a terminal and an agent find
/// it. The CLI sits in `Contents/Helpers`, which is not on PATH.
///
/// A release and a dev build make the same link: the last one installed wins.
/// The guide for agents says `ccop`, whichever build copied it.
public struct CLIInstaller {
    public static let toolPath = "Contents/Helpers/ccop"

    public enum Failure: Error, LocalizedError, Equatable {
        case toolMissing(URL)
        case occupied(URL)
        case io(String)

        public var errorDescription: String? {
            switch self {
            case let .toolMissing(url): "The command-line tool is missing from the app: \(url.path)"
            case let .occupied(url): "\(url.path) already exists and is not a link to ccop. Remove it first."
            case let .io(text): text
            }
        }
    }

    public var tool: URL
    public var binDir: URL

    public init(tool: URL, binDir: URL) {
        self.tool = tool
        self.binDir = binDir
    }

    /// The running app's tool and `~/.local/bin`.
    public init(bundle: Bundle = .main) {
        self.init(tool: bundle.bundleURL.appendingPathComponent(Self.toolPath),
                  binDir: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin"))
    }

    public var link: URL { binDir.appendingPathComponent("ccop") }

    /// Makes or refreshes the link. Never replaces anything that is not a
    /// link into a ccop bundle.
    @discardableResult
    public func install() throws -> URL {
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: tool.path) else { throw Failure.toolMissing(tool) }
        do {
            try fm.createDirectory(at: binDir, withIntermediateDirectories: true)
        } catch {
            throw Failure.io("Cannot create \(binDir.path): \(error.localizedDescription)")
        }
        if let existing = try? fm.destinationOfSymbolicLink(atPath: link.path) {
            if existing == tool.path { return link }
            guard existing.hasSuffix("/" + Self.toolPath) else { throw Failure.occupied(link) }
            try? fm.removeItem(at: link)
        } else if fm.fileExists(atPath: link.path) {
            throw Failure.occupied(link)
        }
        do {
            try fm.createSymbolicLink(atPath: link.path, withDestinationPath: tool.path)
        } catch {
            throw Failure.io("Cannot link \(link.path): \(error.localizedDescription)")
        }
        return link
    }

    /// Is the link's folder in this PATH?
    public func isOnPath(_ path: String) -> Bool {
        let target = binDir.standardizedFileURL.path
        return path.split(separator: ":").contains { URL(fileURLWithPath: String($0)).standardizedFileURL.path == target }
    }

    /// One line to run in a terminal when the folder is not on PATH.
    public static let pathHint = "echo 'export PATH=\"$HOME/.local/bin:$PATH\"' >> ~/.zshrc"

    private static let pathMarker = "CCOP_PATH="

    /// The PATH line in what the login shell printed: profile scripts may print more.
    public static func path(inShellOutput text: String) -> String? {
        text.split(whereSeparator: \.isNewline).last { $0.hasPrefix(pathMarker) }.map { String($0.dropFirst(pathMarker.count)) }
    }

    /// The PATH of a terminal, or nil when the shell does not answer. An app
    /// opened from Finder has a shorter PATH than a terminal, so its own says
    /// little. Blocks: call it off the main thread.
    public static func loginShellPath(timeout: TimeInterval = 5) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh")
        p.arguments = ["-l", "-i", "-c", "printf '\\n\(pathMarker)%s\\n' \"$PATH\""]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let deadline = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        deadline.cancel()
        return path(inShellOutput: String(decoding: data, as: UTF8.self))
    }
}
