//  For licensing see accompanying LICENSE file.
//  Copyright 2026 Argmax, Inc. All rights reserved.

import OSLog
import SwiftUI
import UIKit

/// The runner's host app, which Xcode 27 needs next to the UI test bundle. Shows `FixtureView` when launched with
/// `--deviceloop-fixture`, its variant B with `--deviceloop-fixture-variant=b` as well, `AccessibilityFixtureView` with
/// `--deviceloop-fixture-a11y faults|clean`, and `IdleView` otherwise.
/// Requests that the idle timer stay disabled while this host app is in the foreground.
/// This does not establish the idle behavior of other apps or device power modes.
/// `--deviceloop-log <marker>`, `--deviceloop-write <name>` and `--deviceloop-crash` log a marker, write a file or trap.
@main
struct DeviceLoopHostApp: App {
    /// Sleeps for the `-DeviceLoopLaunchDelayMs` launch argument before the first frame.
    init() {
        Thread.sleep(forTimeInterval: UserDefaults.standard.double(forKey: "DeviceLoopLaunchDelayMs") / 1000)
        let marker = Self.argument(after: "--deviceloop-log")
        if let marker {
            print(marker)
            fflush(nil)
            Logger(subsystem: Bundle.main.bundleIdentifier ?? "deviceloop.host", category: "fixture")
                .log("\(marker, privacy: .public)")
        }
        if let name = Self.argument(after: "--deviceloop-write") {
            try? Data((marker ?? name).utf8).write(to: URL.documentsDirectory.appending(path: name), options: .atomic)
        }
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if let screen = Self.argument(after: "--deviceloop-fixture-a11y").flatMap(AccessibilityFixtureView.Screen.init(rawValue:)) {
                    AccessibilityFixtureView(screen: screen)
                } else if ProcessInfo.processInfo.arguments.contains("--deviceloop-fixture") {
                    FixtureView(variantB: ProcessInfo.processInfo.arguments.contains("--deviceloop-fixture-variant=b"))
                } else {
                    IdleView()
                }
            }
            .onAppear {
                UIApplication.shared.isIdleTimerDisabled = true
                if ProcessInfo.processInfo.arguments.contains("--deviceloop-crash") {
                    DispatchQueue.main.async { fatalError("--deviceloop-crash") }
                }
            }
        }
    }

    private static func argument(after flag: String) -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }
}

/// The screen on the device while DeviceLoop drives it: what the app is.
private struct IdleView: View {
    @ScaledMetric(relativeTo: .largeTitle) private var badgeSide = 88.0

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: 12) {
                    Text(">_")
                        .font(.system(size: badgeSide * 0.45, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white)
                        .frame(width: badgeSide, height: badgeSide)
                        .background(.tint, in: .rect(cornerRadius: badgeSide * 0.225, style: .continuous))
                        .padding(.bottom, 12)
                        .accessibilityHidden(true)
                    Text("DeviceLoop runner")
                        .font(.title2.bold())
                    Text("DeviceLoop on your Mac uses this app to drive this device. You can delete this app at any time.")
                        .foregroundStyle(.secondary)
                }
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
                .padding(32)
                .frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }
}
