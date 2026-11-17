import Foundation
import Testing
@testable import RTBKit

@Suite("Device catalog")
struct DeviceCatalogTests {
    private let devices = DeviceCatalog.all

    @Test func idsAreUniqueAndStable() {
        let ids = devices.map(\.id)
        #expect(Set(ids).count == ids.count)
        for id in ids {
            #expect(id == id.lowercased())
            #expect(!id.contains(" "))
        }
        #expect(DeviceCatalog.device(id: "iphone-16-pro-max")?.name == "iPhone 16 Pro Max")
        #expect(DeviceCatalog.device(id: "no-such-device") == nil)
    }

    @Test func everyFamilyIsPresentAndGroupedInCatalogOrder() {
        let families = Set(devices.map(\.family))
        #expect(families == Set(DeviceProfile.Family.allCases))
        let groups = DeviceCatalog.groups
        #expect(groups.map(\.family) == DeviceProfile.Family.allCases)
        #expect(groups.flatMap(\.devices).count == devices.count)
        for group in groups {
            #expect(group.devices.allSatisfy { $0.family == group.family })
        }
    }

    @Test func requiredModelsArePresent() {
        let required = ["iphone-se-3", "iphone-13-mini", "iphone-15", "iphone-15-plus", "iphone-15-pro", "iphone-15-pro-max", "iphone-16e",
                        "iphone-16-pro", "iphone-16-pro-max", "iphone-17", "iphone-air", "iphone-17-pro", "iphone-17-pro-max", "iphone-18-pro",
                        "iphone-18-pro-max", "iphone-duo", "ipad-pro-11-m5", "pixel-8", "galaxy-s24", "galaxy-z-fold", "pixel-fold", "surface-duo", "ipad-10", "ipad-pro-11",
                        "apple-tv-4k", "google-tv", "fire-tv-stick-4k", "roku-express"]
        for id in required {
            #expect(DeviceCatalog.device(id: id) != nil, "missing \(id)")
        }
    }

    @Test func publishedScreenGeometry() throws {
        func size(_ id: String) throws -> (Double, Double, Double) {
            let device = try #require(DeviceCatalog.device(id: id))
            return (device.screenWidth, device.screenHeight, device.scale)
        }
        #expect(try size("iphone-se-3") == (375, 667, 2))
        #expect(try size("iphone-13-mini") == (375, 812, 3))
        #expect(try size("iphone-15") == (393, 852, 3))
        #expect(try size("iphone-15-pro") == (393, 852, 3))
        #expect(try size("iphone-15-plus") == (430, 932, 3))
        #expect(try size("iphone-15-pro-max") == (430, 932, 3))
        #expect(try size("iphone-16-pro") == (402, 874, 3))
        #expect(try size("iphone-16-pro-max") == (440, 956, 3))
        // 2025–2026 (Apple tech specs ÷ 3; useyourloaf "iPhone 17 Screen Sizes").
        #expect(try size("iphone-16e") == (390, 844, 3))
        #expect(try size("iphone-17") == (402, 874, 3))
        #expect(try size("iphone-air") == (420, 912, 3))
        #expect(try size("iphone-17-pro") == (402, 874, 3))
        #expect(try size("iphone-17-pro-max") == (440, 956, 3))
        #expect(try size("iphone-18-pro") == (402, 874, 3))
        #expect(try size("iphone-18-pro-max") == (440, 956, 3))
        #expect(try size("ipad-pro-11-m5") == (834, 1210, 2))
        #expect(try size("pixel-8") == (412, 915, 2.625))
        #expect(try size("galaxy-s24") == (360, 780, 3))
        #expect(try size("ipad-10") == (820, 1180, 2))
        #expect(try size("ipad-pro-11") == (834, 1194, 2))
        #expect(try size("surface-duo") == (540, 720, 2.5))
    }

