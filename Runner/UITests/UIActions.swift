//  For licensing see accompanying LICENSE file.
//  Copyright 2026 Argmax, Inc. All rights reserved.

import UIKit
import XCTest

/// Runs UI commands with public XCUITest API. One call at a time on the main actor.
@MainActor
enum UIActions {
    private static let springboard = "com.apple.springboard"
    private static var cachedApps: [String: XCUIApplication] = [:]
    private static var currentApp = springboard
    /// References are scoped to this runner process, observation and requested app.
    private static var locators = ObservationReferences<RefLocator>()
    /// The observed app's frame size when the tree was taken.
    private static var observedSize = CGSize.zero

    struct RefLocator {
        var owner: String
        var type: XCUIElement.ElementType
        /// Position among descendants of `type`, in snapshot document order.
        var index: Int
        /// The point a tap on the element hits, in screen points: the frame's center, or the switch inside a switch row.
        /// Nil when the element has an empty frame.
        var tapPoint: CGPoint?
        var id: String?
        var label: String?
    }

    static func app(_ bundleID: String?) -> XCUIApplication {
        let id = bundleID ?? currentApp
        if let cached = cachedApps[id] { return cached }
        let app = XCUIApplication(bundleIdentifier: id)
        cachedApps[id] = app
        return app
    }

    static func launch(_ request: AppRequest) -> ActionResult {
        defer { locators.invalidate() }
        let app = app(request.app)
        if let arguments = request.arguments { app.launchArguments = arguments }
        if let environment = request.environment { app.launchEnvironment = environment }
        if request.mode == "activate" {
            app.activate()
        } else {
            app.launch()
        }
        currentApp = request.app
        return ActionResult(eventTime: now())
    }

    static func terminate(_ app: String) -> ActionResult {
        defer { locators.invalidate() }
        self.app(app).terminate()
        return ActionResult(eventTime: now())
    }

    static func state(_ bundleID: String) -> AppStateResult {
        AppStateResult(app: bundleID, state: stateName(app(bundleID).state))
    }

    /// SpringBoard and system scene hosts such as CarPlay can report running in the foreground
    /// behind another app, so the target is the first foreground candidate with a window on
    /// screen, and SpringBoard only when no other candidate has one.
    static func foreground(_ candidates: [String]) -> ForegroundResult {
        let front = candidates.filter { app($0).state == .runningForeground }
        let shown = front.first { $0 != springboard && hasWindow($0) } ?? front.first { $0 == springboard }
        if let shown, shown != currentApp {
            locators.invalidate()
            currentApp = shown
        }
        return ForegroundResult(foreground: front)
    }

    private static func hasWindow(_ bundleID: String) -> Bool {
        guard let window = try? app(bundleID).windows.firstMatch.snapshot() else { return false }
        return !window.frame.isEmpty
    }

    static func openURL(_ request: OpenURLRequest) throws -> ActionResult {
        defer { locators.invalidate() }
        guard let url = URL(string: request.url) else { throw RunnerFailure("bad_request", "Not a URL: \(request.url)") }
        if let app = request.app {
            self.app(app).open(url)
        } else {
            XCUIDevice.shared.system.open(url)
        }
        return ActionResult(eventTime: now())
    }

    static func tree(_ request: TreeRequest) throws -> TreeResult {
        let app = app(request.app)
        let bundle = request.app ?? currentApp
        locators.invalidate()
        // The orientation before the snapshot, which ref lookups compare with.
        let orientation = orientationName(XCUIDevice.shared.orientation)
        let rootSnapshot = try snapshot(of: app, root: request.root)
        locators.begin(app: bundle, orientation: orientation)
        observedSize = try runningFrame(app).size

        var counter = 0
        var typeCounts: [UInt: Int] = [:]
        let screen = UIScreen.main.bounds
        let visibleOnly = request.visibleOnly ?? false
        let root = node(
            from: rootSnapshot, owner: bundle, counter: &counter, typeCounts: &typeCounts, screen: screen, visibleOnly: visibleOnly)
        let system = (request.includeSystem ?? true) ? systemNodes(counter: &counter, typeCounts: &typeCounts, screen: screen) : nil
        return TreeResult(app: bundle, generation: locators.generation, nodeCount: counter, root: root, system: system)
    }

