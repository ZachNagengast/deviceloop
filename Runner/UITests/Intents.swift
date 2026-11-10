//  For licensing see accompanying LICENSE file.
//  Copyright 2026 Argmax, Inc. All rights reserved.

import UIKit

/// Runs App Intents of other apps through DeviceLoopIntents.framework, loaded on first use on iOS 27 and later.
@MainActor
enum Intents {
    private static var bridge: (any IntentsBridging)?

    static func run(_ request: IntentRunRequest) async throws -> ActionResult {
        let bridge = try load()
        UIActions.invalidateRefs()
        return try await call { try await bridge.run(JSONEncoder().encode(request)) }
    }

    static func entities(_ request: IntentEntitiesRequest) async throws -> IntentEntitiesResult {
        let bridge = try load()
        return try await call { try await bridge.entities(JSONEncoder().encode(request)) }
    }

    private static func call<T: Decodable>(_ body: () async throws -> Data) async throws -> T {
        let json: Data
        do {
            json = try await body()
        } catch let error as NSError {
            throw RunnerFailure(error.userInfo["code"] as? String ?? "internal", error.localizedDescription)
        }
        return try JSONDecoder().decode(T.self, from: json)
    }

    private static func load() throws -> any IntentsBridging {
        if let bridge { return bridge }
        let version = UIDevice.current.systemVersion
        guard #available(iOS 27.0, *) else {
            throw RunnerFailure("unsupported", "App Intents testing needs iOS 27.0 or later. This device runs iOS \(version).")
        }
        let url = Bundle(for: DeviceLoopRunner.self).bundleURL.appending(path: "Frameworks/DeviceLoopIntents.framework")
        guard let framework = Bundle(url: url) else {
            throw RunnerFailure("unsupported", "This runner has no DeviceLoopIntents.framework.")
        }
        do {
            try framework.loadAndReturnError()
        } catch {
            let reason = (error as NSError).userInfo[NSDebugDescriptionErrorKey] ?? error
            throw RunnerFailure("unsupported", "AppIntentsTesting from this Xcode did not load on iOS \(version): \(reason)")
        }
        guard let type = NSClassFromString("DeviceLoopIntentsBridge") as? NSObject.Type, let loaded = type.init() as? any IntentsBridging
        else {
            throw RunnerFailure("internal", "DeviceLoopIntents.framework has no DeviceLoopIntentsBridge.")
        }
        bridge = loaded
        return loaded
    }
}
