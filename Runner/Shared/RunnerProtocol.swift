//  For licensing see accompanying LICENSE file.
//  Copyright 2026 Argmax, Inc. All rights reserved.

import Foundation

// Wire types shared by the on-device runner and the DeviceLoop CLI.
// The runner serves HTTP/1.1 JSON at /v1/... Every request carries `Authorization: Bearer <token>`.
// Coordinates and sizes are points with the origin at the top left of the screen.

public enum RunnerWire {
    /// The protocol revision. It changes with the meaning of requests and replies, not only with the routes.
    public static let version = 5
    /// Printed once on stdout when the listener is ready: `DEVICELOOP_READY port=<port> v=<version>`.
    public static let readyPrefix = "DEVICELOOP_READY"

    public enum Header {
        public static let epoch = "x-deviceloop-epoch"
        public static let operationID = "x-deviceloop-operation-id"
        public static let dispatchBudget = "x-deviceloop-dispatch-budget-ms"
    }

    /// Environment variables the CLI passes to the runner through the xctestrun file.
    public enum Environment {
        public static let token = "DEVICELOOP_TOKEN"
        /// Address to bind: the device side of the CoreDevice tunnel, or `::1` on a simulator.
        public static let bind = "DEVICELOOP_BIND"
        /// Only this peer address may connect: the Mac side of the tunnel, or `::1`.
        public static let peer = "DEVICELOOP_PEER"
        public static let port = "DEVICELOOP_PORT"
        /// JSON `MeasureScenario` for a `DeviceLoopMeasure` test.
        public static let scenario = "DEVICELOOP_SCENARIO"
    }

    public enum Path {
        public static let health = "/v1/health"
        public static let operations = "/v1/operations/"
        public static let time = "/v1/time"
        public static let info = "/v1/info"
        public static let shutdown = "/v1/shutdown"
        public static let appLaunch = "/v1/app/launch"
        public static let appTerminate = "/v1/app/terminate"
        public static let appState = "/v1/app/state"
        public static let appForeground = "/v1/app/foreground"
        public static let openURL = "/v1/open-url"
        public static let tree = "/v1/tree"
        public static let find = "/v1/find"
        public static let wait = "/v1/wait"
        public static let waitStable = "/v1/wait/stable"
        public static let tap = "/v1/tap"
        public static let drag = "/v1/drag"
        public static let swipe = "/v1/swipe"
        public static let pinch = "/v1/pinch"
        public static let type = "/v1/type"
        public static let key = "/v1/key"
        public static let button = "/v1/button"
        public static let siri = "/v1/siri"
        public static let orientation = "/v1/orientation"
        public static let appearance = "/v1/appearance"
        public static let location = "/v1/location"
        public static let screenshot = "/v1/screenshot"
        public static let alert = "/v1/alert"
        public static let audit = "/v1/audit"
        public static let intentsRun = "/v1/intents/run"
        public static let intentsEntities = "/v1/intents/entities"
    }
}

public struct WireTiming: Codable, Sendable, Equatable {
    /// Device wall clock, seconds since 1970.
    public var start: Double
    public var end: Double
    public var ms: Int

    public init(start: Double, end: Double, elapsed: Double? = nil) {
        self.start = start
        self.end = end
        self.ms = Int((max(0, elapsed ?? (end - start)) * 1000).rounded())
    }
}

/// Public XCTest diagnostics, including whether XCTest considers an issue a failure.
public struct WireIssue: Codable, Sendable, Equatable {
    public var type: Int
    public var message: String
    public var isFailure: Bool

    public init(type: Int, message: String, isFailure: Bool) {
        self.type = type
        self.message = message
        self.isFailure = isFailure
    }
}

public struct WireError: Codable, Sendable, Equatable {
    /// One of: bad_request, unauthorized, element_not_found, stale_ref, element_ambiguous, element_not_hittable,
    /// text_mismatch, busy, unsupported, timeout, snapshot_failed, app_not_running, audit_failed, intent_failed, xctest_issue,
    /// internal.
    public var code: String
    public var message: String
    /// XCTest issues recorded while the command ran.
    public var issues: [String]
    /// The values the target supports, sent with `unsupported`.
    public var alternatives: [String]?

