//  For licensing see accompanying LICENSE file.
//  Copyright 2026 Argmax, Inc. All rights reserved.

import SwiftUI

/// Accessibility audit screens, enabled only by the host's --deviceloop-fixture-a11y faults|clean launch argument.
struct AccessibilityFixtureView: View {
    enum Screen: String {
        case faults
        case clean
    }

    let screen: Screen

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                switch screen {
                    case .faults: faults
                    case .clean: clean
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
        .background(Color.white)
        .environment(\.colorScheme, .light)
    }

    /// One fault per audit type that XCTest's audit flags, each on the element fixture.a11y.<type>.
    @ViewBuilder private var faults: some View {
        Text("Accessibility faults")
            .font(.title)
            .accessibilityIdentifier("fixture.a11y.screen")
        Button(action: {}) {
            Circle().fill(Color.blue).frame(width: 44, height: 44)
        }
        .accessibilityIdentifier("fixture.a11y.sufficientElementDescription")
        Button(action: {}) {
            Text("Tap area").frame(width: 200, height: 44, alignment: .leading)
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle().size(width: 8, height: 8))
        .accessibilityIdentifier("fixture.a11y.hitRegion")
        Text("Low contrast text")
            .foregroundStyle(Color(white: 0.88))
            .accessibilityIdentifier("fixture.a11y.contrast")
        Text("Fixed size text")
            .font(.system(size: 15))
            .accessibilityIdentifier("fixture.a11y.dynamicType")
        Text("Short label")
            .lineLimit(1)
            .frame(width: 110, alignment: .leading)
            .accessibilityIdentifier("fixture.a11y.textClipped")
        Button("Save button") {}
            .buttonStyle(.borderedProminent)
            .tint(Color(red: 0, green: 0.3, blue: 0.7))
            .controlSize(.large)
            .accessibilityIdentifier("fixture.a11y.trait")
    }

    @ViewBuilder private var clean: some View {
        Text("Accessible screen")
            .font(.title)
            .accessibilityIdentifier("fixture.a11y.screen")
        Text("Body text in the system font that scales with Dynamic Type.")
            .accessibilityIdentifier("fixture.a11y.clean.text")
        Button("Continue") {}
            .buttonStyle(.borderedProminent)
            .tint(Color(red: 0, green: 0.3, blue: 0.7))
            .controlSize(.large)
            .accessibilityIdentifier("fixture.a11y.clean.button")
    }
}
