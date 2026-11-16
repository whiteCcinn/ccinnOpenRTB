import Testing
@testable import CcinnOpenRTBKit

@Suite("Smoke")
struct SmokeTests {
    @Test func builds() {
        #expect(Bool(true))
    }
}
