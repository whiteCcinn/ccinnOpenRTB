import Foundation

// Device profiles (design D8). The catalog lives in Devices/DeviceCatalog.swift.

public struct DeviceInsets: Sendable, Hashable, Codable {
    public var top: Double
    public var leading: Double
    public var bottom: Double
    public var trailing: Double

    public init(top: Double = 0, leading: Double = 0, bottom: Double = 0, trailing: Double = 0) {
        self.top = top
        self.leading = leading
        self.bottom = bottom
        self.trailing = trailing
    }
}

public struct DeviceProfile: Sendable, Hashable, Identifiable, Codable {
    public enum Family: String, Sendable, Hashable, Codable, CaseIterable {
        case iPhone, androidPhone, foldable, dualScreen, tablet, ctv
    }

    public enum Cutout: String, Sendable, Hashable, Codable {
        case none, notch, dynamicIsland, punchHole
    }

    public enum Input: String, Sendable, Hashable, Codable {
        case touch, remote
    }

    /// Stable id, e.g. `iphone-16-pro`.
    public var id: String
    public var name: String
    public var family: Family
    /// Portrait screen size in points (landscape for CTV). For dual-screen devices: one screen.
    public var screenWidth: Double
    public var screenHeight: Double
    public var scale: Double
    public var cornerRadius: Double
    public var safeArea: DeviceInsets
    public var cutout: Cutout
    /// Dual-screen devices: the gap between the two screens (points). `nil` for single-screen devices.
    public var hingeWidth: Double?
    /// Foldables: the cover (folded) screen size in points; the main fields describe the unfolded screen.
    public var foldedWidth: Double?
    public var foldedHeight: Double?
    /// Foldables whose cover screen is laid out differently from the main one (e.g. an iPhone-style cover screen with the
    /// Dynamic Island on a foldable whose open screen is tablet-like); `nil`: the cover screen uses `safeArea`.
    public var foldedSafeArea: DeviceInsets?
    public var os: String
    public var osVersion: String
    public var make: String
    public var model: String
    public var userAgent: String
    /// OpenRTB `device.devicetype`: 1 mobile/tablet, 3 connected TV, 4 phone, 5 tablet, 7 set-top box.
    public var openRTBDeviceType: Int
    public var input: Input
    /// CTV cannot open click-through URLs.
    public var supportsClickThrough: Bool
    /// The device clock's IANA time zone (`Asia/Kuala_Lumpur`), the offset of VAST `[TIMESTAMP]`; `nil` (the catalog's
    /// default) or an identifier Foundation does not know means UTC. Never the Mac's own zone: the simulator plays the
    /// device, not the machine it runs on.
    public var timeZone: String?

    public init(id: String, name: String, family: Family, screenWidth: Double, screenHeight: Double, scale: Double, cornerRadius: Double = 0,
                safeArea: DeviceInsets = DeviceInsets(), cutout: Cutout = .none, hingeWidth: Double? = nil, foldedWidth: Double? = nil,
                foldedHeight: Double? = nil, foldedSafeArea: DeviceInsets? = nil, os: String, osVersion: String, make: String, model: String, userAgent: String,
                openRTBDeviceType: Int, input: Input = .touch, supportsClickThrough: Bool = true, timeZone: String? = nil) {
        self.id = id
        self.name = name
        self.family = family
        self.screenWidth = screenWidth
        self.screenHeight = screenHeight
        self.scale = scale
        self.cornerRadius = cornerRadius
        self.safeArea = safeArea
        self.cutout = cutout
        self.hingeWidth = hingeWidth
        self.foldedWidth = foldedWidth
        self.foldedHeight = foldedHeight
        self.foldedSafeArea = foldedSafeArea
        self.os = os
        self.osVersion = osVersion
        self.make = make
        self.model = model
        self.userAgent = userAgent
        self.openRTBDeviceType = openRTBDeviceType
        self.input = input
        self.supportsClickThrough = supportsClickThrough
        self.timeZone = timeZone
    }
}
