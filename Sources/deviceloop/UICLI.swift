//  For licensing see accompanying LICENSE file.
//  Copyright 2026 Argmax, Inc. All rights reserved.

import ArgumentParser
import DeviceLoopKit
import DeviceLoopProtocol
import Foundation

struct ScreenshotCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "screenshot", abstract: "Capture the screen. Saves a full-resolution PNG and prints its path.")

    @Option(name: [.short, .long], help: "Where to save the PNG.")
    var output: String?

    @Flag(name: .long, help: "Keep native pixels in the returned image instead of points.")
    var native = false

    @OptionGroup var target: TargetOptions

    func run() async throws {
        try await Output.run(target) {
            try await UICommands.screenshot($0, scale: native ? .native : .points, output: output.map { URL(filePath: $0) })
        }
    }
}

struct AppOption: ParsableArguments {
    @Option(name: .long, help: "Bundle ID of the app to act on. Defaults to the app in front.")
    var app: String?
}

struct ElementQueryOptions: ParsableArguments {
    @Option(name: .long, help: "Exact label.")
    var label: String?

    @Option(name: .long, help: "Label contains, case-insensitive.")
    var labelContains: String?

    @Option(name: .long, help: "Accessibility identifier.")
    var id: String?

    @Option(name: .long, help: "Element type, for example button or textField.")
    var type: String?

    var query: ElementQuery { ElementQuery(type: type, id: id, label: label, labelContains: labelContains) }
}

