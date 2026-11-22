import AppKit
import Foundation

/// The Saved list's multiple selection, as plain values (tested without views).
///
/// The list keeps the standard macOS selection (⌘-click, ⇧-click, ⌘A, arrow keys) while a plain click still opens a
/// request. Every bulk action works on `targets`: the selected requests that are listed, never one the search hides.
enum SavedRequestSelection {
    /// A click with one of these selects instead of opening: ⌘ adds or removes a row, ⇧ selects a range, ⌃ is a right click.
    static let selectingModifiers: NSEvent.ModifierFlags = [.command, .shift, .control]

    /// Whether activating a row opens it. Only a mouse click's modifiers can make it select instead: any other activation
    /// (VoiceOver presses with ⌃⌥Space, an accessibility action without an event) opens, as it always did.
    static func activationOpens(_ eventType: NSEvent.EventType?, modifiers: NSEvent.ModifierFlags) -> Bool {
        guard let eventType, eventType == .leftMouseUp || eventType == .leftMouseDown else { return true }
        return modifiers.isDisjoint(with: selectingModifiers)
    }

    /// The listed requests whose id is selected, in list order.
    static func targets(_ selection: Set<UUID>, in listed: [SavedRequest]) -> [SavedRequest] {
        guard !selection.isEmpty else { return [] }
        return listed.filter { selection.contains($0.id) }
    }

    /// The selection without the rows that are no longer listed (hidden by the search, or deleted).
    static func pruned(_ selection: Set<UUID>, to listed: [SavedRequest]) -> Set<UUID> {
        guard !selection.isEmpty else { return selection }
        return selection.intersection(listed.lazy.map(\.id))
    }

    static func summary(selected: Int, listed: Int) -> String {
        "\(selected) of \(listed) selected"
    }

    static func deleteMenuTitle(count: Int) -> String {
        count == 1 ? "Delete…" : "Delete \(count) Requests…"
    }

    struct Confirmation: Equatable {
        var title: String
        var button: String
        var message: String
    }

    /// Asking before deleting `requests` (one or more).
    static func confirmation(deleting requests: [SavedRequest]) -> Confirmation {
        if requests.count == 1, let only = requests.first {
            return Confirmation(title: "Delete the saved request?", button: "Delete “\(only.name)”",
                                message: "Its request and saved response are removed from disk.")
        }
        return Confirmation(title: "Delete \(requests.count) saved requests?", button: "Delete \(requests.count) Requests",
                            message: "Their requests and saved responses are removed from disk.")
    }
}
