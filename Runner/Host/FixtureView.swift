//  For licensing see accompanying LICENSE file.
//  Copyright 2026 Argmax, Inc. All rights reserved.

import CoreLocation
import SwiftUI
import UIKit
import os

/// Disposable UI-test controls, enabled only by the host's --deviceloop-fixture launch argument.
struct FixtureView: View {
    /// Emits the `OpenDetail` interval from the Open detail tap until the detail screen appears.
    static let signposter = OSSignposter(subsystem: "com.argmaxinc.deviceloop.host", category: "fixture")

    var variantB = false
    @State private var count = 0
    @State private var input = ""
    @State private var submitted = ""
    @State private var choice = "none"
    @State private var showingDetail = false
    @State private var secret = ""
    @State private var prefilled = "abc"
    @State private var placeholderDeletes = 0
    @State private var showingAlert = false
    @State private var alertChoice = "none"
    @State private var taps = 0
    @State private var doubleTaps = 0
    @State private var longPresses = 0
    @State private var swipe = "none"
    @State private var drag = "none"
    @State private var switchOn = false
    @State private var location = FixtureLocation()
    @State private var openDetail: OSSignpostIntervalState?
    @FocusState private var inputFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Button("Increment") { count += 1 }
                        .accessibilityIdentifier("fixture.counter.increment")
                    Text("Count: \(count)")
                        .accessibilityIdentifier("fixture.counter.value")
                }
                TextField("Test text", text: $input)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($inputFocused)
                    .accessibilityIdentifier("fixture.text.input")
                Button("Submit text") {
                    submitted = input
                    inputFocused = false
                }
                .accessibilityIdentifier("fixture.text.submit")
                .padding(.leading, variantB ? 40 : 0)
                Text(submitted.isEmpty ? "No text submitted" : submitted)
                    .accessibilityIdentifier("fixture.text.echo")
                HStack {
                    SecureField("Password", text: $secret)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("fixture.secure.input")
                    Text("Secret length: \(secret.count)")
                        .accessibilityIdentifier("fixture.secure.length")
                }
                TextField("Prefilled", text: $prefilled)
                    .font(.system(size: 17, design: .monospaced))
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .frame(width: 300)
                    .accessibilityIdentifier("fixture.prefilled.input")
                HStack {
                    DeleteCountingField(placeholder: "Empty with placeholder", deletes: $placeholderDeletes)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Deletes: \(placeholderDeletes)")
                        .accessibilityIdentifier("fixture.placeholder.deletes")
                }
                Button(variantB ? "Show detail" : "Open detail") {
                    inputFocused = false
                    openDetail = Self.signposter.beginInterval("OpenDetail")
                    showingDetail = true
                }
                .accessibilityIdentifier("fixture.navigation.open")
                HStack(spacing: 24) {
                    Button("Choose") { choice = "first" }
                        .accessibilityIdentifier("fixture.duplicate.first")
                    Button("Choose") { choice = "second" }
                        .accessibilityIdentifier("fixture.duplicate.second")
                }
                Text("Choice: \(choice)")
                    .accessibilityIdentifier("fixture.duplicate.result")
                Spacer()
            }
            .buttonStyle(.bordered)
            .padding()
            .navigationTitle("Test fixture")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(isPresented: $showingDetail) {
                VStack(spacing: 20) {
                    Text("Detail screen")
                        .accessibilityIdentifier("fixture.navigation.detail")
                    Button("Back to fixture") { showingDetail = false }
                        .accessibilityIdentifier("fixture.navigation.back")
                    HStack {
                        Button("Show alert") { showingAlert = true }
                            .accessibilityIdentifier("fixture.alert.open")
                        Text("Alert: \(alertChoice)")
                            .accessibilityIdentifier("fixture.alert.result")
                    }
                    Button("Request location") { location.request() }
                        .accessibilityIdentifier("fixture.location.request")
                    Text(location.reading)
                        .accessibilityIdentifier("fixture.location.value")
                    SlideRow(variantB: variantB)
                    HStack(alignment: .top) {
                        GesturePad(taps: $taps, doubleTaps: $doubleTaps, longPresses: $longPresses, swipe: $swipe, drag: $drag)
                            .frame(width: 200, height: 140)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Taps: \(taps)")
                                .accessibilityIdentifier("fixture.gesture.taps")
                            Text("Double taps: \(doubleTaps)")
                                .accessibilityIdentifier("fixture.gesture.doubletaps")
                            Text("Long presses: \(longPresses)")
                                .accessibilityIdentifier("fixture.gesture.longpresses")
                            Text("Swipe: \(swipe)")
                                .accessibilityIdentifier("fixture.gesture.swipe")
                            Text("Drag: \(drag)")
                                .accessibilityIdentifier("fixture.gesture.drag")
                        }
                        .font(.footnote)
                    }
                    Toggle("Fixture switch", isOn: $switchOn)
                        .accessibilityIdentifier("fixture.switch")
                        .frame(width: 280)
                        .overlay {
                            Button("Off screen") {}
                                .offset(x: 1000)
                                .accessibilityIdentifier("fixture.offscreen")
                        }
                }
                .alert("Unsaved draft", isPresented: $showingAlert) {
                    Button("Keep Draft") { alertChoice = "Keep Draft" }
                    Button("Delete Draft", role: .destructive) { alertChoice = "Delete Draft" }
                    Button("Ask Later", role: .cancel) { alertChoice = "Ask Later" }
                }
                .navigationTitle("Detail")
                .navigationBarBackButtonHidden()
                .onAppear {
                    if let openDetail { Self.signposter.endInterval("OpenDetail", openDetail) }
                    openDetail = nil
                }
            }
        }
    }
}

