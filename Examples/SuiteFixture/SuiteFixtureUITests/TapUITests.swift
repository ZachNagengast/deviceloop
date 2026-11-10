//  For licensing see accompanying LICENSE file.
//  Copyright 2026 Argmax, Inc. All rights reserved.

import XCTest

final class TapUITests: XCTestCase {
    @MainActor
    func testTapCounts() {
        let app = XCUIApplication()
        app.launch()
        app.buttons["tapButton"].tap()
        XCTAssertEqual(app.staticTexts["tapCount"].label, "Taps: 1")
    }
}
