import SwiftTerm

/// Tracks the unseen-completion dot for one terminal session.
///
/// SwiftTerm hands over the whole OSC 7501 store on every change, so the dot comes from the
/// folded state *changing* into a finished one; the presence of a `.done` record is not itself
/// an event. A terminal can hold several records at once (nested or anonymous ids), and
/// `.blocked` outranks `.done` because a program waiting on the user is the more urgent fact.
/// No records means the store was emptied (process exit), which counts as a change away from
/// finished rather than an error.
struct TerminalAttention: Equatable {
    private(set) var needsAttention = false
    private var lastState: TerminalProgramStatusState?

    /// Returns true when the dot changed, i.e. when the tab bar needs a repaint.
    @discardableResult
    mutating func update(records: [TerminalProgramStatus], isSelected: Bool) -> Bool {
        update(states: records.map(\.state), isSelected: isSelected)
    }

    @discardableResult
    mutating func update(states: [TerminalProgramStatusState], isSelected: Bool) -> Bool {
        let state = Self.aggregate(states)
        defer { lastState = state }
        // Selection clears the dot but leaves `lastState` at the finished value, so a repeated
        // snapshot of the same state cannot re-light it after the user switches away again.
        guard !isSelected, state != lastState, state == .done || state == .blocked, !needsAttention else { return false }
        needsAttention = true
        return true
    }

    mutating func clear() {
        needsAttention = false
    }

    static func aggregate(_ states: [TerminalProgramStatusState]) -> TerminalProgramStatusState? {
        if states.contains(.blocked) { return .blocked }
        if states.contains(.done) { return .done }
        return states.last
    }
}
