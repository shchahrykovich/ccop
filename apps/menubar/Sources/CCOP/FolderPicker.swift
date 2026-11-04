import CCOPKit
import SwiftUI

/// A button with the chosen folder, inside the search field: small grey text,
/// no border. A click opens a panel with a search field and a scrolling list
/// of the folders of the period.
struct FolderPicker: View {
    @Environment(AppModel.self) private var model
    @State private var open = false

    var body: some View {
        let choices = model.folderChoices
        Button { open.toggle() } label: {
            HStack(spacing: 4) {
                Text(title(choices)).lineLimit(1).truncationMode(.middle)
                Image(systemName: "chevron.down").font(.system(size: 7.5, weight: .bold))
            }
            .font(.ui(11))
            .foregroundStyle(Theme.text2)
            .frame(maxWidth: 140, alignment: .trailing)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(model.folder?.path ?? "Show the sessions of one project folder")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            FolderList(tree: SessionList.folderTree(choices), selected: model.folder) { scope in
                model.folder = scope
                open = false
            }
        }
    }

    /// "All folders", a folder's name, "<name> + subfolders" or "<name>
    /// only" (a folder that has subfolders, without them). The name is at
    /// most 26 characters, cut in the middle.
    private func title(_ choices: [FolderChoice]) -> String {
        guard let folder = model.folder else { return "All folders" }
        let name = Self.short(choices.first { $0.path == folder.path }?.label ?? folder.path)
        let hasSubfolders = choices.contains { $0.path.hasPrefix(folder.path + "/") }
        guard hasSubfolders else { return name }
        switch folder {
        case .withSubfolders: return name + " + subfolders"
        case .only: return name + " only"
        }
    }

    static func short(_ name: String) -> String {
        name.count > 26 ? name.prefix(12) + "…" + name.suffix(13) : name
    }
}

/// The panel: type to narrow the list; up and down arrows move, right and
/// left open and close a folder, Return picks, Escape closes.
///
/// A folder with subfolders (such as worktrees in .claude/worktrees) is one
/// row: a click picks it with all its subfolders. Its arrow opens it to pick
/// the folder alone or one subfolder.
private struct FolderList: View {
    let tree: [FolderNode]
    let selected: FolderScope?
    let pick: (FolderScope?) -> Void

    @State private var search = ""
    @State private var highlight = 0
    @State private var expanded: Set<String> = []
    @FocusState private var focused: Bool

    private enum Kind {
        case all(Int)
        case folder(FolderNode)
        case only(FolderNode)
        case sub(FolderNode, FolderChoice)
    }

    private struct Row: Identifiable {
        let id: String
        let kind: Kind
        let scope: FolderScope?
    }

    private static let rowHeight: CGFloat = 26

    private var searching: Bool { !search.trimmingCharacters(in: .whitespaces).isEmpty }

    private var rows: [Row] {
        var out: [Row] = []
        if !searching {
            out.append(Row(id: "", kind: .all(tree.reduce(0) { $0 + $1.total }), scope: nil))
        }
        for node in SessionList.matching(tree, search: search) {
            let path = node.folder.path
            if node.subfolders.isEmpty {
                out.append(Row(id: "f:" + path, kind: .folder(node), scope: .only(path)))
                continue
            }
            out.append(Row(id: "t:" + path, kind: .folder(node), scope: .withSubfolders(path)))
            if searching || expanded.contains(path) {
                out.append(Row(id: "o:" + path, kind: .only(node), scope: .only(path)))
                for sub in node.subfolders {
                    out.append(Row(id: "s:" + sub.path, kind: .sub(node, sub), scope: .only(sub.path)))
                }
            }
        }
        return out
    }