    @Test func geometryIsSane() {
        for device in devices {
            #expect(device.screenWidth > 0 && device.screenHeight > 0, "\(device.id)")
            #expect([1, 2, 2.5, 2.625, 3].contains(device.scale), "\(device.id) scale")
            #expect(device.cornerRadius >= 0 && device.cornerRadius < min(device.screenWidth, device.screenHeight) / 2, "\(device.id) corners")
            let insets = device.safeArea
            #expect(insets.top >= 0 && insets.bottom >= 0 && insets.leading >= 0 && insets.trailing >= 0)
            #expect(insets.top + insets.bottom < device.screenHeight / 4, "\(device.id) safe area")
            #expect(insets.leading + insets.trailing < device.screenWidth / 4, "\(device.id) safe area")
            // Physical pixels come out whole (within the rounding of published dp values).
            #expect(device.screenWidth * device.scale >= 320)
        }
    }

    @Test func multiScreenGeometryOnlyWhereItBelongs() throws {
        for device in devices {
            switch device.family {
            case .dualScreen:
                let hinge = try #require(device.hingeWidth)
                #expect(hinge > 0 && hinge < device.screenWidth / 4)
                #expect(device.foldedWidth == nil)
            case .foldable:
                let foldedWidth = try #require(device.foldedWidth)
                let foldedHeight = try #require(device.foldedHeight)
                #expect(foldedWidth < device.screenWidth, "\(device.id): the cover screen is narrower than the unfolded one")
                #expect(foldedHeight > foldedWidth, "\(device.id): the cover screen is portrait")
                #expect(device.hingeWidth == nil)
            default:
                #expect(device.hingeWidth == nil && device.foldedWidth == nil && device.foldedHeight == nil, "\(device.id)")
            }
        }
        let duo = try #require(DeviceCatalog.device(id: "surface-duo"))
        // Microsoft's dual-screen web docs: 540 + 34 + 540 = 1114 CSS px spanned.
        #expect(duo.screenWidth * 2 + (duo.hingeWidth ?? 0) == 1114)
    }

    @Test func platformAttributes() {
        for device in devices {
            #expect(!device.userAgent.isEmpty && !device.os.isEmpty && !device.osVersion.isEmpty && !device.make.isEmpty && !device.model.isEmpty)
            #expect(device.userAgent.hasPrefix("Mozilla/5.0") || device.family == .ctv, "\(device.id) UA")
            switch device.family {
            case .iPhone:
                #expect(device.os == "iOS" && device.make == "Apple")
                #expect(device.userAgent.contains("iPhone"))
                #expect(device.openRTBDeviceType == 4)
            case .foldable where device.make == "Apple":
                #expect(device.os == "iOS" && device.userAgent.contains("iPhone"))
                #expect(device.openRTBDeviceType == 4)
            case .androidPhone, .foldable, .dualScreen:
                #expect(device.os == "Android")
                #expect(device.userAgent.contains("Android"))
                #expect(device.openRTBDeviceType == 4)
            case .tablet:
                #expect(device.openRTBDeviceType == 5)
                #expect(device.userAgent.contains("iPad"))
            case .ctv:
                #expect([3, 7].contains(device.openRTBDeviceType))
            }
            if device.family != .ctv {
                #expect(device.input == .touch && device.supportsClickThrough, "\(device.id)")
            }
        }
    }

    @Test func connectedTVRules() {
        let tvs = devices.filter { $0.family == .ctv }
        #expect(tvs.count >= 4)
        for tv in tvs {
            #expect(tv.screenWidth == 1920 && tv.screenHeight == 1080, "\(tv.id): 1920×1080 pt landscape")
            #expect(tv.input == .remote)
            #expect(!tv.supportsClickThrough)
            #expect(tv.cutout == .none && tv.cornerRadius == 0)
        }
        // 1080p and 4K panels are both represented.
        #expect(Set(tvs.map(\.scale)) == [1, 2])
        // Connected TV and set-top box device types are both represented.
        #expect(Set(tvs.map(\.openRTBDeviceType)) == [3, 7])
    }

