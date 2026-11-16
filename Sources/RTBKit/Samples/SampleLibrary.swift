import Foundation

/// Built-in samples (design D11). Owner: kit-openrtb (OpenRTB / Native); VAST XML constants live in VASTSamples.swift (kit-vast).
public struct Sample: Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String
    public var group: String
    public var response: String
    public var request: String?

    public init(id: String, title: String, group: String, response: String, request: String? = nil) {
        self.id = id
        self.title = title
        self.group = group
        self.response = response
        self.request = request
    }
}

public enum SampleLibrary {
    public static let all: [Sample] = []
}
