import Foundation
import Testing
@testable import SekitiriApp

@Suite("Resource stability")
struct ResourceStabilityTests {
    @Test("Eight gigabyte Macs do not retain summary weights")
    func summaryRetentionIsBounded() {
        #expect(LocalSummaryRuntime.warmRetentionSeconds <= 30)
    }
}