    static func find(_ request: FindRequest) -> FindResult {
        // allElementsBoundByIndex returns an empty list on no match, where firstMatch would make
        // XCTest log its whole element tree as a diagnostic.
        let all = elementQuery(request.query, in: app(request.app)).allElementsBoundByIndex
        let elements = (request.all ?? false) ? all : Array(all.prefix(1))
        let matches = elements.compactMap { element -> FoundElement? in
            guard element.exists else { return nil }
            let frame = element.frame
            return FoundElement(
                type: typeName(element.elementType),
                id: element.identifier.nonEmpty,
                label: element.label.nonEmpty,
                value: element.value as? String,
                frame: frame.wireFrame,
                hittable: element.isHittable
            )
        }
        return FindResult(matches: matches)
    }

    static func wait(_ request: WaitRequest) throws -> ActionResult {
        let element = element(request.query, in: app(request.app))
        let timeout = Double(request.timeoutMs) / 1000
        let met =
            switch request.until {
                case "gone": element.waitForNonExistence(timeout: timeout)
                case "hittable": waitUntil(timeout: timeout) { element.exists && element.isHittable }
                case "enabled": waitUntil(timeout: timeout) { element.exists && element.isEnabled }
                default: element.waitForExistence(timeout: timeout)
            }
        guard met else {
            throw RunnerFailure("timeout", "Waiting for \(request.until) timed out after \(request.timeoutMs) ms")
        }
        return ActionResult()
    }

    static func waitStable(_ request: WaitStableRequest) throws -> ActionResult {
        let app = app(request.app)
        let deadline = ProcessInfo.processInfo.systemUptime + Double(request.timeoutMs) / 1000
        var stability = ObservationStability(quietDuration: Double(request.quietMs) / 1000)
        var lastSnapshotFailed = false
        while ProcessInfo.processInfo.systemUptime < deadline {
            let remaining = max(0, deadline - ProcessInfo.processInfo.systemUptime)
            let hash = (try? snapshot(of: app, root: nil, launchWait: remaining))?.stableHash
            lastSnapshotFailed = hash == nil
            let sampleTime = ProcessInfo.processInfo.systemUptime
            if sampleTime < deadline, stability.observe(hash: hash, at: sampleTime) {
                return ActionResult()
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        if lastSnapshotFailed {
            throw RunnerFailure("snapshot_failed", "Could not observe the screen settling. Take a new tree.")
        }
        throw RunnerFailure("timeout", "Screen did not settle within \(request.timeoutMs) ms")
    }

    static func tap(_ request: TapRequest) throws -> ActionResult {
        defer { locators.invalidate() }
        let coordinate = try coordinate(for: request.target, bundleID: request.app)
        let eventTime = now()
        if let holdMs = request.holdMs {
            coordinate.press(forDuration: Double(holdMs) / 1000)
        } else if request.count == 2 {
            coordinate.doubleTap()
        } else {
            coordinate.tap()
        }
        return ActionResult(point: WirePoint(x: coordinate.screenPoint.x, y: coordinate.screenPoint.y), eventTime: eventTime)
    }

    static func drag(_ request: DragRequest) throws -> ActionResult {
        defer { locators.invalidate() }
        let app = app(request.app)
        try requireInside(request.from, app)
        try requireInside(request.to, app)
        let from = coordinate(x: request.from.x, y: request.from.y, in: app)
        let to = coordinate(x: request.to.x, y: request.to.y, in: app)
        let eventTime = now()
        from.press(
            forDuration: Double(request.pressMs ?? 50) / 1000,
            thenDragTo: to,
            withVelocity: XCUIGestureVelocity(rawValue: request.velocity ?? XCUIGestureVelocity.default.rawValue),
            thenHoldForDuration: Double(request.holdMs ?? 0) / 1000
        )
        return ActionResult(point: request.from, eventTime: eventTime)
    }

    static func swipe(_ request: SwipeRequest) throws -> ActionResult {
        defer { locators.invalidate() }
        let element = try request.target.map { try resolveElement($0, bundleID: request.app) } ?? app(request.app)
        let velocity = XCUIGestureVelocity(rawValue: request.velocity ?? XCUIGestureVelocity.default.rawValue)
        let eventTime = now()
        switch request.direction {
            case "up": element.swipeUp(velocity: velocity)
            case "down": element.swipeDown(velocity: velocity)
            case "left": element.swipeLeft(velocity: velocity)
            case "right": element.swipeRight(velocity: velocity)
            default: throw RunnerFailure("bad_request", "direction must be up, down, left or right")
        }
        return ActionResult(eventTime: eventTime)
    }

    static func pinch(_ request: PinchRequest) throws -> ActionResult {
        defer { locators.invalidate() }
        let element = try request.target.map { try resolveElement($0, bundleID: request.app) } ?? app(request.app)
        let eventTime = now()
        element.pinch(withScale: request.scale, velocity: request.velocity)
        return ActionResult(eventTime: eventTime)
    }

    static func type(_ request: TypeRequest) throws -> ActionResult {
        defer { locators.invalidate() }
        let app = app(request.app)
        guard let target = request.target else {
            let eventTime = now()
            app.typeText(request.text)
            return ActionResult(eventTime: eventTime)
        }
        let element = try resolveElement(target, bundleID: request.app)
        let before = try resolvedSnapshot(of: element)
        let secure = before.elementType == .secureTextField
        let previous = before.fieldText
        // A tap near the trailing edge puts the caret after the existing text, so typing appends to it.
        let frame = before.frame
        let caret = frame.isEmpty ? nil : CGPoint(x: frame.maxX - min(8, frame.width / 2), y: frame.midY)
        try coordinate(atScreenPoint: caret, in: app).tap()
        if request.clear ?? false, let previous, !previous.isEmpty {
            element.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: previous.count))
            if let remaining = (try? element.snapshot())?.fieldText, !remaining.isEmpty {
                throw RunnerFailure(
                    "text_mismatch", "The field still holds \(remaining.count) characters after clearing, so nothing was typed.")
            }
        }
        let eventTime = now()
        element.typeText(request.text)
        return ActionResult(
            eventTime: eventTime,
            readBack: secure ? nil : (try? element.snapshot())?.fieldText,
            elementType: typeName(before.elementType),
            previousValue: secure ? nil : previous
        )
    }

