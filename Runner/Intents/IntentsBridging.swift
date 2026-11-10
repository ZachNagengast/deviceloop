//  For licensing see accompanying LICENSE file.
//  Copyright 2026 Argmax, Inc. All rights reserved.

import Foundation

/// Implemented by DeviceLoopIntents.framework. Takes and returns wire types as JSON.
/// A thrown NSError carries the wire error code in `userInfo["code"]`.
@objc(DeviceLoopIntentsBridging) @MainActor
protocol IntentsBridging {
    /// Takes an `IntentRunRequest` and returns an `ActionResult`.
    func run(_ request: Data) async throws -> Data
    /// Takes an `IntentEntitiesRequest` and returns an `IntentEntitiesResult`.
    func entities(_ request: Data) async throws -> Data
}
