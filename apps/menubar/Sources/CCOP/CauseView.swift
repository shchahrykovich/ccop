import CCOPKit
import SwiftUI

/// The Cause tab: one cause of the session's cost, with each call behind it.
/// The Spend tab's "By cause" rows open it at their cause.
struct CauseView: View {
    @Environment(AppModel.self) private var model
    let anatomy: Anatomy
    @State private var shownCall: CallRef?

    var body: some View {
        let causes = anatomy.spend.shownCauses
        let cause = causes.first { $0.id == model.causeID } ?? causes.first
        PageScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let cause {
                    groups(anatomy.spend.causeGroups, chosen: cause)
                    summary(cause)
                    CallList(anatomy: anatomy, items: cause.items, shownCall: $shownCall)
                        .id(cause.id)
                } else {
                    Text("This session has no model calls with a cost.")
                        .font(.system(size: 13)).foregroundStyle(Theme.text3)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.top, 18)
            .padding(.bottom, 24)
        }
        .sheet(item: $shownCall) { ref in
            if let lane = anatomy.lane(ref.lane), lane.events.indices.contains(ref.index) {
                CallSheet(sessionID: anatomy.sessionId, lane: lane, index: ref.index)
            }
        }
    }

    /// One row per server, in one card: the name of the group on the left, its
    /// causes on the right. The group says the server, so a chip says only `get_page`.
    private func groups(_ groups: [CauseGroup], chosen: Cause) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(groups.enumerated()), id: \.element.id) { i, group in
                if i > 0 { Rectangle().fill(Theme.line).frame(height: 1) }
                HStack(alignment: .top, spacing: 14) {
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 5) {
                            Text(group.title).font(.system(size: 12, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                            if group.isMCP { mcpBadge }
                        }
                        Text(Format.dollars(group.costMicros)).font(.system(size: 11)).monospacedDigit().foregroundStyle(Theme.text3)
                    }
                    .frame(width: 160, alignment: .leading)
                    .help(group.isMCP ? "MCP server \(group.title)" : "Claude Code's own tools, your messages and compactions")
                    VStack(alignment: .leading, spacing: 8) {
                        if let about = group.about {
                            Text(about)
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.text3)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                        FlowRows(spacing: 6, lineSpacing: 6) {
                            ForEach(group.causes) { c in chip(c, on: c.id == chosen.id) }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
        }
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.line))
    }

    /// Says that a group's name is an MCP server, not a part of Claude Code.
    private var mcpBadge: some View {
        Text("MCP")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(Theme.text3)
            .padding(.horizontal, 4)
            .frame(height: 14)
            .background(RoundedRectangle(cornerRadius: 3).fill(Theme.line))
            .fixedSize()
    }

    private func chip(_ c: Cause, on: Bool) -> some View {
        let look = c.look
        // The chip that is on adds no step to Back and Forward.
        return Button { if !on { model.causeID = c.id } } label: {
            HStack(spacing: 5) {
                Image(systemName: look.symbol)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(on ? Theme.dynamic(0xFFFFFF, 0x1D1D1F) : look.icon)
                    .frame(width: 14)
                    .accessibilityHidden(true)
                Text(c.shortTitle)
                Text(Format.dollars(c.costMicros)).monospacedDigit().opacity(0.6)
            }
            .font(.system(size: 12))
            .lineLimit(1)
            .foregroundStyle(on ? Theme.dynamic(0xFFFFFF, 0x1D1D1F) : Color.primary)
            .padding(.leading, 7)
            .padding(.trailing, 9)
            .frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 7).fill(on ? Theme.dynamic(0x1D1D1F, 0xF2F2F7) : Theme.bg))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(on ? Color.clear : Theme.line))
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help(anatomy.spend.help(c))
        .accessibilityLabel(c.title)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func summary(_ c: Cause) -> some View {
        var facts = ["\(Format.percent(anatomy.spend.share(c.costMicros))) of the session"]
        if c.count > 0 { facts.append("\(c.count) \(c.count == 1 ? "call" : "calls")" + (c.errors > 0 ? ", \(c.errors) failed" : "")) }
        facts.append("\(Int(c.modelCalls.rounded())) model calls after them")
        if c.avgContext > 0 { facts.append("\(Format.tokens(c.avgContext)) context on average") }
        if c.addedTokens > 0 { facts.append("\(Format.tokens(c.addedTokens)) added to the context (estimated)") }
        let look = c.look
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: look.symbol)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(look.icon)
                .frame(width: 40, height: 40)
                .background(look.tile, in: RoundedRectangle(cornerRadius: 9))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(Format.dollars(c.costMicros)).font(.system(size: 22, weight: .semibold)).monospacedDigit()
                    Text(c.title).font(.system(size: 13, weight: .semibold)).textSelection(.enabled)
                }
                if let description = c.description, !description.isEmpty {
                    Text(description)
                        .font(.system(size: 12.5))
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                Text(facts.joined(separator: " · "))
                    .font(.system(size: 12)).monospacedDigit().foregroundStyle(Theme.text3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