    public init(code: String, message: String, issues: [String] = [], alternatives: [String]? = nil) {
        self.code = code
        self.message = message
        self.issues = issues
        self.alternatives = alternatives
    }
}

/// Every JSON response: `{"ok": true, "result": {...}, "timing": {...}}` or `{"ok": false, "error": {...}}`.
public struct WireResponse<Result: Codable & Sendable>: Codable, Sendable {
    public var ok: Bool
    public var result: Result?
    public var error: WireError?
    public var timing: WireTiming?
    public var issues: [WireIssue]?

    public init(ok: Bool, result: Result? = nil, error: WireError? = nil, timing: WireTiming? = nil, issues: [WireIssue]? = nil) {
        self.ok = ok
        self.result = result
        self.error = error
        self.timing = timing
        self.issues = issues
    }

    /// The response for a command that returned `result`, an acknowledgement and not proof of its UI postcondition. A
    /// failure among `issues` makes it an xctest_issue error that keeps the result.
    public static func completed(_ result: Result, timing: WireTiming, issues: [WireIssue]) -> Self {
        let failure = issues.contains(where: \.isFailure)
        let error =
            failure
            ? WireError(
                code: "xctest_issue",
                message: "XCTest reported a failure. The action may have taken effect; inspect the current state before retrying.",
                issues: issues.map(\.message)
            ) : nil
        return Self(ok: !failure, result: result, error: error, timing: timing, issues: issues.isEmpty ? nil : issues)
    }
}

/// What a `DeviceLoopMeasure` test measures: the app, how many measured iterations and its launch arguments, and for
/// `testScenario` the steps and metrics.
public struct MeasureScenario: Codable, Sendable, Equatable {
    public var bundleID: String
    public var iterations: Int
    public var launchArguments: [String]
    /// Run after each relaunch, outside the measured interval.
    public var setup: [MeasureStep]
    /// Run inside the measured interval.
    public var measure: [MeasureStep]
    public var metrics: [MeasureMetric]

    public init(
        bundleID: String, iterations: Int, launchArguments: [String] = [], setup: [MeasureStep] = [], measure: [MeasureStep] = [],
        metrics: [MeasureMetric] = []
    ) {
        self.bundleID = bundleID
        self.iterations = iterations
        self.launchArguments = launchArguments
        self.setup = setup
        self.measure = measure
        self.metrics = metrics
    }
}

/// One `ui` step as the runner request the CLI sends for it, or a pause.
public struct MeasureStep: Codable, Sendable, Equatable {
    /// The step as written, with `<text>` in place of typed text.
    public var text: String
    /// Runner path of the POST. Nil for a pause.
    public var path: String?
    /// JSON request body.
    public var body: String?
    public var sleepMs: Int?

    public init(text: String, path: String? = nil, body: String? = nil, sleepMs: Int? = nil) {
        self.text = text
        self.path = path
        self.body = body
        self.sleepMs = sleepMs
    }
}

/// An XCTest metric `testScenario` collects, written as its raw value such as `cpu` or `signpost:<subsystem>/<category>/<name>`.
public enum MeasureMetric: Codable, Sendable, Hashable, RawRepresentable {
    case hitch, cpu, memory, clock
    /// `XCTOSSignpostMetric.scrollingAndDecelerationMetric`.
    case scroll
    /// An os_signpost interval the app emits.
    case signpost(subsystem: String, category: String, name: String)

    /// What `perf run` measures without `--metric`.
    public static let defaults: [MeasureMetric] = [.hitch, .cpu, .memory, .clock]

    public init?(rawValue: String) {
        switch rawValue {
            case "hitch": self = .hitch
            case "cpu": self = .cpu
            case "memory": self = .memory
            case "clock": self = .clock
            case "scroll": self = .scroll
            default:
                guard rawValue.hasPrefix("signpost:") else { return nil }
                let parts = rawValue.dropFirst("signpost:".count).split(separator: "/", maxSplits: 2, omittingEmptySubsequences: false)
                guard parts.count == 3, !parts.contains(where: \.isEmpty) else { return nil }
                self = .signpost(subsystem: String(parts[0]), category: String(parts[1]), name: String(parts[2]))
        }
    }