    static func key(_ request: KeyRequest) -> ActionResult {
        defer { locators.invalidate() }
        let app = app(request.app)
        var flags: XCUIElement.KeyModifierFlags = []
        for modifier in request.modifiers ?? [] {
            switch modifier {
                case "command": flags.insert(.command)
                case "shift": flags.insert(.shift)
                case "option": flags.insert(.option)
                case "control": flags.insert(.control)
                default: break
            }
        }
        let eventTime = now()
        app.typeKey(keyboardKey(request.key), modifierFlags: flags)
        return ActionResult(eventTime: eventTime)
    }

    static func button(_ name: String) throws -> ActionResult {
        let available = hardwareButtons()
        guard let button = available.first(where: { $0.name == name })?.button else {
            throw RunnerFailure(
                "unsupported", "This device has no \(name) button that XCUIDevice can press", alternatives: available.map(\.name))
        }
        defer { locators.invalidate() }
        let eventTime = now()
        XCUIDevice.shared.press(button)
        return ActionResult(eventTime: eventTime)
    }

    static func siri(_ text: String) -> ActionResult {
        defer { locators.invalidate() }
        // The router owns asynchronous acknowledgement and keeps admission until Siri returns.
        let eventTime = now()
        XCUIDevice.shared.siriService.activate(voiceRecognitionText: text)
        return ActionResult(eventTime: eventTime)
    }

    /// Labels `accept` taps, with straight apostrophes. An alert must show exactly one of them.
    private static let acceptLabels = ["Allow", "OK", "Allow While Using App", "Allow Full Access", "Continue", "Open"]
    /// Labels `dismiss` taps, with straight apostrophes. An alert must show exactly one of them.
    private static let dismissLabels = ["Don't Allow", "Cancel", "Not Now", "Dismiss"]

