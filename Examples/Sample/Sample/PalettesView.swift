//  For licensing see accompanying LICENSE file.
//  Copyright 2026 Argmax, Inc. All rights reserved.

import SwiftUI

struct Palette: Identifiable, Hashable {
    struct Swatch: Hashable {
        let red: Double
        let green: Double
        let blue: Double

        var color: Color { Color(red: red / 255, green: green / 255, blue: blue / 255) }
        var hex: String { String(format: "#%02X%02X%02X", Int(red), Int(green), Int(blue)) }
    }

    let name: String
    let note: String
    let swatches: [Swatch]

    var id: String { name }
    var gradient: LinearGradient {
        LinearGradient(colors: swatches.map(\.color), startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    static let all = [
        Palette(
            name: "Sunrise", note: "Warm light over still water",
            swatches: [.init(255, 183, 94), .init(255, 126, 103), .init(214, 79, 135)]),
        Palette(
            name: "Lagoon", note: "Shallow blues and greens", swatches: [.init(64, 224, 208), .init(32, 160, 220), .init(28, 84, 168)]),
        Palette(
            name: "Meadow", note: "Grass, moss and clover", swatches: [.init(197, 232, 120), .init(102, 190, 110), .init(36, 122, 92)]),
        Palette(name: "Ember", note: "The last glow of a fire", swatches: [.init(255, 214, 102), .init(244, 120, 52), .init(170, 40, 40)]),
        Palette(
            name: "Dusk", note: "Violet hour at the horizon", swatches: [.init(255, 158, 170), .init(150, 110, 220), .init(52, 48, 120)]),
        Palette(name: "Glacier", note: "Ice, fog and slate", swatches: [.init(226, 240, 250), .init(150, 196, 230), .init(80, 112, 150)]),
    ]
}

extension Palette.Swatch {
    init(_ red: Double, _ green: Double, _ blue: Double) {
        self.init(red: red, green: green, blue: blue)
    }
}

/// The Palettes tab: a list of palettes, each opening a detail page with its colors and a Favorite button.
struct PalettesView: View {
    @State private var favorites: Set<String> = []

    var body: some View {
        NavigationStack {
            List(Palette.all) { palette in
                NavigationLink(value: palette) {
                    PaletteRow(palette: palette, isFavorite: favorites.contains(palette.name))
                }
            }
            .navigationTitle("Palettes")
            .navigationDestination(for: Palette.self) { palette in
                PaletteDetail(palette: palette, favorites: $favorites)
            }
        }
    }
}

private struct PaletteRow: View {
    let palette: Palette
    let isFavorite: Bool

    var body: some View {
        HStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(palette.gradient)
                .frame(width: 44, height: 44)
                .accessibilityHidden(true)
            VStack(alignment: .leading) {
                Text(palette.name)
                    .font(.headline)
                Text(palette.note)
                    .font(.subheadline)
                    .foregroundStyle(.subtle)
            }
            Spacer()
            if isFavorite {
                Image(systemName: "heart.fill")
                    .foregroundStyle(.rose)
                    .accessibilityLabel("Favorite")
            }
        }
    }
}

private struct PaletteDetail: View {
    let palette: Palette
    @Binding var favorites: Set<String>

    private var isFavorite: Bool { favorites.contains(palette.name) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(palette.gradient)
                    .aspectRatio(4 / 3, contentMode: .fit)
                    .accessibilityHidden(true)
                Text(palette.note)
                    .font(.title3)
                    .foregroundStyle(.subtle)
                    .padding(.vertical)
                ForEach(palette.swatches, id: \.self) { swatch in
                    HStack {
                        Circle()
                            .fill(swatch.color)
                            .frame(width: 36, height: 36)
                            .overlay(Circle().strokeBorder(.quaternary))
                            .accessibilityHidden(true)
                        Text(swatch.hex)
                            .font(.body.monospaced())
                        Spacer()
                    }
                    .accessibilityElement(children: .combine)
                }
                Button {
                    if isFavorite {
                        favorites.remove(palette.name)
                    } else {
                        favorites.insert(palette.name)
                    }
                } label: {
                    Label(isFavorite ? "Favorited" : "Favorite", systemImage: isFavorite ? "heart.fill" : "heart")
                        .contentTransition(.symbolEffect(.replace))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.rose)
                .controlSize(.large)
                .padding(.top)
                .accessibilityIdentifier("sample.palette.favorite")
            }
            .padding()
        }
        .navigationTitle(palette.name)
    }
}