    public var rawValue: String {
        switch self {
            case .hitch: return "hitch"
            case .cpu: return "cpu"
            case .memory: return "memory"
            case .clock: return "clock"
            case .scroll: return "scroll"
            case .signpost(let subsystem, let category, let name): return "signpost:\(subsystem)/\(category)/\(name)"
        }
    }
}

/// Result type for commands that return nothing.
public struct WireEmpty: Codable, Sendable, Equatable {
    public init() {}
}

public struct WirePoint: Codable, Sendable, Equatable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// `[x, y, width, height]` in points.
public typealias WireFrame = [Double]

/// Finds an element with XCTest queries.
public struct ElementQuery: Codable, Sendable, Equatable {
    /// Element type name such as `button`, `cell`, `textField` (XCUIElement.ElementType without the prefix).
    public var type: String?
    /// Accessibility identifier, exact.
    public var id: String?
    /// Accessibility label, exact.
    public var label: String?
    /// Substring of the label, case-insensitive.
    public var labelContains: String?
    /// NSPredicate over XCUIElementAttributes keys, for example `value BEGINSWITH 'On'`.
    public var predicate: String?
    /// Which match to use. Nil means the first match.
    public var index: Int?

    public init(
        type: String? = nil, id: String? = nil, label: String? = nil, labelContains: String? = nil, predicate: String? = nil,
        index: Int? = nil
    ) {
        self.type = type
        self.id = id
        self.label = label
        self.labelContains = labelContains
        self.predicate = predicate
        self.index = index
    }
}

/// Exactly one of `point`, `ref` or `query`.
public struct ElementTarget: Codable, Sendable, Equatable {
    public var point: WirePoint?
    /// An opaque ref from the most recent /v1/tree of the same app.
    public var ref: String?
    public var query: ElementQuery?

    public init(point: WirePoint? = nil, ref: String? = nil, query: ElementQuery? = nil) {
        self.point = point
        self.ref = ref
        self.query = query
    }
}

public struct AppRequest: Codable, Sendable, Equatable {
    public var app: String
    /// `launch` (relaunches) or `activate` (brings to front, launching if needed).
    public var mode: String?
    public var arguments: [String]?
    public var environment: [String: String]?

    public init(app: String, mode: String? = nil, arguments: [String]? = nil, environment: [String: String]? = nil) {
        self.app = app
        self.mode = mode
        self.arguments = arguments
        self.environment = environment
    }
}

public struct ForegroundRequest: Codable, Sendable, Equatable {
    public var candidates: [String]

    public init(candidates: [String]) {
        self.candidates = candidates
    }
}

public struct OpenURLRequest: Codable, Sendable, Equatable {
    public var url: String
    public var app: String?

    public init(url: String, app: String? = nil) {
        self.url = url
        self.app = app
    }
}

public struct TreeRequest: Codable, Sendable, Equatable {
    /// Bundle ID. Nil means the current target app (last launched or detected foreground app).
    public var app: String?
    /// Snapshot only the subtree of the first match.
    public var root: ElementQuery?
    /// Drop elements whose frame does not intersect the screen.
    public var visibleOnly: Bool?
    /// Also snapshot SpringBoard alerts and the keyboard. Default true.
    public var includeSystem: Bool?

    public init(app: String? = nil, root: ElementQuery? = nil, visibleOnly: Bool? = nil, includeSystem: Bool? = nil) {
        self.app = app
        self.root = root
        self.visibleOnly = visibleOnly
        self.includeSystem = includeSystem
    }
}

public struct FindRequest: Codable, Sendable, Equatable {
    public var app: String?
    public var query: ElementQuery
    public var all: Bool?

    public init(app: String? = nil, query: ElementQuery, all: Bool? = nil) {
        self.app = app
        self.query = query
        self.all = all
    }
}

public struct WaitRequest: Codable, Sendable, Equatable {
    public var app: String?
    public var query: ElementQuery
    /// `exists`, `gone`, `hittable` or `enabled`.
    public var until: String
    public var timeoutMs: Int

    public init(app: String? = nil, query: ElementQuery, until: String, timeoutMs: Int) {
        self.app = app
        self.query = query
        self.until = until
        self.timeoutMs = timeoutMs
    }
}

