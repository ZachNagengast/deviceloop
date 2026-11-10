//  For licensing see accompanying LICENSE file.
//  Copyright 2026 Argmax, Inc. All rights reserved.

import XCTest

/// Finite tests that measure the app named by the `DEVICELOOP_SCENARIO` scenario, one per `perf` command.
final class DeviceLoopMeasure: XCTestCase {
    @MainActor
    func testLaunch() throws {
        let scenario = try Self.scenario()
        let app = XCUIApplication(bundleIdentifier: scenario.bundleID)
        app.launchArguments = scenario.launchArguments
        let options = XCTMeasureOptions()
        options.iterationCount = scenario.iterations
        measure(metrics: [XCTApplicationLaunchMetric()], options: options) {
            app.launch()
        }
    }

    /// Relaunches the app and runs the setup steps, then measures the measured steps, in every iteration.
    @MainActor
    func testScenario() throws {
        let scenario = try Self.scenario()
        let app = XCUIApplication(bundleIdentifier: scenario.bundleID)
        app.launchArguments = scenario.launchArguments
        let metrics: [any XCTMetric] = scenario.metrics.compactMap { metric in
            switch metric {
                case .hitch:
                    guard #available(iOS 26, *) else { return nil }
                    return XCTHitchMetric(application: app)
                case .cpu: return XCTCPUMetric(application: app)
                case .memory: return XCTMemoryMetric(application: app)
                case .clock: return XCTClockMetric()
                case .scroll: return XCTOSSignpostMetric.scrollingAndDecelerationMetric
                case .signpost(let subsystem, let category, let name):
                    return XCTOSSignpostMetric(subsystem: subsystem, category: category, name: name)
            }
        }
        let options = XCTMeasureOptions()
        options.iterationCount = scenario.iterations
        options.invocationOptions = [.manuallyStart, .manuallyStop]
        let router = Router()
        continueAfterFailure = false
        measure(metrics: metrics, options: options) {
            app.launch()
            for step in scenario.setup { run(step, phase: "Setup", router: router) }
            startMeasuring()
            for step in scenario.measure { run(step, phase: "Measured", router: router) }
            stopMeasuring()
        }
    }

    /// Sends `step` through the router as the CLI would over HTTP, and fails the test when the runner reports an error.
    @MainActor
    private func run(_ step: MeasureStep, phase: String, router: Router) {
        guard let path = step.path else {
            RunLoop.current.run(until: Date().addingTimeInterval(Double(step.sleepMs ?? 0) / 1000))
            return
        }
        let request = HTTPRequest(method: "POST", path: path, headers: [:], body: Data((step.body ?? "").utf8))
        // measure takes a synchronous block, and waiting turns the run loop so the routed task can finish.
        let routed = expectation(description: step.text)
        let reply = Reply()
        Task { @MainActor in
            reply.response = await router.route(request)
            routed.fulfill()
        }
        wait(for: [routed], timeout: 300)
        guard let response = reply.response, response.status >= 300 else { return }
        let failure = (try? JSONDecoder().decode(WireResponse<WireEmpty>.self, from: response.body))?.error
        XCTFail(
            "\(phase) step \"\(step.text)\" failed with \(failure?.code ?? "HTTP \(response.status)"): \(failure?.message ?? "")")
    }

    private static func scenario() throws -> MeasureScenario {
        try JSONDecoder().decode(
            MeasureScenario.self, from: Data((ProcessInfo.processInfo.environment[RunnerWire.Environment.scenario] ?? "").utf8))
    }
}

/// The router's answer to one measured step.
@MainActor private final class Reply {
    var response: HTTPResponse?
}