    static func readAlert() -> AlertResult {
        guard let alert = frontmostAlert() else { return AlertResult(present: false) }
        let snapshot = try? alert.element.snapshot()
        // An app alert also lists its title among its static texts.
        let texts = (snapshot?.descendantStaticTexts ?? []).filter { $0 != snapshot?.label }
        return AlertResult(
            present: true,
            owner: alert.owner,
            title: snapshot?.label,
            message: texts.isEmpty ? nil : texts.joined(separator: "\n"),
            buttons: snapshot?.descendantButtons ?? []
        )
    }

    static func actOnAlert(_ request: AlertActionRequest) throws -> ActionResult {
        defer { locators.invalidate() }
        guard let alert = frontmostAlert() else { throw RunnerFailure("element_not_found", "No alert is showing") }
        let buttons = (try? alert.element.snapshot())?.descendantButtons ?? []
        let label: String?
        if let button = request.button {
            let names = ElementQuery.forms(of: button).map(\.straightApostrophes)
            label = buttons.first { names.contains($0.straightApostrophes) }
        } else {
            let action = request.action ?? "accept"
            let known = action == "dismiss" ? dismissLabels : acceptLabels
            let matches = buttons.filter { known.contains($0.straightApostrophes) }
            guard matches.count == 1 else {
                let list = buttons.map { "\"\($0)\"" }.joined(separator: ", ")
                throw RunnerFailure("element_ambiguous", "\(action) matched \(matches.count) known labels, not 1. Alert buttons: \(list).")
            }
            label = matches[0]
        }
        guard let label, alert.element.buttons[label].exists else {
            throw RunnerFailure("element_not_found", "Alert has no button \(request.button ?? request.action ?? "")")
        }
        let eventTime = now()
        alert.element.buttons[label].tap()
        return ActionResult(eventTime: eventTime, button: label)
    }

    private static let auditTypes: [(name: String, type: XCUIAccessibilityAuditType)] = [
        ("contrast", .contrast),
        ("elementDetection", .elementDetection),
        ("hitRegion", .hitRegion),
        ("sufficientElementDescription", .sufficientElementDescription),
        ("dynamicType", .dynamicType),
        ("textClipped", .textClipped),
        ("trait", .trait),
    ]

    static func audit(_ request: AuditRequest) throws -> AuditResult {
        var types: XCUIAccessibilityAuditType = []
        for name in request.types ?? auditTypes.map(\.name) {
            guard let type = auditTypes.first(where: { $0.name == name })?.type else {
                throw RunnerFailure("bad_request", "Unknown audit type \(name). Use \(auditTypes.map(\.name).joined(separator: ", ")).")
            }
            types.insert(type)
        }
        if types.isEmpty { throw RunnerFailure("bad_request", "Name at least one audit type, or omit types to run all of them.") }
        let app = app(request.app)
        if app.state == .notRunning { throw RunnerFailure("app_not_running", "The app is not running") }
        defer { locators.invalidate() }
        // Returning true keeps each finding out of XCTest's failure record.
        var found: [XCUIAccessibilityAuditIssue] = []
        do {
            try app.performAccessibilityAudit(for: types) { issue in
                found.append(issue)
                return true
            }
        } catch {
            throw RunnerFailure("audit_failed", "\(error)")
        }
        let issues = found.map { issue in
            let snapshot = try? issue.element?.snapshot()
            return AuditIssue(
                type: auditTypes.first { $0.type == issue.auditType }?.name ?? String(issue.auditType.rawValue),
                compactDescription: issue.compactDescription,
                detailedDescription: issue.detailedDescription,
                element: snapshot.map {
                    FoundElement(
                        type: typeName($0.elementType), id: $0.identifier.nonEmpty, label: $0.label.nonEmpty, frame: $0.frame.wireFrame)
                }
            )
        }
        return AuditResult(app: request.app ?? currentApp, issues: issues)
    }

    static func invalidateRefs() {
        locators.invalidate()
    }

    static func screenshot() -> Data {
        XCUIScreen.main.screenshot().pngRepresentation
    }

