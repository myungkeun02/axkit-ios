import Foundation

/// The 홈 room list (left sheet). It opens only from its button — no dragging — and a room changes only when one
/// is tapped while the list is open. The old drag-to-open sheet switched rooms when a drag ended over a row and
/// could stay half open when iOS cancelled the drag; this keeps the rule in one small, tested place.
public struct RoomPicker: Equatable, Sendable {
    public private(set) var isOpen = false

    public init() {}

    public mutating func open() { isOpen = true }
    public mutating func close() { isOpen = false }

    /// A tap on a room ("" = the assistant). Closes the list and returns the rooms to stack ([] = the assistant),
    /// or nil when the list was already closed — a late tap must not change the chat.
    public mutating func pick(_ room: String) -> [String]? {
        guard isOpen else { return nil }
        isOpen = false
        return room.isEmpty ? [] : [room]
    }
}
