//  For licensing see accompanying LICENSE file.
//  Copyright 2026 Argmax, Inc. All rights reserved.

import AppIntents
import Foundation
import Observation

struct FixtureTask: Codable {
    let id: String
    let title: String
}

/// The fixture's tasks, saved as JSON in this app's Application Support directory.
@MainActor @Observable
final class FixtureTaskStore {
    static let shared = FixtureTaskStore()

    private(set) var tasks: [FixtureTask]
    private let file = URL.applicationSupportDirectory.appending(path: "fixture-tasks.json")

    private init() {
        tasks = (try? JSONDecoder().decode([FixtureTask].self, from: Data(contentsOf: file))) ?? []
    }

    func add(title: String) throws -> FixtureTask {
        let task = FixtureTask(id: UUID().uuidString, title: title)
        try save(tasks + [task])
        return task
    }

    func reset() throws {
        try save([])
    }

    private func save(_ updated: [FixtureTask]) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(updated).write(to: file, options: .atomic)
        tasks = updated
    }
}

struct FixtureTaskEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Fixture Task"
    static let defaultQuery = FixtureTaskQuery()

    let id: String
    @Property(title: "Title") var title: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)")
    }

    init(_ task: FixtureTask) {
        id = task.id
        title = task.title
    }
}

/// Finds tasks by ID, or by a case-insensitive substring of the title.
struct FixtureTaskQuery: EntityStringQuery {
    @MainActor func entities(for identifiers: [String]) async throws -> [FixtureTaskEntity] {
        FixtureTaskStore.shared.tasks.filter { identifiers.contains($0.id) }.map(FixtureTaskEntity.init)
    }

    @MainActor func entities(matching string: String) async throws -> [FixtureTaskEntity] {
        FixtureTaskStore.shared.tasks.filter { $0.title.localizedCaseInsensitiveContains(string) }.map(FixtureTaskEntity.init)
    }

    @MainActor func suggestedEntities() async throws -> [FixtureTaskEntity] {
        FixtureTaskStore.shared.tasks.map(FixtureTaskEntity.init)
    }
}

struct AddFixtureTaskIntent: AppIntent {
    static let title: LocalizedStringResource = "Add Fixture Task"

    @Parameter(title: "Title") var title: String

    init() {}

    init(title: String) {
        self.title = title
    }

    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<FixtureTaskEntity> & ProvidesDialog {
        let task = try FixtureTaskStore.shared.add(title: title)
        return .result(value: FixtureTaskEntity(task), dialog: "Added \(title).")
    }
}

/// Removes every task. Hidden from Shortcuts and Siri.
struct ResetFixtureTasksIntent: AppIntent {
    static let title: LocalizedStringResource = "Reset Fixture Tasks"
    static let isDiscoverable = false

    @MainActor func perform() async throws -> some IntentResult {
        try FixtureTaskStore.shared.reset()
        return .result()
    }
}

struct FixtureShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AddFixtureTaskIntent(),
            phrases: ["Add a task in \(.applicationName)", "Add a fixture task in \(.applicationName)"],
            shortTitle: "Add Task",
            systemImageName: "plus"
        )
    }
}
