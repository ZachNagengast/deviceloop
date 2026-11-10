//  For licensing see accompanying LICENSE file.
//  Copyright 2026 Argmax, Inc. All rights reserved.

import Testing

@testable import DeviceLoopKit
@testable import deviceloop

@Suite struct PerfCLITests {
    @Test func runHidesTypeStepsOfSetupAndMeasure() throws {
        let words = [
            "--app", "com.example", "--setup", #"type "hunter2" id=password"#, "--setup", "tap id=open",
            "--measure", "type swordfish", "--measure", "tap id=login",
        ]
        let run = try PerfCLI.Run.parse(words)
        #expect(run.typed == [#"type "hunter2" id=password"#, "hunter2", "type swordfish", "swordfish"])
        let journaled = RunRecorder.hide(run.typed, in: .array(words.map(JSONValue.string)))
        #expect(journaled.array?.compactMap(\.string).filter { $0.contains("hunter2") || $0.contains("swordfish") } == [])
        #expect(journaled.array?.compactMap(\.string).contains("tap id=open") == true)
    }
}
