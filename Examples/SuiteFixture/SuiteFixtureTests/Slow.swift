//  For licensing see accompanying LICENSE file.
//  Copyright 2026 Argmax, Inc. All rights reserved.

import XCTest

final class Slow: XCTestCase {
    /// Sleeps for 120 seconds so a run can be cancelled midway.
    func testSleeps() {
        Thread.sleep(forTimeInterval: 120)
    }
}
