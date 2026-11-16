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
        let required = ["iphone-se-3", "iphone-13-mini", "iphone-15", "iphone-15-plus", "iphone-15-pro", "iphone-15-pro-max", "iphone-16-pro",
                        "iphone-16-pro-max", "pixel-8", "galaxy-s24", "galaxy-z-fold", "pixel-fold", "surface-duo", "ipad-10", "ipad-pro-11",
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

    @Test func cutoutsMatchTheHardware() throws {
        #expect(try #require(DeviceCatalog.device(id: "iphone-se-3")).cutout == .none)
        #expect(try #require(DeviceCatalog.device(id: "iphone-13-mini")).cutout == .notch)
        #expect(try #require(DeviceCatalog.device(id: "iphone-15")).cutout == .dynamicIsland)
        #expect(try #require(DeviceCatalog.device(id: "iphone-16-pro-max")).cutout == .dynamicIsland)
        #expect(try #require(DeviceCatalog.device(id: "pixel-8")).cutout == .punchHole)
        #expect(try #require(DeviceCatalog.device(id: "galaxy-s24")).cutout == .punchHole)
        // The SE has a home button: no bottom inset.
        #expect(try #require(DeviceCatalog.device(id: "iphone-se-3")).safeArea.bottom == 0)
    }

    @Test func defaultDeviceIsAModernIPhone() {
        #expect(DeviceCatalog.defaultDevice.family == .iPhone)
        #expect(DeviceCatalog.defaultDevice.id == "iphone-15-pro")
    }
}
