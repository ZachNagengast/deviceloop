//  For licensing see accompanying LICENSE file.
//  Copyright 2026 Argmax, Inc. All rights reserved.

import XCTest

final class Performance: XCTestCase {
    func testClock() {
        measure(metrics: [XCTClockMetric()]) {
            _ = (0 ..< 200_000).map { $0 * 2 }.reduce(0, +)
        }
    }

    @MainActor
    func testLaunch() {
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }
}
