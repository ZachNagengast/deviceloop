//  For licensing see accompanying LICENSE file.
//  Copyright 2026 Argmax, Inc. All rights reserved.

import SwiftUI

/// Test app for Siri scenarios.
@main
struct SiriFixtureApp: App {
    var body: some Scene {
        WindowGroup {
            FixtureTaskList()
        }
    }
}

/// Lists the stored tasks in order, each with the identifier siri.fixture.task.<position from 1>.
struct FixtureTaskList: View {
    private let store = FixtureTaskStore.shared

    var body: some View {
        NavigationStack {
            List(Array(store.tasks.enumerated()), id: \.element.id) { index, task in
                Text(task.title)
                    .accessibilityIdentifier("siri.fixture.task.\(index + 1)")
            }
            .overlay {
                if store.tasks.isEmpty {
                    ContentUnavailableView("No tasks", systemImage: "checklist")
                }
            }
            .navigationTitle("Fixture Tasks")
        }
    }
}
