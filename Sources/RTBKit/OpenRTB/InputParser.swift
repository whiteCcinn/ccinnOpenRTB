import Foundation

/// Parses the right-hand panel (design D3). Owner: kit-openrtb.
public enum InputParser {
    /// Detects what `text` is and parses it; `request` is the optional bid request JSON.
    public static func parse(_ text: String, request: String? = nil) -> ParsedInput {
        // Placeholder until the OpenRTB parser lands: only recognises empty input.
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? ParsedInput(kind: .empty) : ParsedInput(kind: .invalid("Parser not implemented yet"))
    }
}