public struct WaitStableRequest: Codable, Sendable, Equatable {
    public var app: String?
    /// The tree must stay unchanged for this long.
    public var quietMs: Int
    public var timeoutMs: Int

    public init(app: String? = nil, quietMs: Int = 300, timeoutMs: Int = 5000) {
        self.app = app
        self.quietMs = quietMs
        self.timeoutMs = timeoutMs
    }
}

public struct TapRequest: Codable, Sendable, Equatable {
    public var app: String?
    public var target: ElementTarget
    /// 1 or 2.
    public var count: Int?
    /// Long press when set.
    public var holdMs: Int?

    public init(app: String? = nil, target: ElementTarget, count: Int? = nil, holdMs: Int? = nil) {
        self.app = app
        self.target = target
        self.count = count
        self.holdMs = holdMs
    }
}

public struct DragRequest: Codable, Sendable, Equatable {
    public var app: String?
    public var from: WirePoint
    public var to: WirePoint
    /// Press before moving. Default 50 ms.
    public var pressMs: Int?
    /// Pixels per second.
    public var velocity: Double?
    /// Hold at the end before lifting.
    public var holdMs: Int?

    public init(app: String? = nil, from: WirePoint, to: WirePoint, pressMs: Int? = nil, velocity: Double? = nil, holdMs: Int? = nil) {
        self.app = app
        self.from = from
        self.to = to
        self.pressMs = pressMs
        self.velocity = velocity
        self.holdMs = holdMs
    }
}

public struct SwipeRequest: Codable, Sendable, Equatable {
    public var app: String?
    /// Element to swipe on. Nil means the whole app.
    public var target: ElementTarget?
    /// `up`, `down`, `left` or `right`.
    public var direction: String
    /// Pixels per second.
    public var velocity: Double?

    public init(app: String? = nil, target: ElementTarget? = nil, direction: String, velocity: Double? = nil) {
        self.app = app
        self.target = target
        self.direction = direction
        self.velocity = velocity
    }
}

public struct PinchRequest: Codable, Sendable, Equatable {
    public var app: String?
    public var target: ElementTarget?
    /// Below 1 pinches in, above 1 zooms out.
    public var scale: Double
    /// Scale factor per second.
    public var velocity: Double

    public init(app: String? = nil, target: ElementTarget? = nil, scale: Double, velocity: Double) {
        self.app = app
        self.target = target
        self.scale = scale
        self.velocity = velocity
    }
}

public struct TypeRequest: Codable, Sendable, Equatable {
    public var app: String?
    public var text: String
    /// Element to tap first so it has keyboard focus.
    public var target: ElementTarget?
    /// Clear the field before typing.
    public var clear: Bool?

    public init(app: String? = nil, text: String, target: ElementTarget? = nil, clear: Bool? = nil) {
        self.app = app
        self.text = text
        self.target = target
        self.clear = clear
    }
}

public struct KeyRequest: Codable, Sendable, Equatable {
    public var app: String?
    /// `return`, `delete`, `escape`, `tab`, `upArrow`, a single character, and so on.
    public var key: String
    /// `command`, `shift`, `option`, `control`.
    public var modifiers: [String]?

    public init(app: String? = nil, key: String, modifiers: [String]? = nil) {
        self.app = app
        self.key = key
        self.modifiers = modifiers
    }
}

public struct ButtonRequest: Codable, Sendable, Equatable {
    /// `home`, `volumeUp`, `volumeDown`, `action` or `camera`, when the device has it. Volume buttons only on devices.
    public var name: String

    public init(name: String) {
        self.name = name
    }
}

public struct SiriRequest: Codable, Sendable, Equatable {
    /// What to say to Siri, for example "lock the screen".
    public var text: String

    public init(text: String) {
        self.text = text
    }
}

public struct ValueRequest: Codable, Sendable, Equatable {
    /// Orientation (`portrait`, `portraitUpsideDown`, `landscapeLeft`, `landscapeRight`) or appearance (`light`, `dark`).
    public var value: String

    public init(value: String) {
        self.value = value
    }
}

public struct LocationRequest: Codable, Sendable, Equatable {
    public var latitude: Double
    public var longitude: Double
    public var altitude: Double?

