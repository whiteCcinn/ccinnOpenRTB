import Foundation

/// RFC 6901 JSON pointer. `prefix` scopes pointers that do not point into the response itself (`request:`), and pointers
/// continue into JSON embedded in a string field (`/seatbid/0/bid/0/adm/native/assets/0`).
struct JSONPointer: Hashable, CustomStringConvertible {
    private var rendered: String

    static let root = JSONPointer(rendered: "")

    init(prefix: String) {
        rendered = prefix
    }

    private init(rendered: String) {
        self.rendered = rendered
    }

    func appending(_ key: String) -> JSONPointer {
        let escaped = key.replacingOccurrences(of: "~", with: "~0").replacingOccurrences(of: "/", with: "~1")
        return JSONPointer(rendered: rendered + "/" + escaped)
    }

    func appending(_ index: Int) -> JSONPointer {
        JSONPointer(rendered: rendered + "/" + String(index))
    }

    /// Appends another pointer (`/a` + `/b/c` = `/a/b/c`).
    func appending(pointer: String) -> JSONPointer {
        JSONPointer(rendered: rendered + pointer)
    }

    var description: String { rendered }
}
