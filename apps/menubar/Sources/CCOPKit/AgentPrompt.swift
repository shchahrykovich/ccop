import Foundation

/// What Copy for Agent puts on the clipboard: the guide for agents (`ccop
/// guide`) and the one session to look at. You paste it and add your question.
public enum AgentPrompt {
    public static func text(guide: String, session: Session, cli: String?) -> String {
        var out = guide.trimmingCharacters(in: .whitespacesAndNewlines)
        out += "\n\n## This session\n\n"
        out += "Look at session `\(session.id)`, \"\(session.title)\", in `\(session.projectDir)`. "
        out += "Start with `ccop brief \(session.id)`.\n"
        if let cli {
            out += "\nThis app's `ccop` is \(Resume.shellQuote(cli)). Use it if `ccop` is not found.\n"
        }
        return out
    }
}
