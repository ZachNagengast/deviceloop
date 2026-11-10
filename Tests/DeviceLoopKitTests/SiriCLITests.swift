//  For licensing see accompanying LICENSE file.
//  Copyright 2026 Argmax, Inc. All rights reserved.

import DeviceLoopKit
import DeviceLoopProtocol
import Testing

@testable import deviceloop

@Suite struct SiriCLITests {
    @Test func expectReadsTargetsLikeUITap() throws {
        #expect(try SiriCLI.Say.expectation("id=login") == ElementQuery(id: "login"))
        #expect(try SiriCLI.Say.expectation("label~=Wi") == ElementQuery(labelContains: "Wi"))
        #expect(try SiriCLI.Say.expectation("Done") == ElementQuery(label: "Done"))
    }

    @Test func expectRejectsPointsRefsAndLabelEquals() {
        for text in ["120,640", "@e5", "label=Done"] {
            #expect(throws: DeviceLoopError.self) { try SiriCLI.Say.expectation(text) }
        }
    }
}
