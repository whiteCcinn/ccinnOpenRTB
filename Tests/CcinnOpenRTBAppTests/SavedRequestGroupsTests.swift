import CcinnOpenRTBKit
import Foundation
import Testing
@testable import CcinnOpenRTB

private func saved(_ name: String, group: String? = nil, at seconds: TimeInterval = 1_800_000_000, id: UUID = UUID()) -> SavedRequest {
    let date = Date(timeIntervalSince1970: seconds)
    return SavedRequest(id: id, name: name, createdAt: date, updatedAt: date,
                        request: ClientRequest(url: "https://ssp.example/openrtb2/auction", body: #"{"id":"1"}"#), exchange: nil, group: group)
}

// MARK: - Names and sections

@Suite("Saved requests: groups")
struct SavedRequestGroupsTests {
    @Test func namesAreTrimmedCollapsedAndCapped() {
        #expect(SavedRequestGroups.normalized("  G24  ") == "G24")
        #expect(SavedRequestGroups.normalized("G24\n smoke\ttests") == "G24 smoke tests")
        #expect(SavedRequestGroups.normalized("") == nil)
        #expect(SavedRequestGroups.normalized(" \n\t ") == nil)
        #expect(SavedRequestGroups.normalized(nil) == nil)
        #expect(SavedRequestGroups.normalized(String(repeating: "a", count: 200))?.count == SavedRequestGroups.maxNameLength)
        // Capped between two words: no trailing space.
        let capped = SavedRequestGroups.normalized(String(repeating: "a", count: 79) + " bcd")
        #expect(capped == String(repeating: "a", count: 79))
    }

    @Test func caseDoesNotMakeAnotherGroup() {
        #expect(SavedRequestGroups.key("G24") == SavedRequestGroups.key(" g24 "))
        #expect(SavedRequestGroups.key("G24") != SavedRequestGroups.key("G25"))
        #expect(SavedRequestGroups.key("   ") == nil)
    }

    /// Groups by name, members in list order (newest first), titled as the newest member spells it; "No Group" last.
    @Test func sectionsAreGroupsByNameThenTheUngrouped() {
        let requests = [saved("a", group: "G24"), saved("b"), saved("c", group: "Banner"), saved("d", group: "g24"), saved("e", group: " ")]

        let sections = SavedRequestGroups.sections(requests)

        #expect(sections.map(\.title) == ["Banner", "G24", "No Group"])
        #expect(sections.map { $0.requests.map(\.name) } == [["c"], ["a", "d"], ["b", "e"]])
        #expect(sections.map(\.key) == ["banner", "g24", nil])
        #expect(Set(sections.map(\.id)).count == 3)
        #expect(SavedRequestGroups.names(requests) == ["Banner", "G24"])
        #expect(SavedRequestGroups.hasGroups(requests))
        #expect(!SavedRequestGroups.hasGroups([saved("b"), saved("e", group: " ")]))
        #expect(SavedRequestGroups.sections([]).isEmpty)
    }

    @Test func aNewNameTakesTheSpellingOfTheGroupItJoins() {
        let requests = [saved("a", group: "G24"), saved("b", group: "Banner")]

        #expect(SavedRequestGroups.canonical(" g24 ", among: requests) == "G24")
        #expect(SavedRequestGroups.canonical("Video", among: requests) == "Video")
        #expect(SavedRequestGroups.canonical("  ", among: requests) == nil)
    }

    /// A folded group shows nothing (and so is never selected or deleted), unless a search shows every match.
    @Test func aFoldedGroupIsNotShownUnlessSearching() {
        let requests = [saved("a", group: "G24"), saved("b"), saved("c", group: "Banner")]
        let sections = SavedRequestGroups.sections(requests)
        let folded: Set<String> = [sections[1].id]

        #expect(SavedRequestGroups.visible(sections, collapsed: folded, expandAll: false).map(\.name) == ["c", "b"])
        #expect(SavedRequestGroups.visible(sections, collapsed: folded, expandAll: true).map(\.name) == ["c", "a", "b"])
        #expect(SavedRequestGroups.visible(sections, collapsed: [], expandAll: false).map(\.name) == ["c", "a", "b"])
    }

    /// A library without groups is the flat list it always was; with one, every match is in a section.
    @Test func theListIsFlatUntilAGroupExists() {
        let flat = SavedRequestGroups.listing([saved("a"), saved("b")], query: "", collapsed: ["ungrouped"])
        #expect(flat.sections == nil)
        #expect(flat.shown.map(\.name) == ["a", "b"])
        #expect(!flat.isEmpty)

        let library = [saved("alpha", group: "G24"), saved("beta"), saved("gamma", group: "G24")]
        let grouped = SavedRequestGroups.listing(library, query: "", collapsed: ["group:g24"])
        #expect(grouped.sections?.map(\.title) == ["G24", "No Group"])
        #expect(grouped.shown.map(\.name) == ["beta"])
        #expect(grouped.sections.map { grouped.isExpanded($0[0]) } == false)
        #expect(!grouped.isEmpty)

        // A search shows its matches in their sections, folded or not.
        let searching = SavedRequestGroups.listing(library, query: " gamma ", collapsed: ["group:g24"])
        #expect(searching.expandAll)
        #expect(searching.sections?.map(\.title) == ["G24"])
        #expect(searching.shown.map(\.name) == ["gamma"])
        #expect(SavedRequestGroups.listing(library, query: "zzz", collapsed: []).isEmpty)

        // Every section folded: nothing shown, but the headers are, so the list is not empty.
        let folded = SavedRequestGroups.listing(library, query: "", collapsed: ["group:g24", "ungrouped"])
        #expect(folded.shown.isEmpty)
        #expect(!folded.isEmpty)
    }

    @Test func foldingForgetsGroupsThatAreGone() {
        let library = [saved("a", group: "G24"), saved("b")]

        let folded = SavedRequestGroups.toggled("group:g24", in: ["group:old"], library: library)
        #expect(folded == ["group:g24"])
        #expect(SavedRequestGroups.toggled("group:g24", in: folded, library: library).isEmpty)
    }

    @Test func foldedGroupsAreRemembered() {
        let ids: Set<String> = ["group:g24", "ungrouped", "group:banner"]
        #expect(SavedRequestGroups.decodeCollapsed(SavedRequestGroups.encodeCollapsed(ids)) == ids)
        #expect(SavedRequestGroups.decodeCollapsed("").isEmpty)
        #expect(SavedRequestGroups.encodeCollapsed([]) == "")
    }

    @Test func theSearchFindsTheGroupName() {
        let requests = [saved("Banner 300×250", group: "G24 smoke"), saved("Video")]
        #expect(ClientPresentation.filter(requests, by: "smoke").map(\.name) == ["Banner 300×250"])
        #expect(ClientPresentation.filter(requests, by: "g24 banner").map(\.name) == ["Banner 300×250"])
    }
}

// MARK: - Files

@Suite("Saved requests: group on disk")
struct SavedRequestGroupFileTests {
    @Test func theGroupTravelsInAnExport() throws {
        let requests = [saved("A", group: "G24", at: 1_800_000_000), saved("B", at: 1_800_000_100)]
        let data = try SavedRequestArchive.encode(requests, exportedAt: Date(timeIntervalSince1970: 1_800_000_200), appVersion: "1.5.0")

        let decoded = try SavedRequestArchive.decode(data)

        #expect(decoded.requests == requests)
        #expect(decoded.requests.map(\.group) == ["G24", nil])
    }

    /// A request without a group is written without the field (as before groups), and a file without it is ungrouped.
    @Test func aFileWithoutAGroupIsUngrouped() throws {
        let data = try SavedRequestCoding.encoder().encode(saved("A"))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["group"] == nil)

        let decoded = try SavedRequestCoding.decoder().decode(SavedRequest.self, from: data)
        #expect(decoded.group == nil)
    }
}

// MARK: - Library and model

@MainActor
@Suite("Saved requests: moving between groups", .serialized)
struct SavedRequestGroupLibraryTests {
    private final class Clock {
        var now = Date(timeIntervalSince1970: 500)
    }

    private func library(_ directory: TemporaryDirectory, clock: Clock = Clock()) -> SavedRequestLibrary {
        SavedRequestLibrary(store: SavedRequestStore(directory: directory.url), now: { clock.now })
    }

    @Test func movingSetsTheGroupOnDisk() async throws {
        let directory = TemporaryDirectory()
        defer { directory.cleanUp() }
        let library = library(directory)
        let a = saved("A", at: 100)
        let b = saved("B", at: 200)
        let c = saved("C", at: 300)
        for item in [a, b, c] { #expect(await library.save(item)) }

        #expect(await library.move([a.id, b.id], toGroup: "G24") == [a.id, b.id])

        #expect(library.request(id: a.id)?.group == "G24")
        #expect(library.request(id: b.id)?.group == "G24")
        #expect(library.request(id: c.id)?.group == nil)
        // A move is a change: newer wins when imported elsewhere.
        #expect(library.request(id: a.id)?.updatedAt == Date(timeIntervalSince1970: 500))
        #expect(library.request(id: c.id)?.updatedAt == Date(timeIntervalSince1970: 300))
        #expect(library.lastError == nil)
        let reopened = SavedRequestLibrary(store: SavedRequestStore(directory: directory.url))
        await reopened.loadIfNeeded()
        #expect(reopened.request(id: a.id)?.group == "G24")
        #expect(reopened.request(id: c.id)?.group == nil)
    }

    @Test func movingIntoAGroupKeepsItsSpellingAndRewritesOnlyWhatChanges() async throws {
        let directory = TemporaryDirectory()
        defer { directory.cleanUp() }
        let clock = Clock()
        let library = library(directory, clock: clock)
        let a = saved("A", group: "G24", at: 100)
        let b = saved("B", at: 200)
        #expect(await library.save(a))
        #expect(await library.save(b))
        clock.now = Date(timeIntervalSince1970: 900)

        #expect(await library.move([a.id, b.id], toGroup: "  g24 ") == [b.id])

        #expect(library.request(id: b.id)?.group == "G24")
        #expect(library.request(id: a.id)?.updatedAt == Date(timeIntervalSince1970: 100))
        #expect(library.request(id: b.id)?.updatedAt == Date(timeIntervalSince1970: 900))
    }

    @Test func removingFromAGroupLeavesTheRequest() async throws {
        let directory = TemporaryDirectory()
        defer { directory.cleanUp() }
        let library = library(directory)
        let a = saved("A", group: "G24", at: 100)
        #expect(await library.save(a))

        #expect(await library.move([a.id], toGroup: nil) == [a.id])
        #expect(await library.move([a.id], toGroup: "   ") == [])

        #expect(library.requests.map(\.id) == [a.id])
        #expect(library.request(id: a.id)?.group == nil)
    }

    /// Renaming moves every member: a case-only rename works, a name taken by another group merges into it, a blank
    /// name ungroups.
    @Test func renamingAGroupMovesEveryMember() async throws {
        let directory = TemporaryDirectory()
        defer { directory.cleanUp() }
        let library = library(directory)
        let a = saved("A", group: "G24", at: 100)
        let b = saved("B", group: "g24", at: 200)
        let c = saved("C", group: "Banner", at: 300)
        for item in [a, b, c] { #expect(await library.save(item)) }

        #expect(await library.renameGroup("g24", to: "G24 smoke") == [a.id, b.id])
        #expect(library.requests.map(\.group) == ["G24 smoke", "G24 smoke", "Banner"])

        #expect(await library.renameGroup("g24 smoke", to: "g24 SMOKE").count == 2)
        #expect(Set(library.requests.compactMap(\.group)) == ["g24 SMOKE", "Banner"])

        #expect(await library.renameGroup("g24 smoke", to: "banner").count == 2)
        #expect(library.requests.map(\.group) == ["Banner", "Banner", "Banner"])

        #expect(await library.renameGroup("banner", to: "").count == 3)
        #expect(library.requests.allSatisfy { $0.group == nil })
    }

    @Test func aMoveThatCannotBeWrittenChangesNothing() async throws {
        let directory = TemporaryDirectory()
        defer { directory.cleanUp() }
        let library = library(directory)
        let a = saved("A", at: 100)
        #expect(await library.save(a))
        // A file where the folder was: nothing can be written.
        try FileManager.default.removeItem(at: directory.url)
        try Data("x".utf8).write(to: directory.url)

        #expect(await library.move([a.id], toGroup: "G24").isEmpty)

        #expect(library.request(id: a.id)?.group == nil)
        #expect(library.request(id: a.id)?.updatedAt == Date(timeIntervalSince1970: 100))
        #expect(library.lastError != nil)
    }

    @Test func aDuplicateStaysInTheGroup() async throws {
        let directory = TemporaryDirectory()
        defer { directory.cleanUp() }
        let library = library(directory)
        let a = saved("A", group: "G24", at: 100)
        #expect(await library.save(a))

        let copy = try #require(await library.duplicate(a.id))

        #expect(copy.group == "G24")
    }

    /// Saving over a request keeps the group it has in the library now (moved in Saved while open); Save as New
    /// keeps the group of the request it came from; a request never saved has none.
    @Test func savingKeepsTheGroup() async throws {
        let directory = TemporaryDirectory()
        defer { directory.cleanUp() }
        let library = library(directory)
        let model = ClientModel(target: RecordingSimulatorTarget(monitor: NetworkMonitor(transport: ScriptedTransport(), publishInterval: .zero)),
                                library: library, now: { Date(timeIntervalSince1970: 1_800_000_000) })
        model.request = ClientRequest(url: "https://ssp.example/openrtb2/auction", body: #"{"id":"1"}"#)
        #expect(await model.save())
        let id = try #require(model.savedID)
        #expect(library.request(id: id)?.group == nil)
        #expect(await library.move([id], toGroup: "G24") == [id])
        // Moving the open request is not a change to its content.
        #expect(!model.hasUnsavedChanges)

        model.name = "Renamed"
        #expect(await model.save())
        #expect(library.request(id: id)?.group == "G24")
        #expect(library.request(id: id)?.name == "Renamed")

        #expect(await model.save(asNew: true))
        let copyID = try #require(model.savedID)
        #expect(copyID != id)
        #expect(library.request(id: copyID)?.group == "G24")

        model.newRequest()
        model.request = ClientRequest(url: "https://ssp.example/other")
        #expect(await model.save())
        #expect(library.request(id: try #require(model.savedID))?.group == nil)
    }
}
