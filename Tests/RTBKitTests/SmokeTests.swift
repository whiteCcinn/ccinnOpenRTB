import Testing
@testable import RTBKit

@Suite("Smoke")
struct SmokeTests {
    @Test func builds() {
        #expect(Bool(true))
    }
}
