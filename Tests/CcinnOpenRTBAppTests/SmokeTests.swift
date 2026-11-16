import Testing
@testable import CcinnOpenRTB

@Suite("Smoke")
struct SmokeTests {
    @Test func builds() {
        #expect(Bool(true))
    }
}
