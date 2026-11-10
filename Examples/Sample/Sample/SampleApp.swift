//  For licensing see accompanying LICENSE file.
//  Copyright 2026 Argmax, Inc. All rights reserved.

import SwiftUI

/// A tab view of palettes with detail pages, a card that moves when tapped or linked, and an account form.
/// `deviceloop-sample://` links run as `MotionLab` describes, and a move link opens the Motion tab.
@main
struct SampleApp: App {
    @State private var lab = MotionLab()
    @State private var tab = SampleTab.palettes

    var body: some Scene {
        WindowGroup {
            TabView(selection: $tab) {
                Tab("Palettes", systemImage: "swatchpalette", value: .palettes) {
                    PalettesView()
                }
                Tab("Motion", systemImage: "sparkles", value: .motion) {
                    MotionView(lab: lab)
                }
                Tab("Account", systemImage: "person.crop.circle", value: .account) {
                    AccountView()
                }
            }
            .tint(.indigo)
            .overlay {
                if lab.flashing { Color(.label).ignoresSafeArea() }
            }
            .onOpenURL { url in
                if lab.handle(url) { tab = .motion }
            }
        }
    }
}

enum SampleTab: Hashable {
    case palettes, motion, account
}

extension ShapeStyle where Self == Color {
    /// Secondary text with at least 4.5:1 contrast on grouped and plain backgrounds in light and dark mode.
    static var subtle: Color {
        Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.72, alpha: 1) : UIColor(white: 0.36, alpha: 1) })
    }

    /// The Favorite button and heart color, dark enough for white text on it.
    static var rose: Color { Color(red: 0.84, green: 0.11, blue: 0.38) }
}