    static func info() -> InfoResult {
        let screen = UIScreen.main
        return InfoResult(
            screenWidth: screen.bounds.width,
            screenHeight: screen.bounds.height,
            scale: screen.scale,
            model: UIDevice.current.model,
            systemName: UIDevice.current.systemName,
            systemVersion: UIDevice.current.systemVersion,
            orientation: orientationName(XCUIDevice.shared.orientation),
            appearance: XCUIDevice.shared.appearance == .dark ? "dark" : "light",
            hardwareButtons: hardwareButtons().map(\.name),
            preferredLanguages: Locale.preferredLanguages,
            locale: Locale.current.identifier
        )
    }

    /// Buttons this device has, by wire name. The SDK marks the volume buttons unavailable in the Simulator.
    private static func hardwareButtons() -> [(name: String, button: XCUIDevice.Button)] {
        var buttons: [(name: String, button: XCUIDevice.Button)] = [("home", .home)]
        #if !targetEnvironment(simulator)
            buttons += [("volumeUp", .volumeUp), ("volumeDown", .volumeDown)]
        #endif
        buttons += [("action", .action), ("camera", .camera)]
        return buttons.filter { XCUIDevice.shared.hasHardwareButton($0.button) }
    }

    private static func coordinate(for target: ElementTarget, bundleID: String?) throws -> XCUICoordinate {
        let app = app(bundleID)
        if let point = target.point {
            try requireInside(point, app)
            return coordinate(x: point.x, y: point.y, in: app)
        }
        // A ref taps the point the tree reported, so small targets are not missed.
        if let ref = target.ref {
            let locator = try resolveRef(ref, bundleID: bundleID)
            return try coordinate(atScreenPoint: locator.tapPoint, in: self.app(locator.owner))
        }
        // Snapshot the element once to read its frame, then tap the coordinate. Tapping a coordinate
        // does not re-snapshot the element afterwards, so a tap that navigates away is not a failure.
        return try coordinate(atScreenPoint: tapPoint(of: resolvedSnapshot(of: resolveElement(target, bundleID: bundleID))), in: app)
    }

    /// The center of `snapshot`, or of the switch inside it when `snapshot` is a switch row such as a SwiftUI Toggle. Nil
    /// when the frame is empty, as for an icon on a Home Screen page that is not showing.
    private static func tapPoint(of snapshot: XCUIElementSnapshot) -> CGPoint? {
        let inner = snapshot.elementType == .switch ? innerSwitch(of: snapshot) : nil
        let frame = inner?.frame ?? snapshot.frame
        return frame.isEmpty ? nil : CGPoint(x: frame.midX, y: frame.midY)
    }

    /// The first switch inside `snapshot` with a frame of its own that overlaps the row's. SwiftUI draws a Toggle's switch
    /// a few points past the row.
    private static func innerSwitch(of snapshot: XCUIElementSnapshot) -> XCUIElementSnapshot? {
        for child in snapshot.children {
            if child.elementType == .switch, !child.frame.isEmpty, child.frame != snapshot.frame, snapshot.frame.intersects(child.frame) {
                return child
            }
            if let nested = innerSwitch(of: child) { return nested }
        }
        return nil
    }

    /// The coordinate of `point`, in screen points like element frames, in `app`. Throws element_not_hittable before any
    /// input when there is no point or it is outside the app's frame, as for an icon on another Home Screen page.
    private static func coordinate(atScreenPoint point: CGPoint?, in app: XCUIApplication) throws -> XCUICoordinate {
        guard let point else {
            throw RunnerFailure("element_not_hittable", "The element has an empty frame, so it is not on the screen.")
        }
        let frame = try runningFrame(app)
        guard frame.contains(point) else {
            throw RunnerFailure(
                "element_not_hittable",
                "The element at \(Int(point.x)),\(Int(point.y)) is outside the app frame of \(sizeText(frame.size)) points.")
        }
        return coordinate(x: point.x - frame.minX, y: point.y - frame.minY, in: app)
    }