/// A text field that counts delete key presses, including presses on an empty field.
private struct DeleteCountingField: UIViewRepresentable {
    let placeholder: String
    @Binding var deletes: Int

    func makeUIView(context: Context) -> CountingTextField {
        let field = CountingTextField()
        field.placeholder = placeholder
        field.borderStyle = .roundedRect
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.accessibilityIdentifier = "fixture.placeholder.input"
        field.onDelete = { deletes += 1 }
        return field
    }

    func updateUIView(_ field: CountingTextField, context: Context) {}

    final class CountingTextField: UITextField {
        var onDelete: () -> Void = {}

        override func deleteBackward() {
            onDelete()
            super.deleteBackward()
        }
    }
}

/// A pad that counts single taps, double taps and long presses, and records the direction and translation of the last pan.
private struct GesturePad: UIViewRepresentable {
    @Binding var taps: Int
    @Binding var doubleTaps: Int
    @Binding var longPresses: Int
    @Binding var swipe: String
    @Binding var drag: String

    func makeUIView(context: Context) -> PadView {
        let pad = PadView()
        pad.backgroundColor = .secondarySystemFill
        pad.isAccessibilityElement = true
        pad.accessibilityLabel = "Gesture pad"
        pad.accessibilityIdentifier = "fixture.gesture.pad"
        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleTap))
        doubleTap.numberOfTapsRequired = 2
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tap))
        tap.require(toFail: doubleTap)
        pad.addGestureRecognizer(doubleTap)
        pad.addGestureRecognizer(tap)
        pad.addGestureRecognizer(UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.longPress)))
        pad.addGestureRecognizer(UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pan)))
        return pad
    }

    func updateUIView(_ pad: PadView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(pad: self) }

    /// Records where the last touch went down.
    final class PadView: UIView {
        var touchDown = CGPoint.zero

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            touchDown = touches.first?.location(in: self) ?? .zero
            super.touchesBegan(touches, with: event)
        }
    }

    @MainActor final class Coordinator: NSObject {
        let pad: GesturePad

        init(pad: GesturePad) { self.pad = pad }

        @objc func tap() { pad.taps += 1 }

        @objc func doubleTap() { pad.doubleTaps += 1 }

        @objc func longPress(_ recognizer: UILongPressGestureRecognizer) {
            if recognizer.state == .began { pad.longPresses += 1 }
        }

        @objc func pan(_ recognizer: UIPanGestureRecognizer) {
            guard recognizer.state == .ended, let view = recognizer.view as? PadView else { return }
            let end = recognizer.location(in: view)
            let translation = CGPoint(x: end.x - view.touchDown.x, y: end.y - view.touchDown.y)
            pad.drag = "\(Int(translation.x.rounded())),\(Int(translation.y.rounded()))"
            if abs(translation.x) > abs(translation.y) {
                pad.swipe = translation.x < 0 ? "left" : "right"
            } else {
                pad.swipe = translation.y < 0 ? "up" : "down"
            }
        }
    }
}

/// The location this app receives, read while it has When In Use access.
@MainActor @Observable
final class FixtureLocation: NSObject, CLLocationManagerDelegate {
    var reading = "Location: not requested"
    private let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
    }

    func request() {
        manager.requestWhenInUseAuthorization()
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        MainActor.assumeIsolated {
            switch status {
                case .authorizedWhenInUse, .authorizedAlways:
                    self.manager.startUpdatingLocation()
                    reading = "Location: waiting"
                case .denied, .restricted: reading = "Location: not authorized"
                default: reading = "Location: not requested"
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let coordinate = locations.last?.coordinate else { return }
        let text = String(format: "Location: %.6f,%.6f", coordinate.latitude, coordinate.longitude)
        MainActor.assumeIsolated { reading = text }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) {
        let text = (error as? CLError)?.code == .denied ? "Location: not authorized" : "Location: unavailable"
        MainActor.assumeIsolated { reading = text }
    }
}

/// Moves a square 160 pt right, linearly over 300 ms, or 700 ms in variant B. Holds its own state so the move animates on
/// the detail screen.
private struct SlideRow: View {
    let variantB: Bool
    @State private var slid = false

    var body: some View {
        HStack {
            // A tap gesture on text draws no pressed highlight, unlike a Button.
            Text("Slide")
                .padding(8)
                .onTapGesture {
                    withAnimation(.linear(duration: variantB ? 0.7 : 0.3)) { slid.toggle() }
                }
                .accessibilityAddTraits(.isButton)
                .accessibilityIdentifier("fixture.transition.toggle")
            RoundedRectangle(cornerRadius: 8)
                .fill(.tint)
                .frame(width: 44, height: 44)
                .offset(x: slid ? 160 : 0)
        }
    }
}
