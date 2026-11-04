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
                    FlowRows(spacing: 8, lineSpacing: 8) {
                        ForEach(causes) { c in chip(c, on: c.id == cause.id) }
                    }
                    summary(cause)
                    CallList(anatomy: anatomy, items: anatomy.calls(of: cause), shownCall: $shownCall)
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

    private func chip(_ c: Cause, on: Bool) -> some View {
        // The chip that is on adds no step to Back and Forward.
        Button { if !on { model.causeID = c.id } } label: {
            HStack(spacing: 6) {
                Text(c.title)
                Text(Format.dollars(c.costMicros)).monospacedDigit().opacity(0.7)
            }
            .font(.system(size: 12))
            .lineLimit(1)
            .foregroundStyle(on ? Theme.dynamic(0xFFFFFF, 0x1D1D1F) : Color.primary)
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(Capsule().fill(on ? Theme.dynamic(0x1D1D1F, 0xF2F2F7) : Theme.bg))
            .overlay(Capsule().strokeBorder(on ? Color.clear : Theme.line))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func summary(_ c: Cause) -> some View {
        var facts = ["\(Format.percent(anatomy.spend.share(c.costMicros))) of the session"]
        if c.count > 0 { facts.append("\(c.count) \(c.count == 1 ? "call" : "calls")" + (c.errors > 0 ? ", \(c.errors) failed" : "")) }
        facts.append("\(Int(c.modelCalls.rounded())) model calls after them")
        if c.avgContext > 0 { facts.append("\(Format.tokens(c.avgContext)) context on average") }
        if c.addedTokens > 0 { facts.append("\(Format.tokens(c.addedTokens)) added to the context (estimated)") }
        return HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(Format.dollars(c.costMicros)).font(.system(size: 22, weight: .semibold)).monospacedDigit()
            Text(c.title).font(.system(size: 13, weight: .semibold))
            Text(facts.joined(separator: " · "))
                .font(.system(size: 12)).monospacedDigit().foregroundStyle(Theme.text3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
