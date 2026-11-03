import Foundation

/// Numbers for the session views that only the anatomy has: the cost of each
/// model, the time of the first and last prompt, and the context size.
extension Anatomy {
    /// API-equivalent cost of each model's calls, in all lanes. Only model
    /// calls count: a prompt's or a tool's cost is a share of a call's.
    public var costByModel: [String: UInt64] {
        var out: [String: UInt64] = [:]
        for lane in lanes {
            for e in lane.events where e.kind == .answer {
                guard let model = e.model ?? lane.model, let c = e.costMicros else { continue }
                out[model, default: 0] += c
            }
        }
        return out
    }

    /// API-equivalent cost of the calls of all subagents.
    public var subagentCostMicros: UInt64 {
        lanes.filter { $0.id != "main" }.reduce(0) { sum, lane in
            sum + lane.events.filter { $0.kind == .answer }.compactMap(\.costMicros).reduce(0, +)
        }
    }

    /// When the first and the last prompt of the main lane were typed.
    public var promptTimes: (first: Date, last: Date)? {
        guard let prompts = lane("main")?.events.filter({ $0.kind == .prompt }),
              let first = prompts.first, let last = prompts.last else { return nil }
        return (first.start, last.start)
    }

    /// The average and largest context of the main lane's model calls.
    public var contextSize: (average: UInt64, max: UInt64)? {
        guard let points = lane("main")?.context, !points.isEmpty else { return nil }
        let sum = points.reduce(UInt64(0)) { $0 + $1.total }
        return (sum / UInt64(points.count), points.map(\.total).max() ?? 0)
    }
}