    /// iOS 26 and later keep `18_6` in the WebKit User-Agent (the OS version is frozen there), while `device.osv` carries
    /// the real version.
    @Test func appleDevicesRunTheCurrentReleaseButKeepTheFrozenUserAgentToken() {
        for device in devices where device.make == "Apple" && device.family != .ctv {
            #expect(device.osVersion == "27.2", "\(device.id)")
            #expect(device.userAgent.contains("OS 18_6 like Mac OS X"), "\(device.id)")
        }
    }

    @Test func iPhoneDuoIsABookFoldableWithAnIPhoneCoverScreen() throws {
        let duo = try #require(DeviceCatalog.device(id: "iphone-duo"))
        #expect(duo.family == .foldable && duo.make == "Apple")
        // Inner 7.6" 1878×2670 px: 669×951 pt rendered at @3x and downsampled, wider than tall when open (fold vertical).
        #expect(duo.screenWidth == 951 && duo.screenHeight == 669 && duo.scale == 3)
        // Cover 5.4" 1398×2034 px @3x, with the Dynamic Island; the inner screen's camera is under the display.
        #expect(duo.foldedWidth == 466 && duo.foldedHeight == 678)
        #expect(duo.cutout == .dynamicIsland)
        let cover = try #require(duo.foldedSafeArea)
        #expect(cover.top > duo.safeArea.top && cover.bottom == 34)
    }

    @Test func coverScreenInsetsOnlyOnFoldables() {
        for device in devices where device.foldedSafeArea != nil {
            #expect(device.family == .foldable, "\(device.id)")
        }
    }

    @Test func cutoutsMatchTheHardware() throws {
        #expect(try #require(DeviceCatalog.device(id: "iphone-se-3")).cutout == .none)
        #expect(try #require(DeviceCatalog.device(id: "iphone-13-mini")).cutout == .notch)
        #expect(try #require(DeviceCatalog.device(id: "iphone-15")).cutout == .dynamicIsland)
        #expect(try #require(DeviceCatalog.device(id: "iphone-16e")).cutout == .notch)
        #expect(try #require(DeviceCatalog.device(id: "iphone-air")).cutout == .dynamicIsland)
        #expect(try #require(DeviceCatalog.device(id: "iphone-air")).safeArea == DeviceInsets(top: 68, bottom: 34))
        #expect(try #require(DeviceCatalog.device(id: "iphone-17-pro")).safeArea == DeviceInsets(top: 62, bottom: 34))
        #expect(try #require(DeviceCatalog.device(id: "iphone-16-pro-max")).cutout == .dynamicIsland)
        #expect(try #require(DeviceCatalog.device(id: "pixel-8")).cutout == .punchHole)
        #expect(try #require(DeviceCatalog.device(id: "galaxy-s24")).cutout == .punchHole)
        // The SE has a home button: no bottom inset.
        #expect(try #require(DeviceCatalog.device(id: "iphone-se-3")).safeArea.bottom == 0)
    }

    @Test func defaultDeviceIsACurrentIPhone() {
        #expect(DeviceCatalog.defaultDevice.family == .iPhone)
        #expect(DeviceCatalog.defaultDevice.id == "iphone-17-pro")
    }

    @Test func profilesRoundTripThroughCodableWithAndWithoutTheCoverInsets() throws {
        let duo = try #require(DeviceCatalog.device(id: "iphone-duo"))
        let decoded = try JSONDecoder().decode(DeviceProfile.self, from: JSONEncoder().encode(duo))
        #expect(decoded == duo)
        // Profiles saved before `foldedSafeArea` existed still decode.
        var legacy = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(DeviceCatalog.defaultDevice)) as? [String: Any])
        legacy["foldedSafeArea"] = nil
        let old = try JSONDecoder().decode(DeviceProfile.self, from: JSONSerialization.data(withJSONObject: legacy))
        #expect(old.foldedSafeArea == nil)
    }
}