    public init(latitude: Double, longitude: Double, altitude: Double? = nil) {
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
    }
}

public struct AlertActionRequest: Codable, Sendable, Equatable {
    /// Exact button label to tap.
    public var button: String?
    /// `accept` or `dismiss` when no button is named.
    public var action: String?

    public init(button: String? = nil, action: String? = nil) {
        self.button = button
        self.action = action
    }
}

public struct AuditRequest: Codable, Sendable, Equatable {
    public var app: String?
    /// `contrast`, `elementDetection`, `hitRegion`, `sufficientElementDescription`, `dynamicType`, `textClipped`, `trait`.
    /// Nil means all of them.
    public var types: [String]?

    public init(app: String? = nil, types: [String]? = nil) {
        self.app = app
        self.types = types
    }
}

/// An App Intent parameter: a JSON string, number or Boolean, or `{"entity": "<entity type>", "id": "<identifier>"}`.
public enum IntentValue: Codable, Sendable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case entity(type: String, id: String)

    private enum CodingKeys: String, CodingKey {
        case entity, id
    }

    public init(from decoder: any Decoder) throws {
        if let container = try? decoder.singleValueContainer() {
            if let value = try? container.decode(Bool.self) {
                self = .bool(value)
                return
            }
            if let value = try? container.decode(Double.self) {
                self = .number(value)
                return
            }
            if let value = try? container.decode(String.self) {
                self = .string(value)
                return
            }
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self = .entity(type: try container.decode(String.self, forKey: .entity), id: try container.decode(String.self, forKey: .id))
    }

    public func encode(to encoder: any Encoder) throws {
        switch self {
            case .string(let value): try value.encode(to: encoder)
            case .number(let value): try value.encode(to: encoder)
            case .bool(let value): try value.encode(to: encoder)
            case .entity(let type, let id):
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode(type, forKey: .entity)
                try container.encode(id, forKey: .id)
        }
    }
}

/// Runs an App Intent of `app` with AppIntentsTesting. iOS 27 and later.
public struct IntentRunRequest: Codable, Sendable, Equatable {
    public var app: String
    /// Intent type name, for example `AddFixtureTaskIntent`.
    public var intent: String
    /// Parameter values by parameter name. Nil sets none.
    public var params: [String: IntentValue]?

    public init(app: String, intent: String, params: [String: IntentValue]? = nil) {
        self.app = app
        self.intent = intent
        self.params = params
    }
}

/// Queries entities of `app` with AppIntentsTesting. iOS 27 and later.
public struct IntentEntitiesRequest: Codable, Sendable, Equatable {
    public var app: String
    /// Entity type name, for example `FixtureTaskEntity`.
    public var entity: String
    /// Text for the entity's string query. Nil returns all entities.
    public var matching: String?
    /// Property names to read from each entity.
    public var properties: [String]?

    public init(app: String, entity: String, matching: String? = nil, properties: [String]? = nil) {
        self.app = app
        self.entity = entity
        self.matching = matching
        self.properties = properties
    }
}

public struct IntentEntity: Codable, Sendable, Equatable {
    /// The entity's instance identifier.
    public var id: String
    /// Requested property values as strings, by property name.
    public var properties: [String: String]

    public init(id: String, properties: [String: String]) {
        self.id = id
        self.properties = properties
    }
}

public struct IntentEntitiesResult: Codable, Sendable, Equatable {
    public var count: Int
    public var entities: [IntentEntity]

    public init(count: Int, entities: [IntentEntity]) {
        self.count = count
        self.entities = entities
    }
}

public struct HealthResult: Codable, Sendable, Equatable {
    public var version: Int
    public var runnerBuild: String
    public var os: String
    public var uptimeS: Double
    public var busy: Bool
    public var currentOp: String?
    public var currentElapsedMs: Int?
    public var queue: Int
    public var sessionEpoch: String?

    public init(
        version: Int, runnerBuild: String, os: String, uptimeS: Double, busy: Bool, currentOp: String? = nil, currentElapsedMs: Int? = nil,
        queue: Int, sessionEpoch: String? = nil
    ) {
        self.version = version
        self.runnerBuild = runnerBuild
        self.os = os
        self.uptimeS = uptimeS
        self.busy = busy
        self.currentOp = currentOp
        self.currentElapsedMs = currentElapsedMs
        self.queue = queue
        self.sessionEpoch = sessionEpoch
    }
}