    var body: some View {
        let rows = rows
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                TextField("Search folders", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .padding(8)
                    .onSubmit {
                        if rows.indices.contains(highlight) { pick(rows[highlight].scope) }
                    }
                    .onKeyPress(.downArrow) { move(1, rows, proxy) }
                    .onKeyPress(.upArrow) { move(-1, rows, proxy) }
                    .onKeyPress(.rightArrow) { setOpen(true, rows) }
                    .onKeyPress(.leftArrow) { setOpen(false, rows) }
                    .onChange(of: search) { highlight = 0 }
                Rectangle().fill(Theme.line).frame(height: 1)
                if rows.isEmpty {
                    Text("No folders match").foregroundStyle(Theme.text3)
                        .frame(maxWidth: .infinity)
                        .padding(12)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(rows.enumerated()), id: \.element.id) { i, row in
                                rowView(row, highlighted: i == highlight)
                                    .id(row.id)
                                    .onTapGesture { pick(row.scope) }
                                    .onHover { if $0 { highlight = i } }
                            }
                        }
                        .padding(4)
                    }
                    .frame(height: min(CGFloat(rows.count) * Self.rowHeight + 8, 380))
                }
            }
            .frame(width: 360)
            .font(.ui(13))
            .foregroundStyle(Theme.text)
            .onAppear {
                // Open the folder that holds the choice, so the choice shows.
                if let selected, let node = tree.first(where: { node in
                    node.subfolders.contains { $0.path == selected.path }
                        || (node.folder.path == selected.path && selected == .only(selected.path) && !node.subfolders.isEmpty)
                }) {
                    expanded.insert(node.folder.path)
                }
                focused = true
                let rows = self.rows
                highlight = rows.firstIndex { isChosen($0) } ?? 0
                let id = rows.indices.contains(highlight) ? rows[highlight].id : ""
                DispatchQueue.main.async { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }

    private func isChosen(_ row: Row) -> Bool {
        guard let selected else { return row.scope == nil }
        if case let .folder(node) = row.kind, node.subfolders.isEmpty { return node.folder.path == selected.path }
        return row.scope == selected
    }

    private func move(_ by: Int, _ rows: [Row], _ proxy: ScrollViewProxy) -> KeyPress.Result {
        guard !rows.isEmpty else { return .handled }
        highlight = min(max(highlight + by, 0), rows.count - 1)
        proxy.scrollTo(rows[highlight].id)
        return .handled
    }

    /// Right opens the highlighted folder; left closes it, or goes from an
    /// inner row back to its folder.
    private func setOpen(_ open: Bool, _ rows: [Row]) -> KeyPress.Result {
        guard !searching, rows.indices.contains(highlight) else { return .ignored }
        switch rows[highlight].kind {
        case let .folder(node) where !node.subfolders.isEmpty:
            if open { expanded.insert(node.folder.path) } else { expanded.remove(node.folder.path) }
            return .handled
        case let .only(node), let .sub(node, _):
            guard !open else { return .ignored }
            expanded.remove(node.folder.path)
            highlight = self.rows.firstIndex { $0.id == "t:" + node.folder.path } ?? 0
            return .handled
        default:
            return .ignored
        }
    }

    @ViewBuilder
    private func rowView(_ row: Row, highlighted: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark")
                .font(.system(size: 10, weight: .semibold))
                .opacity(isChosen(row) ? 1 : 0)
                .frame(width: 12)
            switch row.kind {
            case let .all(count):
                Text("All folders")
                Spacer(minLength: 8)
                countText(count)
            case let .folder(node):
                if node.subfolders.isEmpty {
                    Color.clear.frame(width: 12, height: 1)
                } else {
                    let open = searching || expanded.contains(node.folder.path)
                    Button {
                        if open { expanded.remove(node.folder.path) } else { expanded.insert(node.folder.path) }
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Theme.text2)
                            .rotationEffect(.degrees(open ? 90 : 0))
                            .frame(width: 12, height: Self.rowHeight)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(searching)
                    .help(open ? "Hide the subfolders" : "Show the subfolders, to pick one or the folder alone")
                }
                Text(node.folder.label).lineLimit(1).truncationMode(.middle)
                if !node.subfolders.isEmpty {
                    Text("+ \(node.subfolders.count) sub").font(.ui(11)).foregroundStyle(Theme.text3).fixedSize()
                }
                Spacer(minLength: 8)
                countText(node.total)
            case let .only(node):
                Color.clear.frame(width: 26, height: 1)
                Text("Only \(node.folder.label)").lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 8)
                countText(node.folder.sessions)
            case let .sub(node, sub):
                Color.clear.frame(width: 26, height: 1)
                subLabel(node.relativePath(of: sub))
                Spacer(minLength: 8)
                countText(sub.sessions)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: Self.rowHeight)
        .background(highlighted ? Theme.accent.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 5))
        .contentShape(Rectangle())
        .help(help(row))
    }

    /// `.claude/worktrees/` in grey, then the folder's own name.
    private func subLabel(_ relative: String) -> some View {
        let name = (relative as NSString).lastPathComponent
        let prefix = String(relative.dropLast(name.count))
        return (Text(prefix).foregroundStyle(Theme.text3) + Text(name))
            .lineLimit(1).truncationMode(.head)
    }

    private func countText(_ n: Int) -> some View {
        Text("\(n)").monospacedDigit().foregroundStyle(Theme.text3)
    }

    private func help(_ row: Row) -> String {
        switch row.kind {
        case .all: "Sessions of every folder"
        case let .folder(node):
            node.subfolders.isEmpty ? node.folder.path : "\(node.folder.path) and its \(node.subfolders.count) subfolder\(node.subfolders.count == 1 ? "" : "s")"
        case let .only(node): "\(node.folder.path) alone, without its subfolders"
        case let .sub(_, sub): sub.path
        }
    }
}
