//  For licensing see accompanying LICENSE file.
//  Copyright 2026 Argmax, Inc. All rights reserved.

import SwiftUI

/// Shows one button that counts taps. Building with `DELIBERATE_COMPILE_ERROR` in
/// `SWIFT_ACTIVE_COMPILATION_CONDITIONS` fails to compile.
@main
struct SuiteFixtureApp: App {
    var body: some Scene {
        WindowGroup {
            TapView()
        }
    }
}

struct TapView: View {
    @State private var taps = 0

    var body: some View {
        VStack(spacing: 24) {
            Text("Taps: \(taps)")
                .accessibilityIdentifier("tapCount")
            Button("Tap") { taps += 1 }
                .accessibilityIdentifier("tapButton")
        }
    }
}

#if DELIBERATE_COMPILE_ERROR
    let deliberateCompileError: Int = "not a number"
#endif