public struct TimeResult: Codable, Sendable, Equatable {
    /// Device wall clock, seconds since 1970.
    public var wall: Double
    /// Device monotonic clock, seconds since boot.
    public var uptime: Double

    public init(wall: Double, uptime: Double) {
        self.wall = wall
        self.uptime = uptime
    }
}

public struct InfoResult: Codable, Sendable, Equatable {
    public var screenWidth: Double
    public var screenHeight: Double
    public var scale: Double
    public var model: String
    public var systemName: String
    public var systemVersion: String
    public var orientation: String
    public var appearance: String
    public var hardwareButtons: [String]
    /// `Locale.preferredLanguages` in the runner process, for example `["en-US"]`. Nil from older runners.
    public var preferredLanguages: [String]?
    /// `Locale.current.identifier` in the runner process, for example `en_US`. Nil from older runners.
    public var locale: String?

    public init(
        screenWidth: Double, screenHeight: Double, scale: Double, model: String, systemName: String, systemVersion: String,
        orientation: String, appearance: String, hardwareButtons: [String], preferredLanguages: [String]? = nil, locale: String? = nil
    ) {
        self.screenWidth = screenWidth
        self.screenHeight = screenHeight
        self.scale = scale
        self.model = model
        self.systemName = systemName
        self.systemVersion = systemVersion
        self.orientation = orientation
        self.appearance = appearance
        self.hardwareButtons = hardwareButtons
        self.preferredLanguages = preferredLanguages
        self.locale = locale
    }
}

public struct AppStateResult: Codable, Sendable, Equatable {
    public var app: String
    /// `unknown`, `notRunning`, `background`, `suspended`, `foreground`.
    public var state: String

    public init(app: String, state: String) {
        self.app = app
        self.state = state
    }
}

public struct ForegroundResult: Codable, Sendable, Equatable {
    /// Every candidate running in the foreground. iPad can show several apps at once.
    public var foreground: [String]

    public init(foreground: [String]) {
        self.foreground = foreground
    }
}

/// One accessibility element. Empty, false and default fields are omitted on the wire.
public struct TreeNode: Codable, Sendable, Equatable {
    /// Set on every node, `e0`, `e1`, ... in depth-first order. Valid until the next /v1/tree of the same app.
    public var ref: String
    /// Element type name, for example `button`.
    public var type: String
    public var id: String?
    public var label: String?
    public var value: String?
    public var placeholder: String?
    public var title: String?
    public var frame: WireFrame
    /// Present and false only when disabled.
    public var enabled: Bool?
    public var selected: Bool?
    public var focused: Bool?
    public var children: [TreeNode]?

    public init(
        ref: String, type: String, id: String? = nil, label: String? = nil, value: String? = nil, placeholder: String? = nil,
        title: String? = nil, frame: WireFrame, enabled: Bool? = nil, selected: Bool? = nil, focused: Bool? = nil,
        children: [TreeNode]? = nil
    ) {
        self.ref = ref
        self.type = type
        self.id = id
        self.label = label
        self.value = value
        self.placeholder = placeholder
        self.title = title
        self.frame = frame
        self.enabled = enabled
        self.selected = selected
        self.focused = focused
        self.children = children
    }
}

public struct TreeResult: Codable, Sendable, Equatable {
    public var app: String
    /// Increments on every snapshot. Refs from an older generation are stale.
    public var generation: Int
    public var nodeCount: Int
    public var root: TreeNode
    /// SpringBoard alerts and the keyboard, listed separately so agents see them first.
    public var system: [TreeNode]?
    /// True when the full snapshot failed and only parts were captured.
    public var partial: Bool?
    public var errors: [String]?

    public init(
        app: String, generation: Int, nodeCount: Int, root: TreeNode, system: [TreeNode]? = nil, partial: Bool? = nil,
        errors: [String]? = nil
    ) {
        self.app = app
        self.generation = generation
        self.nodeCount = nodeCount
        self.root = root
        self.system = system
        self.partial = partial
        self.errors = errors
    }
}