struct UICLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ui",
        abstract: "Read the screen and drive it: tree, tap, swipe, type, press.",
        discussion: """
            Targets: 120,640 (points), @e5 (ref from `ui tree`), id=login (accessibility identifier), \
            label~=Wi (label contains), or any other text as an exact label.
            """,
        subcommands: [
            TreeCLI.self,
            TapCLI.self,
            SwipeCLI.self,
            DragCLI.self,
            TypeCLI.self,
            PressCLI.self,
            FindCLI.self,
            WaitCLI.self,
            AlertCLI.self,
            DoCLI.self,
            AuditCLI.self,
        ]
    )

    struct TreeCLI: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "tree", abstract: "Print the accessibility tree with refs.")

        @Flag(name: .long, help: "Include frames for every element.")
        var frames = false

        @Option(name: .long, help: "Stop after this many lines.")
        var maxRows: Int?

        @Flag(name: .long, help: "Also capture a screenshot.")
        var screenshot = false

        @OptionGroup var app: AppOption
        @OptionGroup var target: TargetOptions

        func run() async throws {
            try await Output.run(target) {
                try await UICommands.tree($0, app: app.app, frames: frames, maxRows: maxRows, screenshot: screenshot)
            }
        }
    }

    struct TapCLI: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "tap",
            abstract: "Tap a point, ref or element.",
            discussion: """
                Examples:
                  deviceloop ui tap General
                  deviceloop ui tap id=photo --count 2
                  deviceloop ui tap 120,640 --hold-ms 800
                """
        )

        @Argument(help: "120,640 or @e5 or id=login or a label.")
        var element: String

        @Option(name: .long, help: "Number of taps, 1 or 2.")
        var count = 1

        @Option(name: .long, help: "Hold for 1 to 10000 milliseconds (long press).")
        var holdMs: Int?

        @OptionGroup var app: AppOption
        @OptionGroup var target: TargetOptions

        func run() async throws {
            let step = UIStep.tap(try UIStep.parseTarget(element), count: count, holdMs: holdMs)
            try step.validate()
            try await Output.run(target) { try await UICommands.perform(step, on: $0, app: app.app) }
        }
    }

    struct SwipeCLI: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "swipe",
            abstract: "Swipe up, down, left or right.",
            discussion: """
                Examples:
                  deviceloop ui swipe up
                  deviceloop ui swipe left --on id=card
                """
        )

        @Argument(help: "`up`, `down`, `left` or `right`.")
        var direction: String

        @Option(name: .long, help: "Element to swipe on. Defaults to the whole app.")
        var on: String?

        @Option(name: .long, help: "Pixels per second, greater than 0.")
        var velocity: Double?

        @OptionGroup var app: AppOption
        @OptionGroup var target: TargetOptions

        func run() async throws {
            let step = UIStep.swipe(direction: direction, on: try on.map(UIStep.parseTarget), velocity: velocity)
            try step.validate()
            try await Output.run(target) { try await UICommands.perform(step, on: $0, app: app.app) }
        }
    }

    struct DragCLI: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "drag", abstract: "Press, drag in a straight line, release.")

        @Argument(help: "Start point, x,y.")
        var from: String

        @Argument(help: "End point, x,y.")
        var to: String

        @Option(name: .long, help: "Pixels per second, greater than 0.")
        var velocity: Double?

        @Option(name: .long, help: "Hold at the end before lifting, 1 to 10000 milliseconds.")
        var holdMs: Int?

        @OptionGroup var app: AppOption
        @OptionGroup var target: TargetOptions

        func run() async throws {
            guard let start = UIStep.parsePoint(from), let end = UIStep.parsePoint(to) else {
                throw DeviceLoopError.usage("drag expects two points, for example: deviceloop ui drag 200,700 200,200")
            }
            let step = UIStep.drag(from: start, to: end, velocity: velocity, holdMs: holdMs)
            try step.validate()
            try await Output.run(target) { try await UICommands.perform(step, on: $0, app: app.app) }
        }
    }

    struct TypeCLI: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "type",
            abstract: "Type text into the focused field, or into --into.",
            discussion: """
                Examples:
                  deviceloop ui type "hello"
                  deviceloop ui type "user@example.com" --into id=email --clear
                """
        )

        @Argument(help: "Text to type.")
        var text: String

        @Option(name: .long, help: "Field to tap first. Its text is read back and compared with what typing should leave.")
        var into: String?

        @Flag(name: .long, help: "Clear the field first. Stops before typing if the field is not empty after clearing.")
        var clear = false

        @OptionGroup var app: AppOption
        @OptionGroup var target: TargetOptions

        func run() async throws {
            let step = UIStep.type(text, into: try into.map(UIStep.parseTarget), clear: clear)
            try step.validate()
            try await Output.run(target, hiding: [text]) { try await UICommands.perform(step, on: $0, app: app.app) }
        }
    }

    struct PressCLI: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "press", abstract: "Press a hardware button: home, volumeUp, volumeDown, action or camera.")

        @Argument(help: "Button name. A button the target lacks fails with unsupported_on_target, listing the ones it has.")
        var button: String

        @OptionGroup var target: TargetOptions

        func run() async throws {
            let step = UIStep.press(button: button)
            try step.validate()
            try await Output.run(target) { try await UICommands.perform(step, on: $0, app: nil) }
        }
    }

    struct FindCLI: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "find", abstract: "Find elements by label, identifier or type.")

        @OptionGroup var element: ElementQueryOptions

        @Flag(name: .long, help: "Return every match instead of the first.")
        var all = false

        @OptionGroup var app: AppOption
        @OptionGroup var target: TargetOptions

        func run() async throws {
            try await Output.run(target) { try await UICommands.find($0, app: app.app, query: element.query, all: all) }
        }
    }

    struct WaitCLI: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "wait",
            abstract: "Wait for an element, or for the screen to settle.",
            discussion: """
                Examples:
                  deviceloop ui wait --label Done
                  deviceloop ui wait --until gone --id spinner --timeout-ms 30000
                  deviceloop ui wait --until stable
                """
        )

        @Option(name: .long, help: "`exists`, `gone`, `hittable`, `enabled` or `stable`.")
        var until = "exists"

        @OptionGroup var element: ElementQueryOptions

        @Option(name: .long, help: "Give up after this many milliseconds.")
        var timeoutMs = 10_000

        @OptionGroup var app: AppOption
        @OptionGroup var target: TargetOptions

        func run() async throws {
            let query = element.query == ElementQuery() ? nil : element.query
            try await Output.run(target) {
                try await UICommands.wait($0, app: app.app, query: query, until: until, timeoutMs: timeoutMs)
            }
        }
    }

    struct AlertCLI: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "alert",
            abstract: "Show the current system alert, or answer it.",
            discussion: """
                `accept` and `dismiss` tap the one button with a known label, such as Allow or Don't Allow, and fail when \
                the alert has none or several.
                Examples:
                  deviceloop ui alert
                  deviceloop ui alert accept
                  deviceloop ui alert --button "Allow Once"
                """
        )

        @Argument(help: "`accept`, `dismiss` or a button label. Omit to read the alert.")
        var answer: String?

        @Option(name: .long, help: "Exact label of the button to tap.")
        var button: String?

        @OptionGroup var target: TargetOptions

        func run() async throws {
            let action = ["accept", "dismiss"].contains(answer ?? "") ? answer : nil
            let label = button ?? (action == nil ? answer : nil)
            try await Output.run(target) {
                if answer != nil, button != nil { throw DeviceLoopError.usage("Pass accept, dismiss or --button, not both.") }
                return try await UICommands.alert($0, button: label, action: action)
            }
        }
    }

    struct DoCLI: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "do",
            abstract: "Run steps in order.",
            discussion: """
                Each step is one argument, with targets as in `ui tap`. Stops at the first step that fails and exits 1. \
                Ctrl-C stops before the next step and exits 130.
                Steps:
                  tap id=login
                  doubletap id=photo
                  hold 120,640 800        Holds for 800 ms, the default.
                  swipe up
                  swipe left id=card      Swipes on one element.
                  drag 200,700 200,200
                  type "hello" id=email   Types into the field and reads it back.
                  press home
                  launch com.apple.Preferences
                  open myapp://route
                  sleep 500               Waits 500 ms.
                Examples:
                  deviceloop ui do 'tap "Wi-Fi"' 'swipe up' 'sleep 300'
                  deviceloop ui do 'type "hello" id=email' 'press home' --screenshot
                """
        )

        @Argument(help: "Steps: tap, doubletap, hold, swipe, drag, type, press, launch, open or sleep.")
        var steps: [String]

        @Flag(name: .long, help: "Capture a screenshot after the steps, also when one fails.")
        var screenshot = false

        @OptionGroup var app: AppOption
        @OptionGroup var target: TargetOptions

        func run() async throws {
            let parsed = try steps.map(UIStep.parse)
            try UICommands.validate(parsed)
            let typed = zip(steps, parsed).flatMap { step, parsed in parsed.typedText.map { [step, $0] } ?? [] }
            try await Output.runFlow(target, hiding: typed) {
                try await UICommands.perform(parsed, on: $0, app: app.app, screenshot: screenshot)
            }
        }
    }
}

