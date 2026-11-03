// Self-update from GitHub Releases, the same approach as LocalCron:
// read releases/latest, download the DMG, check it with Gatekeeper (spctl),
// then a detached script swaps the app after it quits and opens the new one.

import Foundation
import Security

public enum Updater {
    public static let repo = "shchahrykovich/ccop"
    public static var latestURL: URL { URL(string: "https://api.github.com/repos/\(repo)/releases/latest")! }
    public static var releasesPage: URL { URL(string: "https://github.com/\(repo)/releases/latest")! }
    /// Where the install script writes what it did.
    public static var logsDir: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/ccop")
    }

    public struct Release: Equatable, Sendable {
        public var version: String
        public var tag: String
        public var dmg: URL
        public var notes: String
    }

    public enum Failure: Error, LocalizedError, Equatable {
        case noDmg
        case untrustedURL(String)
        case badResponse(String)
        case gatekeeper(String)

        public var errorDescription: String? {
            switch self {
            case .noDmg: "The latest release has no .dmg file."
            case let .untrustedURL(url): "Refusing to download from \(url)."
            case let .badResponse(text): "GitHub answered unexpectedly: \(text)"
            case let .gatekeeper(text): "macOS did not accept the downloaded image: \(text)"
            }
        }
    }

    // MARK: Pure logic (tested)

    /// Why this copy must not update itself, or nil. A build without a Team ID
    /// (`swift run`, scripts/build-app.sh, scripts/install.sh) is a local
    /// build: the release would replace the code it was built from.
    /// Checked before any network call.
    public static func disabledReason(teamID: String?) -> String? {
        guard teamID?.isEmpty ?? true else { return nil }
        return "This is a local build, so it does not update itself. Build it again from source, or install a release from GitHub."
    }

    /// `1.2.10` > `1.2.9`. Anything after `-` or `+` is ignored.
    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        func parts(_ v: String) -> [Int] {
            let core = v.trimmingCharacters(in: CharacterSet(charactersIn: "v"))
                .split(whereSeparator: { $0 == "-" || $0 == "+" }).first ?? ""
            return core.split(separator: ".").map { Int($0) ?? 0 }
        }
        let a = parts(candidate), b = parts(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// Only https to GitHub hosts, with no user info or port tricks.
    public static func isTrusted(_ url: URL) -> Bool {
        guard url.scheme == "https", let host = url.host?.lowercased(), url.user == nil, url.password == nil,
              url.port == nil else { return false }
        return ["github.com", "api.github.com"].contains(host) || host.hasSuffix(".githubusercontent.com")
    }

    public static func parse(_ data: Data) throws -> Release {
        struct Asset: Decodable {
            var name: String
            var browserDownloadUrl: String
        }
        struct Latest: Decodable {
            var tagName: String
            var body: String?
            var assets: [Asset]
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let latest: Latest
        do {
            latest = try decoder.decode(Latest.self, from: data)
        } catch {
            throw Failure.badResponse(String(data: data.prefix(200), encoding: .utf8) ?? "not text")
        }
        guard let asset = latest.assets.first(where: { $0.name.lowercased().hasSuffix(".dmg") }),
              let url = URL(string: asset.browserDownloadUrl) else { throw Failure.noDmg }
        guard isTrusted(url) else { throw Failure.untrustedURL(asset.browserDownloadUrl) }
        let version = latest.tagName.hasPrefix("v") ? String(latest.tagName.dropFirst()) : latest.tagName
        return Release(version: version, tag: latest.tagName, dmg: url, notes: latest.body ?? "")
    }

    /// Why this copy cannot replace itself, or nil when it can.
    public static func obstacle(appURL: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String? {
        guard appURL.pathExtension == "app" else {
            return "This copy does not run from an app bundle. Download the new version from GitHub."
        }
        let parent = appURL.deletingLastPathComponent().standardizedFileURL.path
        let allowed = ["/Applications", home.appendingPathComponent("Applications").standardizedFileURL.path]
        guard allowed.contains(parent) else {
            return "Move CCOP to the Applications folder first; updates only replace a copy there."
        }
        guard FileManager.default.isWritableFile(atPath: parent) else {
            return "\(parent) is not writable for your user. Download the new version from GitHub."
        }
        return nil
    }

    /// The script that swaps the app after this process quits. The new app
    /// must pass `codesign --verify` and carry the same Team ID as this one;
    /// on any failure the old app stays and is opened again.
    public static func installScript(dmg: URL, dest: URL, pid: Int32, team: String, log: URL) -> String {
        func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        return """
        #!/bin/bash
        # ccop self-update. Written by the app, run once, then deleted.
        set -uo pipefail
        DMG=\(q(dmg.path))
        DEST=\(q(dest.path))
        PID=\(pid)
        TEAM=\(q(team))
        LOG=\(q(log.path))
        mkdir -p "$(dirname "$LOG")"
        exec >>"$LOG" 2>&1
        echo "update started $(date)"
        MOUNT="$(mktemp -d /tmp/ccop-update.XXXXXX)"
        cleanup() { hdiutil detach "$MOUNT" -quiet >/dev/null 2>&1; rmdir "$MOUNT" 2>/dev/null; rm -f "$DMG" "$0"; }
        trap cleanup EXIT
        for _ in $(seq 1 60); do kill -0 "$PID" 2>/dev/null || break; sleep 0.5; done
        kill -9 "$PID" 2>/dev/null
        [ -n "$TEAM" ] || { echo "no team to check"; open "$DEST"; exit 1; }
        hdiutil attach -nobrowse -noverify -noautoopen -mountpoint "$MOUNT" "$DMG" || { echo "attach failed"; open "$DEST"; exit 1; }
        SRC="$MOUNT/CCOP.app"
        [ -d "$SRC" ] || { echo "no CCOP.app in image"; open "$DEST"; exit 1; }
        codesign --verify --deep --strict "$SRC" || { echo "signature check failed"; open "$DEST"; exit 1; }
        NEW_TEAM="$(codesign -dv "$SRC" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
        [ "$NEW_TEAM" = "$TEAM" ] || { echo "team $NEW_TEAM is not $TEAM"; open "$DEST"; exit 1; }
        STAGE="$DEST.update-$$"
        OLD="$DEST.old-$$"
        rm -rf "$STAGE"
        ditto "$SRC" "$STAGE" || { echo "copy failed"; rm -rf "$STAGE"; open "$DEST"; exit 1; }
        if mv "$DEST" "$OLD" && mv "$STAGE" "$DEST"; then
          rm -rf "$OLD"
        else
          echo "swap failed, restoring"
          [ -d "$OLD" ] && { rm -rf "$DEST"; mv "$OLD" "$DEST"; }
          rm -rf "$STAGE"
        fi
        xattr -dr com.apple.quarantine "$DEST" 2>/dev/null
        for _ in 1 2 3 4; do
          open "$DEST" && break
          sleep 2
        done
        echo "update finished $(date)"
        """
    }

    // MARK: Effects

    public static func latest(currentVersion: String) async throws -> Release {
        var request = URLRequest(url: latestURL, timeoutInterval: 30)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("ccop/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw Failure.badResponse("status \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        return try parse(data)
    }

    public static func download(_ release: Release) async throws -> URL {
        guard isTrusted(release.dmg) else { throw Failure.untrustedURL(release.dmg.absoluteString) }
        let (temp, response) = try await URLSession.shared.download(from: release.dmg)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, let final = http.url, isTrusted(final) else {
            throw Failure.badResponse("download failed")
        }
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("ccop-\(release.version).dmg")
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: temp, to: dest)
        return dest
    }

    /// Gatekeeper must accept the image: Developer ID signed and notarized.
    public static func checkImage(_ dmg: URL) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/spctl")
        p.arguments = ["--assess", "--type", "open", "--context", "context:primary-signature", dmg.path]
        let pipe = Pipe()
        p.standardError = pipe
        p.standardOutput = pipe
        try p.run()
        p.waitUntilExit()
        if p.terminationStatus != 0 {
            let text = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw Failure.gatekeeper(text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// Team ID of a signed bundle, or nil (ad-hoc or unsigned).
    public static func teamIdentifier(of url: URL) -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return nil }
        return dict[kSecCodeInfoTeamIdentifier as String] as? String
    }

    /// Write the script and start it detached. The caller quits right after.
    public static func startInstall(dmg: URL, app: URL, team: String) throws {
        let stamp = Int(Date().timeIntervalSince1970)
        let script = FileManager.default.temporaryDirectory.appendingPathComponent("ccop-update-\(stamp).sh")
        let log = logsDir.appendingPathComponent("update-\(stamp).log")
        let text = installScript(dmg: dmg, dest: app, pid: ProcessInfo.processInfo.processIdentifier, team: team, log: log)
        try text.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [script.path]
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
    }
}
