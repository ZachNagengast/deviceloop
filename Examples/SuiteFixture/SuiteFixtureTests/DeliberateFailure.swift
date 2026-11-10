//  For licensing see accompanying LICENSE file.
//  Copyright 2026 Argmax, Inc. All rights reserved.

import XCTest

final class DeliberateFailure: XCTestCase {
    func testMismatch() {
        XCTAssertEqual(1 + 1, 3)
    }
}
