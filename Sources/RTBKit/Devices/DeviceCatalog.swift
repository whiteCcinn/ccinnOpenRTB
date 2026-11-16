import Foundation

/// Built-in devices (design D8). Owner: app-shell.
public enum DeviceCatalog {
    public static let all: [DeviceProfile] = [
        DeviceProfile(id: "iphone-15", name: "iPhone 15", family: .iPhone, screenWidth: 393, screenHeight: 852, scale: 3, cornerRadius: 55,
                      safeArea: DeviceInsets(top: 59, bottom: 34), cutout: .dynamicIsland, os: "iOS", osVersion: "18.0", make: "Apple",
                      model: "iPhone15,4",
                      userAgent: "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148",
                      openRTBDeviceType: 4),
    ]

    public static var defaultDevice: DeviceProfile { all[0] }

    public static func device(id: String) -> DeviceProfile? { all.first { $0.id == id } }
}