struct KeepAwakeCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "keep-awake",
        abstract: "Send periodic taps to an inert app point you choose.",
        discussion: """
            Best effort only: the screen may still auto-lock. --at is required. Choose a point that does nothing in the \
            current app, away from every screen edge. Stops on the first input error, on Ctrl-C or after --for seconds.
            """
    )

    @Option(name: .long, help: "Seconds between taps, 1 to 3600. Choose an interval below the configured Auto-Lock timeout.")
    var interval = 25

    @Option(name: .long, help: "Required inert app point, x,y, at least 64 points from every screen edge.")
    var at: String

    @Option(name: .customLong("for"), help: "Stop after 1 to 86400 seconds instead of running until Ctrl-C.")
    var seconds: Int?

    @OptionGroup var target: TargetOptions

    func run() async throws {
        guard let point = UIStep.parsePoint(at) else {
            throw DeviceLoopError.usage("--at expects x,y for an inert interior app point")
        }
        let intervalMs = try KeepAwakeOptions.milliseconds(seconds: interval, maximumSeconds: 3600, option: "--interval")
        let durationMs = try seconds.map {
            try KeepAwakeOptions.milliseconds(seconds: $0, maximumSeconds: 86400, option: "--for")
        }
        _ = try KeepAwakeOptions(point: point, intervalMs: intervalMs, durationMs: durationMs)
        try await Output.run(target) {
            try await UICommands.keepAwake(
                $0,
                point: point,
                intervalMs: intervalMs,
                durationMs: durationMs
            ) { line in FileHandle.standardError.write(Data((line + "\n").utf8)) }
        }
    }
}

struct LockCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "lock",
        abstract: "Lock the screen by asking Siri (the only public way to lock a device).",
        discussion: """
            Confirms the lock when devicectl reports passcodeRequired. Otherwise prints lockVerified false with a reason \
            and does not send the lock again. A device with no passcode never reports passcodeRequired, so its lock cannot be verified.
            """
    )

    @Option(name: .long, help: "Seconds to wait for devicectl to report the lock, 1 to 300.") var verifySeconds = 8
    @OptionGroup var target: TargetOptions

    func run() async throws {
        try await Output.run(target) { try await SiriCommands.lock($0, verifySeconds: verifySeconds) }
    }
}

struct RunnerCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "runner",
        abstract: "Start, stop or inspect the on-device UI runner.",
        subcommands: [Start.self, Stop.self, Status.self, Operation.self],
        defaultSubcommand: Status.self
    )

    struct Start: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Build the UI runner if needed and start it.")
        @OptionGroup var target: TargetOptions
        func run() async throws { try await Output.run(target) { try await RunnerCommands.start($0) } }
    }

    struct Operation: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Read an operation receipt without sending input.")
        @Argument(help: "Operation ID from the accepted request or error.") var id: String
        @Option(name: .long, help: "Session epoch returned with the operation.") var epoch: String
        @OptionGroup var target: TargetOptions
        func run() async throws {
            try await Output.run(target) { try await RunnerCommands.operation($0, id: id, epoch: epoch) }
        }
    }

    struct Stop: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Stop the UI runner.")
        @OptionGroup var target: TargetOptions
        func run() async throws { try await Output.run(target) { try await RunnerCommands.stop($0) } }
    }

    struct Status: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Show whether the UI runner is running, with its address, uptime, busy state and log.")
        @OptionGroup var target: TargetOptions
        func run() async throws { try await Output.run(target) { try await RunnerCommands.status($0) } }
    }
}