    /// The point `x`, `y`, in points from the top-left corner of `app`.
    private static func coordinate(x: Double, y: Double, in app: XCUIApplication) -> XCUICoordinate {
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x, dy: y))
    }

    /// Throws before any input when `point`, an offset from the app's top-left corner, is outside the app's frame.
    private static func requireInside(_ point: WirePoint, _ app: XCUIApplication) throws {
        let size = try runningFrame(app).size
        guard (0 ..< size.width).contains(point.x), (0 ..< size.height).contains(point.y) else {
            throw RunnerFailure(
                "bad_request", "Point \(point.x),\(point.y) is outside the app frame of \(sizeText(size)) points. Pass a point inside it.")
        }
    }

    private static func sizeText(_ size: CGSize) -> String { "\(Int(size.width))x\(Int(size.height))" }

    /// The app's frame. Throws app_not_running when the app is not running.
    private static func runningFrame(_ app: XCUIApplication) throws -> CGRect {
        if app.state == .notRunning { throw RunnerFailure("app_not_running", "The app is not running") }
        return app.frame
    }

    /// Throws element_not_found when `element` matches no element or several.
    private static func resolvedSnapshot(of element: XCUIElement) throws -> XCUIElementSnapshot {
        do {
            return try element.snapshot()
        } catch {
            throw RunnerFailure("element_not_found", "No element matches the target")
        }
    }

    private static func resolveElement(_ target: ElementTarget, bundleID: String?) throws -> XCUIElement {
        let app = app(bundleID)
        if target.point != nil {
            throw RunnerFailure("bad_request", "This action needs an element (ref or query), not a point")
        }
        if let ref = target.ref {
            let locator = try resolveRef(ref, bundleID: bundleID)
            let app = self.app(locator.owner)
            if let id = locator.id {
                return app.descendants(matching: locator.type).matching(identifier: id).element
            }
            if let label = locator.label {
                return app.descendants(matching: locator.type).matching(NSPredicate(format: "label == %@", label)).element
            }
            return app.descendants(matching: locator.type).element(boundBy: locator.index)
        }
        if let query = target.query {
            return try single(query, in: app)
        }
        throw RunnerFailure("bad_request", "An element target needs a point, ref or query")
    }

    /// Seconds an element action waits for its query to match, which covers a screen still pushing in after the last tap.
    private static let matchWait = 2.0

    /// The one element `query` names. Of several matches it leaves out those with an empty frame, such as an icon's copy
    /// on a Home Screen page that is not showing, then picks the one whose frame holds all the others, such as a button
    /// and the text inside it with the same label, and throws element_ambiguous when there is none.
    private static func single(_ query: ElementQuery, in app: XCUIApplication) throws -> XCUIElement {
        if query.index != nil {
            let element = element(query, in: app)
            guard element.waitForExistence(timeout: matchWait) else {
                throw RunnerFailure("element_not_found", "No element matches the query")
            }
            return element
        }
        var matches: [XCUIElement] = []
        _ = waitUntil(timeout: matchWait) {
            matches = elementQuery(query, in: app).allElementsBoundByIndex.filter(\.exists)
            return !matches.isEmpty
        }
        guard !matches.isEmpty else { throw RunnerFailure("element_not_found", "No element matches the query") }
        let shown = matches.filter { !$0.frame.isEmpty }
        let candidates = shown.isEmpty ? matches : shown
        let frames = candidates.map(\.frame)
        if let outer = frames.firstIndex(where: { frame in frames.allSatisfy { frame.contains($0) } }) { return candidates[outer] }
        throw RunnerFailure(
            "element_ambiguous", "\(matches.count) elements match the query",
            alternatives: matches.prefix(8).map { element in
                let frame = element.frame.wireFrame.map { String(Int($0)) }.joined(separator: ",")
                let id = element.identifier.nonEmpty.map { " id=\($0)" } ?? ""
                return "\(typeName(element.elementType)) \"\(element.label)\"\(id) [\(frame)]"
            })
    }

    /// The locator `ref` names. Throws stale_ref when a later tree or input replaced it, or the device turned or the app
    /// frame changed size since the tree.
    private static func resolveRef(_ ref: String, bundleID: String?) throws -> RefLocator {
        let bundle = bundleID ?? currentApp
        guard let observed = locators.orientation, let locator = locators.value(for: ref, app: bundle, orientation: observed) else {
            throw RunnerFailure("stale_ref", "Ref \(ref) is not in the last tree snapshot. Take a new tree.")
        }
        // Face up and face down read as unknown and keep the interface orientation, so only a turn between known ones counts.
        let orientation = orientationName(XCUIDevice.shared.orientation)
        if orientation != observed, orientation != "unknown", observed != "unknown" {
            throw RunnerFailure(
                "stale_ref",
                "The device orientation changed from \(observed) to \(orientation) after ref \(ref) was taken. Take a new tree.")
        }
        let size = try runningFrame(app(bundle)).size
        if size != observedSize {
            let turn = observed == "unknown" && orientation != "unknown" ? " as the device turned to \(orientation)" : ""
            throw RunnerFailure(
                "stale_ref",
                "The app frame changed from \(sizeText(observedSize)) to \(sizeText(size))\(turn) after ref \(ref) was taken. "
                    + "Take a new tree.")
        }
        return locator
    }

    private static func elementQuery(_ query: ElementQuery, in app: XCUIApplication) -> XCUIElementQuery {
        var result = app.descendants(matching: elementType(query.type))
        if let id = query.id { result = result.matching(identifier: id) }
        if let label = query.label {
            let labels = ElementQuery.forms(of: label)
            result = result.matching(
                labels.count == 1 ? NSPredicate(format: "label == %@", label) : NSPredicate(format: "label IN %@", labels))
        }
        if let contains = query.labelContains {
            let parts = ElementQuery.forms(of: contains).map { NSPredicate(format: "label CONTAINS[c] %@", $0) }
            result = result.matching(parts.count == 1 ? parts[0] : NSCompoundPredicate(orPredicateWithSubpredicates: parts))
        }
        if let predicate = query.predicate { result = result.matching(NSPredicate(format: predicate)) }
        return result
    }

    /// The single element a query resolves to, honouring an explicit index.
    private static func element(_ query: ElementQuery, in app: XCUIApplication) -> XCUIElement {
        let result = elementQuery(query, in: app)
        if let index = query.index { return result.element(boundBy: index) }
        return result.element
    }

    private static func snapshot(of app: XCUIApplication, root query: ElementQuery?, launchWait: Double = 5) throws -> XCUIElementSnapshot {
        // An app launched outside XCTest, for example by devicectl, can still be starting.
        if app.state == .notRunning, !waitUntil(timeout: launchWait, { app.state != .notRunning }) {
            throw RunnerFailure("app_not_running", "The app is not running")
        }
        if let query {
            return try element(query, in: app).snapshot()
        }
        do {
            return try app.snapshot()
        } catch {
            return try app.windows.firstMatch.snapshot()
        }
    }

    private static func node(
        from snapshot: XCUIElementSnapshot,
        owner: String,
        counter: inout Int,
        typeCounts: inout [UInt: Int],
        screen: CGRect,
        visibleOnly: Bool
    ) -> TreeNode {
        counter += 1
        let raw = snapshot.elementType.rawValue
        let index = typeCounts[raw] ?? 0
        typeCounts[raw] = index + 1
        let frame = snapshot.frame
        let id = snapshot.identifier.nonEmpty
        let label = snapshot.label.nonEmpty
        let ref = locators.insert(
            RefLocator(
                owner: owner, type: snapshot.elementType, index: index, tapPoint: tapPoint(of: snapshot), id: id, label: label))

        let children = snapshot.children
            .filter { !visibleOnly || $0.frame.intersects(screen) }
            .map { node(from: $0, owner: owner, counter: &counter, typeCounts: &typeCounts, screen: screen, visibleOnly: visibleOnly) }
        return TreeNode(
            ref: ref,
            type: typeName(snapshot.elementType),
            id: id,
            label: label,
            value: snapshot.value as? String,
            placeholder: snapshot.placeholderValue,
            title: snapshot.title.nonEmpty,
            frame: frame.wireFrame,
            enabled: snapshot.isEnabled ? nil : false,
            selected: snapshot.isSelected ? true : nil,
            children: children.isEmpty ? nil : children
        )
    }

    private static func systemNodes(counter: inout Int, typeCounts: inout [UInt: Int], screen: CGRect) -> [TreeNode]? {
        guard let alert = try? app(springboard).alerts.firstMatch.snapshot(), alert.elementType == .alert else { return nil }
        return [node(from: alert, owner: springboard, counter: &counter, typeCounts: &typeCounts, screen: screen, visibleOnly: false)]
    }

    private static func frontmostAlert() -> (element: XCUIElement, owner: String)? {
        let system = XCUIApplication(bundleIdentifier: springboard)
        if system.alerts.firstMatch.exists {
            return (system.alerts.firstMatch, springboard)
        }
        let current = app(nil)
        if current.alerts.firstMatch.exists {
            return (current.alerts.firstMatch, currentApp)
        }
        return nil
    }

    private static func waitUntil(timeout: Double, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return condition()
    }

    private static func now() -> Double { Date().timeIntervalSince1970 }

    private static func stateName(_ state: XCUIApplication.State) -> String {
        switch state {
            case .notRunning: return "notRunning"
            case .runningBackground: return "background"
            case .runningBackgroundSuspended: return "suspended"
            case .runningForeground: return "foreground"
            default: return "unknown"
        }
    }

    private static func orientationName(_ orientation: UIDeviceOrientation) -> String {
        switch orientation {
            case .portrait: return "portrait"
            case .portraitUpsideDown: return "portraitUpsideDown"
            case .landscapeLeft: return "landscapeLeft"
            case .landscapeRight: return "landscapeRight"
            default: return "unknown"
        }
    }

    private static func keyboardKey(_ key: String) -> String {
        switch key {
            case "return", "enter": return XCUIKeyboardKey.return.rawValue
            case "delete", "backspace": return XCUIKeyboardKey.delete.rawValue
            case "escape": return XCUIKeyboardKey.escape.rawValue
            case "tab": return XCUIKeyboardKey.tab.rawValue
            case "space": return XCUIKeyboardKey.space.rawValue
            case "upArrow": return XCUIKeyboardKey.upArrow.rawValue
            case "downArrow": return XCUIKeyboardKey.downArrow.rawValue
            case "leftArrow": return XCUIKeyboardKey.leftArrow.rawValue
            case "rightArrow": return XCUIKeyboardKey.rightArrow.rawValue
            default: return key
        }
    }
}

