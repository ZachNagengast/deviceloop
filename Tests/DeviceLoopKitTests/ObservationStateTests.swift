//  For licensing see accompanying LICENSE file.
//  Copyright 2026 Argmax, Inc. All rights reserved.

import DeviceLoopProtocol
import Testing

@Suite struct ObservationStateTests {
    @Test func anotherSnapshotCannotRetargetAnOldReference() {
        var refs = ObservationReferences<String>()
        refs.begin(app: "fixture", orientation: "portrait")
        let original = refs.insert("original button")
        refs.begin(app: "fixture", orientation: "portrait")
        let replacement = refs.insert("different button")
        #expect(original != replacement)
        #expect(refs.value(for: original, app: "fixture", orientation: "portrait") == nil)
        #expect(refs.value(for: replacement, app: "fixture", orientation: "portrait") == "different button")
        #expect(refs.generation == 2)
    }

    @Test func anotherRunnerCannotReuseAnOldReference() {
        var first = ObservationReferences<Int>()
        var restarted = ObservationReferences<Int>()
        first.begin(app: "fixture", orientation: "portrait")
        restarted.begin(app: "fixture", orientation: "portrait")
        let old = first.insert(1)
        let new = restarted.insert(1)
        #expect(old != new)
        #expect(restarted.value(for: old, app: "fixture", orientation: "portrait") == nil)
    }

    @Test func referencesAreScopedToTheObservedApp() {
        var refs = ObservationReferences<Int>()
        refs.begin(app: "first.app", orientation: "portrait")
        let ref = refs.insert(1)
        #expect(refs.value(for: ref, app: "first.app", orientation: "portrait") == 1)
        #expect(refs.value(for: ref, app: "second.app", orientation: "portrait") == nil)
    }

    @Test func invalidationRejectsAllPreviousTargets() {
        var refs = ObservationReferences<Int>()
        refs.begin(app: "fixture", orientation: "portrait")
        let first = refs.insert(1)
        let second = refs.insert(2)
        refs.invalidate()
        #expect(refs.value(for: first, app: "fixture", orientation: "portrait") == nil)
        #expect(refs.value(for: second, app: "fixture", orientation: "portrait") == nil)
        refs.begin(app: "fixture", orientation: "portrait")
        let replacement = refs.insert(3)
        #expect(replacement != first)
    }

    @Test func rotationRejectsReferencesFromTheEarlierOrientation() {
        var refs = ObservationReferences<Int>()
        refs.begin(app: "fixture", orientation: "portrait")
        let ref = refs.insert(1)
        #expect(refs.value(for: ref, app: "fixture", orientation: "portrait") == 1)
        #expect(refs.value(for: ref, app: "fixture", orientation: "landscapeLeft") == nil)
    }

    @Test func stabilityRequiresSuccessfulSamplesAcrossTheQuietInterval() {
        var stability = ObservationStability(quietDuration: 1)
        let sample1 = stability.observe(hash: 42, at: 10)
        #expect(!sample1)
        let sample2 = stability.observe(hash: 42, at: 10.9)
        #expect(!sample2)
        let sample3 = stability.observe(hash: 42, at: 11)
        #expect(sample3)
    }

    @Test func missingSnapshotsNeverEstablishStability() {
        var stability = ObservationStability(quietDuration: 1)
        let sample4 = stability.observe(hash: nil, at: 10)
        #expect(!sample4)
        let sample5 = stability.observe(hash: nil, at: 20)
        #expect(!sample5)
    }

    @Test func failedSnapshotRestartsTheQuietInterval() {
        var stability = ObservationStability(quietDuration: 1)
        let sample6 = stability.observe(hash: 42, at: 10)
        #expect(!sample6)
        let sample7 = stability.observe(hash: nil, at: 10.9)
        #expect(!sample7)
        let sample8 = stability.observe(hash: 42, at: 11)
        #expect(!sample8)
        let sample9 = stability.observe(hash: 42, at: 11.9)
        #expect(!sample9)
        let sample10 = stability.observe(hash: 42, at: 12)
        #expect(sample10)
    }

    @Test func changedSnapshotRestartsTheQuietInterval() {
        var stability = ObservationStability(quietDuration: 1)
        let sample11 = stability.observe(hash: 42, at: 10)
        #expect(!sample11)
        let sample12 = stability.observe(hash: 43, at: 10.9)
        #expect(!sample12)
        let sample13 = stability.observe(hash: 43, at: 11)
        #expect(!sample13)
        let sample14 = stability.observe(hash: 43, at: 12)
        #expect(sample14)
    }
}
