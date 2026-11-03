import CCOPKit
import SwiftUI

/// A button with the chosen folder. A click opens a panel with a search
/// field and a scrolling list of the folders of the period.
struct FolderPicker: View {
    @Environment(AppModel.self) private var model
    /// Inside the sidebar's search field: small grey text, no border.
    var inField = false
    @State private var open = false

    var body: some View {
        let choices = model.folderChoices
        Button { open.toggle() } label: {
            if inField {
                HStack(spacing: 4) {
                    Text(title(choices)).lineLimit(1).truncationMode(.middle)
                    Image(systemName: "chevron.down").font(.system(size: 7.5, weight: .bold))
                }
                .font(.ui(11))
                .foregroundStyle(Theme.text2)
                .frame(maxWidth: 140, alignment: .trailing)
                .contentShape(Rectangle())
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "folder").font(.system(size: 12))
                    Text(title(choices)).lineLimit(1).truncationMode(.middle)
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
                }
                .font(.ui(12))
                .foregroundStyle(Theme.text)
                .padding(.horizontal, 8)
                .frame(height: 26)
                .background(Theme.bg, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.line))
                .contentShape(Rectangle())
            }
        }
        .buttonStyle(.plain)
        .fixedSize(horizontal: !inField, vertical: false)
        .help(model.folder ?? "Show the sessions of one project folder")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            FolderList(choices: choices, selected: model.folder) { path in
                model.folder = path
                open = false
            }
        }
    }

    /// The chosen folder's name, at most 26 characters (cut in the middle).
    private func title(_ choices: [FolderChoice]) -> String {
        guard let folder = model.folder else { return "All folders" }
        let name = choices.first { $0.path == folder }?.label ?? folder
        guard name.count > 26 else { return name }
        return name.prefix(12) + "…" + name.suffix(13)
    }
}

/// The panel: type to narrow the list; up and down arrows move, Return picks,
/// Escape closes.
private struct FolderList: View {
    let choices: [FolderChoice]
    let selected: String?
    let pick: (String?) -> Void

    @State private var search = ""
    @State private var highlight = 0
    @FocusState private var focused: Bool

    private struct Row: Identifiable {
        /// "" for All folders, else the path.
        let id: String
        let path: String?
        let label: String
        let sessions: Int
    }

    private static let rowHeight: CGFloat = 26

    private var rows: [Row] {
        var out: [Row] = []
        if search.trimmingCharacters(in: .whitespaces).isEmpty {
            out.append(Row(id: "", path: nil, label: "All folders", sessions: choices.reduce(0) { $0 + $1.sessions }))
        }
        out += SessionList.matching(choices, search: search)
            .map { Row(id: $0.path, path: $0.path, label: $0.label, sessions: $0.sessions) }
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
                        if rows.indices.contains(highlight) { pick(rows[highlight].path) }
                    }
                    .onKeyPress(.downArrow) { move(1, rows, proxy) }
                    .onKeyPress(.upArrow) { move(-1, rows, proxy) }
                    .onChange(of: search) { highlight = 0 }
                Divider()
                if rows.isEmpty {
                    Text("No folders match").foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(12)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(rows.enumerated()), id: \.element.id) { i, row in
                                rowView(row, highlighted: i == highlight)
                                    .id(row.id)
                                    .onTapGesture { pick(row.path) }
                                    .onHover { if $0 { highlight = i } }
                            }
                        }
                        .padding(4)
                    }
                    .frame(height: min(CGFloat(rows.count) * Self.rowHeight + 8, 340))
                }
            }
            .frame(width: 300)
            .onAppear {
                focused = true
                highlight = rows.firstIndex { $0.path == selected } ?? 0
                let id = rows.indices.contains(highlight) ? rows[highlight].id : ""
                DispatchQueue.main.async { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }

    private func move(_ by: Int, _ rows: [Row], _ proxy: ScrollViewProxy) -> KeyPress.Result {
        guard !rows.isEmpty else { return .handled }
        highlight = min(max(highlight + by, 0), rows.count - 1)
        proxy.scrollTo(rows[highlight].id)
        return .handled
    }

    private func rowView(_ row: Row, highlighted: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark")
                .font(.caption.weight(.semibold))
                .opacity(row.path == selected ? 1 : 0)
                .frame(width: 12)
            Text(row.label).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 8)
            Text("\(row.sessions)").monospacedDigit().foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .frame(height: Self.rowHeight)
        .background(highlighted ? Color.accentColor.opacity(0.2) : .clear, in: RoundedRectangle(cornerRadius: 5))
        .contentShape(Rectangle())
        .help(row.path ?? "Sessions of every folder")
    }
}