/// A failure a command reports as an HTTP error without ending the test.
struct RunnerFailure: Error {
    let code: String
    let message: String
    let alternatives: [String]?

    init(_ code: String, _ message: String, alternatives: [String]? = nil) {
        self.code = code
        self.message = message
        self.alternatives = alternatives
    }
}

extension String {
    /// The text with each right single quotation mark replaced by a straight apostrophe.
    var straightApostrophes: String { replacingOccurrences(of: "\u{2019}", with: "'") }

    /// The text, or nil when it is empty.
    var nonEmpty: String? { isEmpty ? nil : self }
}

extension CGRect {
    /// `[x, y, width, height]` in points.
    var wireFrame: WireFrame { [minX, minY, width, height] }
}

extension XCUIElementSnapshot {
    /// Button labels in this subtree, in document order.
    var descendantButtons: [String] {
        collect { $0.elementType == .button ? $0.label.nonEmpty : nil }
    }

    /// The text in a field, empty when the field shows only its placeholder.
    var fieldText: String? {
        guard let value = value as? String else { return nil }
        return value == placeholderValue ? "" : value
    }

    /// Static text strings in this subtree, in document order.
    var descendantStaticTexts: [String] {
        collect { $0.elementType == .staticText ? $0.label.nonEmpty : nil }
    }

    /// A value that changes when the visible tree changes, for settle detection.
    var stableHash: Int {
        var hasher = Hasher()
        walk { node in
            hasher.combine(node.elementType.rawValue)
            hasher.combine(node.identifier)
            hasher.combine(node.label)
            hasher.combine(node.value as? String)
            let frame = node.frame
            hasher.combine(Int(frame.minX))
            hasher.combine(Int(frame.minY))
            hasher.combine(Int(frame.width))
            hasher.combine(Int(frame.height))
            hasher.combine(node.isEnabled)
            hasher.combine(node.isSelected)
        }
        return hasher.finalize()
    }

    private func collect(_ transform: (XCUIElementSnapshot) -> String?) -> [String] {
        var result: [String] = []
        walk { if let value = transform($0) { result.append(value) } }
        return result
    }

    private func walk(_ visit: (XCUIElementSnapshot) -> Void) {
        visit(self)
        for child in children { child.walk(visit) }
    }
}