public struct FoundElement: Codable, Sendable, Equatable {
    public var type: String
    public var id: String?
    public var label: String?
    public var value: String?
    public var frame: WireFrame
    public var hittable: Bool?

    public init(type: String, id: String? = nil, label: String? = nil, value: String? = nil, frame: WireFrame, hittable: Bool? = nil) {
        self.type = type
        self.id = id
        self.label = label
        self.value = value
        self.frame = frame
        self.hittable = hittable
    }
}

public struct FindResult: Codable, Sendable, Equatable {
    public var matches: [FoundElement]

    public init(matches: [FoundElement]) {
        self.matches = matches
    }
}

public struct ActionResult: Codable, Sendable, Equatable {
    /// Where the touch landed, in points, when the action was a touch.
    public var point: WirePoint?
    /// Device wall clock when the event was sent, for lining actions up with video.
    public var eventTime: Double?
    /// For typing with a target: the field's text after typing. Nil for a secure field.
    public var readBack: String?
    /// For typing with a target: the element type name, for example `textField` or `secureTextField`.
    public var elementType: String?
    /// For typing with a target: the field's text before typing, empty when it showed only its placeholder. Nil for a secure field.
    public var previousValue: String?
    /// For typing with a target: whether `readBack` is the text typing should leave. Set by the CLI.
    public var textVerified: Bool?
    /// The receipt for an accepted request that is still running.
    public var operation: OperationReference?
    /// For an alert action: the label of the button the runner tapped.
    public var button: String?

    public init(
        point: WirePoint? = nil, eventTime: Double? = nil, readBack: String? = nil, elementType: String? = nil,
        previousValue: String? = nil, textVerified: Bool? = nil, operation: OperationReference? = nil, button: String? = nil
    ) {
        self.point = point
        self.eventTime = eventTime
        self.readBack = readBack
        self.elementType = elementType
        self.previousValue = previousValue
        self.textVerified = textVerified
        self.operation = operation
        self.button = button
    }
}

public struct OperationReference: Codable, Sendable, Equatable {
    public var id: String
    public var sessionEpoch: String
    public var phase: String

    public init(id: String, sessionEpoch: String, phase: String) {
        self.id = id
        self.sessionEpoch = sessionEpoch
        self.phase = phase
    }
}

/// A receipt lookup. The runner keeps receipts in memory.
public struct OperationStatusResult: Codable, Sendable, Equatable {
    public var operation: OperationReference
    public var responseStatus: Int?
    public var responseContentType: String?
    public var responseJSON: String?

    public init(operation: OperationReference, responseStatus: Int? = nil, responseContentType: String? = nil, responseJSON: String? = nil)
    {
        self.operation = operation
        self.responseStatus = responseStatus
        self.responseContentType = responseContentType
        self.responseJSON = responseJSON
    }
}

public struct ValueResult: Codable, Sendable, Equatable {
    public var value: String

    public init(value: String) {
        self.value = value
    }
}

public struct AlertResult: Codable, Sendable, Equatable {
    public var present: Bool
    /// Bundle ID that owns the alert, usually `com.apple.springboard` for permission prompts.
    public var owner: String?
    public var title: String?
    public var message: String?
    public var buttons: [String]

    public init(present: Bool, owner: String? = nil, title: String? = nil, message: String? = nil, buttons: [String] = []) {
        self.present = present
        self.owner = owner
        self.title = title
        self.message = message
        self.buttons = buttons
    }
}

/// One finding from XCUIApplication.performAccessibilityAudit.
public struct AuditIssue: Codable, Sendable, Equatable {
    /// Audit type name, for example `contrast`.
    public var type: String
    public var compactDescription: String
    public var detailedDescription: String
    /// The element the issue names, read after the audit. Nil when it no longer resolves.
    public var element: FoundElement?

    public init(type: String, compactDescription: String, detailedDescription: String, element: FoundElement? = nil) {
        self.type = type
        self.compactDescription = compactDescription
        self.detailedDescription = detailedDescription
        self.element = element
    }
}

public struct AuditResult: Codable, Sendable, Equatable {
    public var app: String
    public var issues: [AuditIssue]

    public init(app: String, issues: [AuditIssue]) {
        self.app = app
        self.issues = issues
    }
}
