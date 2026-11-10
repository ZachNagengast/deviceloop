//  For licensing see accompanying LICENSE file.
//  Copyright 2026 Argmax, Inc. All rights reserved.

import SwiftUI

/// The Motion tab: a card on a dot grid that moves to a random spot when tapped, or where a `deviceloop-sample://move`
/// link says.
struct MotionView: View {
    let lab: MotionLab

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                GeometryReader { proxy in
                    TimelineView(.animation(paused: lab.frameMove == nil)) { context in
                        Button {
                            lab.moveToRandomSpot()
                        } label: {
                            card
                        }
                        .buttonStyle(UnstyledButton())
                        .accessibilityLabel("Move card")
                        .accessibilityIdentifier("sample.motion.card")
                        .position(lab.center(of: lab.framePosition(at: context.date) ?? lab.spot, in: proxy.size))
                    }
                    .onGeometryChange(for: CGRect.self) {
                        $0.frame(in: .global)
                    } action: {
                        lab.layout($0)
                    }
                }
                .background { DotGrid() }
                Text("Tap the card, or open a deviceloop-sample://move link.")
                    .font(.footnote)
                    .foregroundStyle(.subtle)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding()
            }
            .navigationTitle("Motion")
        }
    }

    private var card: some View {
        RoundedRectangle(cornerRadius: 24, style: .continuous)
            .fill(LinearGradient(colors: [.indigo, .pink], startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: MotionLab.side, height: MotionLab.side)
            .overlay {
                Image(systemName: "sparkles")
                    .font(.title)
                    .foregroundStyle(.white)
            }
            .shadow(color: .indigo.opacity(0.3), radius: 12, y: 6)
    }
}

/// Draws the label with no pressed state.
private struct UnstyledButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
    }
}

/// Dots 24 points apart in the quaternary label color.
private struct DotGrid: View {
    var body: some View {
        Canvas { context, size in
            let spacing = 24.0
            for x in stride(from: spacing / 2, to: size.width, by: spacing) {
                for y in stride(from: spacing / 2, to: size.height, by: spacing) {
                    context.fill(Path(ellipseIn: CGRect(x: x - 1, y: y - 1, width: 2, height: 2)), with: .color(Color(.quaternaryLabel)))
                }
            }
        }
        .accessibilityHidden(true)
    }
}
