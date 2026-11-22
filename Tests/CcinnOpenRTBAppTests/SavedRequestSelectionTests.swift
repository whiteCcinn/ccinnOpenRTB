import AppKit
import Foundation
import Testing
@testable import CcinnOpenRTB

@Suite("Saved requests: selection")
struct SavedRequestSelectionTests {
    private func listed(_ names: String...) -> [SavedRequest] {
        names.enumerated().map { offset, name in
            let date = Date(timeIntervalSince1970: 1_800_000_000 - Double(offset))
            return SavedRequest(id: UUID(), name: name, createdAt: date, updatedAt: date,
                                request: ClientRequest(url: "https://ssp.example/openrtb2/auction"), exchange: nil)
        }
    }

    /// Bulk actions act on the selected requests the user can see, in the order the list shows them.
    @Test func targetsAreTheListedSelectedRequestsInListOrder() {
        let requests = listed("A", "B", "C", "D")
        let hidden = UUID()

        let targets = SavedRequestSelection.targets([requests[3].id, hidden, requests[1].id], in: requests)

        #expect(targets.map(\.name) == ["B", "D"])
        #expect(SavedRequestSelection.targets([], in: requests).isEmpty)
        #expect(SavedRequestSelection.targets([hidden], in: requests).isEmpty)
    }

    /// The search hid a row, or another window deleted it: it leaves the selection.
    @Test func theSelectionKeepsOnlyListedRows() {
        let requests = listed("A", "B", "C")
        let hidden = UUID()

        let pruned = SavedRequestSelection.pruned([requests[0].id, hidden, requests[2].id], to: requests)

        #expect(pruned == [requests[0].id, requests[2].id])
        #expect(SavedRequestSelection.pruned([hidden], to: []).isEmpty)
    }

    /// The modifiers of a mouse click (raw `NSEvent.ModifierFlags`) and whether it opens the request.
    private static let clicks: [(modifiers: UInt, opens: Bool)] = [
        (0, true),
        (NSEvent.ModifierFlags.capsLock.rawValue, true),
        (NSEvent.ModifierFlags.option.rawValue, true),
        (NSEvent.ModifierFlags.function.rawValue, true),
        (NSEvent.ModifierFlags.command.rawValue, false),
        (NSEvent.ModifierFlags.shift.rawValue, false),
        (NSEvent.ModifierFlags.control.rawValue, false),
        (NSEvent.ModifierFlags([.command, .shift]).rawValue, false),
        (NSEvent.ModifierFlags([.capsLock, .command]).rawValue, false),
    ]

    /// ⌘ adds or removes a row, ⇧ selects a range and ⌃ is a right click: those select; any other click opens.
    @Test(arguments: clicks)
    func onlyAPlainClickOpens(modifiers: UInt, opens: Bool) {
        let flags = NSEvent.ModifierFlags(rawValue: modifiers)
        #expect(SavedRequestSelection.activationOpens(.leftMouseUp, modifiers: flags) == opens)
        #expect(SavedRequestSelection.activationOpens(.leftMouseDown, modifiers: flags) == opens)
    }

    /// VoiceOver presses a row with ⌃⌥Space (a key event), or with no event at all: it opens, whatever is held.
    @Test func anActivationThatIsNotAClickOpens() {
        #expect(SavedRequestSelection.activationOpens(.keyDown, modifiers: [.control, .option]))
        #expect(SavedRequestSelection.activationOpens(nil, modifiers: []))
        #expect(SavedRequestSelection.activationOpens(.rightMouseUp, modifiers: .control))
    }

    @Test func theConfirmationNamesOneRequestAndCountsSeveral() {
        let one = SavedRequestSelection.confirmation(deleting: listed("G24 · 2 Banner"))
        #expect(one == .init(title: "Delete the saved request?", button: "Delete “G24 · 2 Banner”",
                             message: "Its request and saved response are removed from disk."))

        let three = SavedRequestSelection.confirmation(deleting: listed("A", "B", "C"))
        #expect(three == .init(title: "Delete 3 saved requests?", button: "Delete 3 Requests",
                               message: "Their requests and saved responses are removed from disk."))
    }

    @Test func theFooterCountsTheSelectionAgainstTheList() {
        #expect(SavedRequestSelection.summary(selected: 2, listed: 7) == "2 of 7 selected")
        #expect(SavedRequestSelection.summary(selected: 1, listed: 1) == "1 of 1 selected")
    }

    @Test func theMenuCountsSeveralRequests() {
        #expect(SavedRequestSelection.deleteMenuTitle(count: 1) == "Delete…")
        #expect(SavedRequestSelection.deleteMenuTitle(count: 4) == "Delete 4 Requests…")
    }
}
