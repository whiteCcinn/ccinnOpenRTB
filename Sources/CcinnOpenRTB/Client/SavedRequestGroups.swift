import Foundation

/// Groups of saved requests, as plain values (tested without views).
///
/// A group is a name on the requests (`SavedRequest.group`): there is no list of groups to keep in step with the files,
/// so a group exists while it holds requests. Names are normalized (`normalized`) and compared without case (`key`), so
/// "G24" and "g24" are one group, titled as its most recently updated request spells it.
enum SavedRequestGroups {
    static let maxNameLength = 80
    static let ungroupedTitle = "No Group"

    /// One group's requests (or the ungrouped ones), in list order.
    struct Section: Identifiable, Equatable {
        /// `nil` for the requests without a group.
        var key: String?
        var title: String
        var requests: [SavedRequest]

        /// Stable across launches (folded sections are remembered by it).
        var id: String { Self.id(key: key) }

        static func id(key: String?) -> String { key.map { "group:" + $0 } ?? "ungrouped" }
    }

    /// What the Saved list shows for a search: sections once any request of the library has a group (a library without
    /// groups is the flat list it always was), and `shown`, the rows on screen — every selection and bulk action works on
    /// them, so a folded group is never selected or deleted.
    struct Listing: Equatable {
        /// `nil`: the flat list.
        var sections: [Section]?
        var shown: [SavedRequest]
        var collapsed: Set<String>
        /// A search shows every match: nothing is folded and folding is off.
        var expandAll: Bool

        /// Nothing matches (folded sections still count: their headers are listed).
        var isEmpty: Bool { sections.map(\.isEmpty) ?? shown.isEmpty }

        func isExpanded(_ section: Section) -> Bool { expandAll || !collapsed.contains(section.id) }
    }

    static func listing(_ library: [SavedRequest], query: String, collapsed: Set<String>) -> Listing {
        let matches = ClientPresentation.filter(library, by: query)
        let expandAll = !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard hasGroups(library) else { return Listing(sections: nil, shown: matches, collapsed: collapsed, expandAll: expandAll) }
        let sections = sections(matches)
        return Listing(sections: sections, shown: visible(sections, collapsed: collapsed, expandAll: expandAll), collapsed: collapsed,
                       expandAll: expandAll)
    }

    /// Trimmed, every run of whitespace or control characters one space, at most `maxNameLength` characters; `nil`
    /// when nothing is left. A hand-edited or imported file can hold anything, so this is applied wherever a name is read.
    static func normalized(_ name: String?) -> String? {
        guard let name else { return nil }
        let words = name.prefix(maxNameLength * 4).split { character in
            character.isWhitespace || character.unicodeScalars.allSatisfy { CharacterSet.controlCharacters.contains($0) }
        }
        guard !words.isEmpty else { return nil }
        let capped = words.joined(separator: " ").prefix(maxNameLength)
        let trimmed = capped.hasSuffix(" ") ? capped.dropLast() : capped
        return String(trimmed)
    }

    /// What makes two names one group: the normalized name without case. `nil`: no group.
    static func key(_ name: String?) -> String? {
        normalized(name)?.folding(options: [.caseInsensitive], locale: nil)
    }

    static func hasGroups(_ requests: [SavedRequest]) -> Bool {
        requests.contains { key($0.group) != nil }
    }

    /// The groups by title, then the requests without one (titled `ungroupedTitle`). Each section keeps the list's order.
    static func sections(_ requests: [SavedRequest]) -> [Section] {
        var grouped: [String: Section] = [:]
        var ungrouped: [SavedRequest] = []
        for request in requests {
            guard let name = normalized(request.group) else {
                ungrouped.append(request)
                continue
            }
            let key = name.folding(options: [.caseInsensitive], locale: nil)
            grouped[key, default: Section(key: key, title: name, requests: [])].requests.append(request)
        }
        var sections = grouped.values.sorted(by: inTitleOrder)
        if !ungrouped.isEmpty { sections.append(Section(key: nil, title: ungroupedTitle, requests: ungrouped)) }
        return sections
    }

    /// Every group's title, in order.
    static func names(_ requests: [SavedRequest]) -> [String] {
        sections(requests).compactMap { $0.key == nil ? nil : $0.title }
    }

    /// `name` normalized, spelled as the group of that name among `requests` when there is one; `nil` for a blank name.
    static func canonical(_ name: String?, among requests: [SavedRequest]) -> String? {
        guard let name = normalized(name) else { return nil }
        let key = name.folding(options: [.caseInsensitive], locale: nil)
        return requests.lazy.compactMap { request in Self.key(request.group) == key ? normalized(request.group) : nil }.first ?? name
    }

    /// The requests shown: every section's, except a folded one's — unless `expandAll` (a search shows every match).
    static func visible(_ sections: [Section], collapsed: Set<String>, expandAll: Bool) -> [SavedRequest] {
        sections.flatMap { section in expandAll || !collapsed.contains(section.id) ? section.requests : [] }
    }

    /// `collapsed` with `id` folded or unfolded, keeping only sections the library still has.
    static func toggled(_ id: String, in collapsed: Set<String>, library: [SavedRequest]) -> Set<String> {
        var next = collapsed.intersection(sections(library).map(\.id))
        if collapsed.contains(id) { next.remove(id) } else { next.insert(id) }
        return next
    }

    /// Folded section ids, one per line (ids hold no line breaks: names are normalized), for `@AppStorage`.
    static func encodeCollapsed(_ ids: Set<String>) -> String {
        ids.sorted().joined(separator: "\n")
    }

    static func decodeCollapsed(_ text: String) -> Set<String> {
        Set(text.split(separator: "\n").map(String.init))
    }

    private static func inTitleOrder(_ lhs: Section, _ rhs: Section) -> Bool {
        switch lhs.title.localizedStandardCompare(rhs.title) {
        case .orderedAscending: true
        case .orderedDescending: false
        case .orderedSame: (lhs.key ?? "") < (rhs.key ?? "")
        }
    }
}
