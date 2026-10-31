import SwiftUI

// Friction marks (PLAN-logbook-v2 B5): on cards, on turns, and in a strip
// beside the transcript's scroll bar.

/// How a §4.3 signal kind looks.
struct LogbookSignalKind {
    let name: String
    let symbol: String
    let color: Color

    init(_ kind: String) {
        (name, symbol, color) = switch kind {
        case "interrupt": ("Interrupted", "bolt.fill", .orange)
        case "denied": ("Tool denied", "hand.raised.fill", .orange)
        case "correction": ("Corrected", "arrow.uturn.backward", .orange)
        case "tool-error": ("Tool failed", "xmark.octagon", .red)
        case "repeat-error": ("Failed again and again", "arrow.triangle.2.circlepath", .red)
        case "asked-needlessly": ("Asked instead of doing", "questionmark.bubble", .yellow)
        case "compact": ("Compacted", "rectangle.compress.vertical", .secondary)
        default: (kind, "exclamationmark.circle", .secondary)
        }
    }

    /// The owner's own friction first, then tool failures, then the rest.
    static let order = ["interrupt", "denied", "correction", "asked-needlessly", "repeat-error", "tool-error", "compact"]
}

/// A symbol and count per kind ("⚡2 ✋1 ⊗5"); nothing without friction.
struct LogbookFrictionMarks: View {
    let friction: [String: Int]

    var body: some View {
        let kinds = friction.filter { $0.value > 0 }.sorted {
            (LogbookSignalKind.order.firstIndex(of: $0.key) ?? 99, $0.key) < (LogbookSignalKind.order.firstIndex(of: $1.key) ?? 99, $1.key)
        }
        if !kinds.isEmpty {
            HStack(spacing: 6) {
                ForEach(kinds, id: \.key) { kind, count in
                    let look = LogbookSignalKind(kind)
                    HStack(spacing: 1) {
                        Image(systemName: look.symbol)
                        Text("\(count)").monospacedDigit()
                    }
                    .foregroundStyle(look.color)
                    .help("\(count) × \(look.name.lowercased())")
                }
            }
        }
    }
}

/// Beside the scroll bar: a tick per loaded turn with friction, at its
/// place among the turns. A click jumps to the turn.
struct LogbookFrictionStrip: View {
    let turns: [String]
    let signals: [LogbookSignal]
    let jump: (String) -> Void

    var body: some View {
        let index = Dictionary(turns.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        let marked = Dictionary(grouping: signals.filter { index[$0.turn] != nil }, by: \.turn)
        if !marked.isEmpty {
            GeometryReader { geo in
                ForEach(Array(marked.keys), id: \.self) { turn in
                    let list = marked[turn] ?? []
                    let first = LogbookSignalKind.order.first { kind in list.contains { $0.kind == kind } } ?? list[0].kind
                    let y = turns.count > 1 ? CGFloat(index[turn]!) / CGFloat(turns.count - 1) : 0
                    Capsule()
                        .fill(LogbookSignalKind(first).color)
                        .frame(width: 6, height: 10)
                        .frame(width: 14, height: 16)
                        .contentShape(Rectangle())
                        .position(x: 7, y: 8 + y * max(geo.size.height - 16, 0))
                        .onTapGesture { jump(turn) }
                        .help(list.map { LogbookSignalKind($0.kind).name + ": " + $0.excerpt }.joined(separator: "\n"))
                }
            }
            .frame(width: 14)
            .padding(.vertical, 4)
            .padding(.trailing, 12)
        }
    }
}
