import Foundation

/// What a double click on a title bar does, from System Settings › Desktop &
/// Dock › "Double-click a window's title bar to". The main window draws its
/// own content over the title bar, so it runs this itself.
public enum TitleBarAction: Equatable, Sendable {
    case zoom, minimize, nothing

    /// `action`: the global default `AppleActionOnDoubleClick` ("Maximize",
    /// "Fill", "Minimize", "None"); absent until the user changes it.
    /// `miniaturize`: the older `AppleMiniaturizeOnDoubleClick`, used only
    /// when `action` is absent.
    public static func from(action: String?, miniaturize: Bool) -> TitleBarAction {
        switch action {
        case "Minimize": .minimize
        case "None": .nothing
        case nil: miniaturize ? .minimize : .zoom
        default: .zoom
        }
    }

    /// The user's choice now.
    public static var current: TitleBarAction {
        let g = UserDefaults.standard
        return from(action: g.string(forKey: "AppleActionOnDoubleClick"),
                    miniaturize: g.bool(forKey: "AppleMiniaturizeOnDoubleClick"))
    }
}
