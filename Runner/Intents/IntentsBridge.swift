//  For licensing see accompanying LICENSE file.
//  Copyright 2026 Argmax, Inc. All rights reserved.

import AppIntentsTesting
import Foundation

/// Runs App Intents and entity queries of other apps with AppIntentsTesting.
@objc(DeviceLoopIntentsBridge) @MainActor
final class IntentsBridge: NSObject, IntentsBridging {
    func run(_ request: Data) async throws -> Data {
        let request = try JSONDecoder().decode(IntentRunRequest.self, from: request)
        let definitions = IntentDefinitions(bundleIdentifier: request.app)
        var intent = definitions.intents[request.intent].makeIntent()
        for (name, value) in request.params ?? [:] {
            switch value {
                case .string(let string): intent[dynamicMember: name] = string
                case .number(let number):
                    intent[dynamicMember: name] = Int(exactly: number).map { $0 as any IntentValueExpressing } ?? number
                case .bool(let bool): intent[dynamicMember: name] = bool
                case .entity(let type, let id): intent[dynamicMember: name] = definitions.entities[type].makeReference(identifier: id)
            }
        }
        let eventTime = Date().timeIntervalSince1970
        do {
            try await intent.run()
        } catch {
            throw failure("intent_failed", "\(error)")
        }
        return try JSONEncoder().encode(ActionResult(eventTime: eventTime))
    }

    func entities(_ request: Data) async throws -> Data {
        let request = try JSONDecoder().decode(IntentEntitiesRequest.self, from: request)
        let definition = IntentDefinitions(bundleIdentifier: request.app).entities[request.entity]
        let found: [AnyAppEntity]
        do {
            if let matching = request.matching {
                found = try await definition.entities(matching: matching)
            } else {
                found = try await definition.allEntities()
            }
        } catch {
            throw failure("intent_failed", "\(error)")
        }
        let entities = try found.map { entity in
            var properties: [String: String] = [:]
            for name in request.properties ?? [] {
                do {
                    properties[name] = try entity[dynamicMember: name] as String
                } catch {
                    throw failure("bad_request", "Could not read property \(name) of \(request.entity) as a string: \(error)")
                }
            }
            return IntentEntity(id: entity.identifier.instanceIdentifier, properties: properties)
        }
        return try JSONEncoder().encode(IntentEntitiesResult(count: entities.count, entities: entities))
    }

    private func failure(_ code: String, _ message: String) -> NSError {
        NSError(domain: "DeviceLoopIntents", code: 0, userInfo: ["code": code, NSLocalizedDescriptionKey: message])
    }
}
