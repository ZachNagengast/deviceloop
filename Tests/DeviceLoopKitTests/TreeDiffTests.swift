//  For licensing see accompanying LICENSE file.
//  Copyright 2026 Argmax, Inc. All rights reserved.

import DeviceLoopProtocol
import Testing

@testable import DeviceLoopKit

@Suite struct TreeDiffTests {
    /// The host fixture screen as `ui tree` read it on an iPhone simulator, frames rounded to 0.1 pt and refs left empty.
    /// `edit` changes the nodes under the window.
    static func fixture(_ edit: (inout [TreeNode]) -> Void = { _ in }) -> TreeResult {
        let title = TreeNode(ref: "", type: "staticText", label: "Test fixture", frame: [20, 116.7, 177, 40.7])
        var nodes = [
            TreeNode(ref: "", type: "navigationBar", id: "Test fixture", frame: [0, 59, 430, 106], children: [title]),
            TreeNode(ref: "", type: "button", id: "fixture.counter.increment", label: "Increment", frame: [16, 181, 100.7, 34.3]),
            TreeNode(ref: "", type: "staticText", id: "fixture.counter.value", label: "Count: 0", frame: [124.7, 188, 65.3, 20.3]),
            TreeNode(ref: "", type: "textField", id: "fixture.text.input", frame: [16, 227.3, 398, 34]),
            TreeNode(ref: "", type: "button", id: "fixture.text.submit", label: "Submit text", frame: [16, 273.3, 111, 34.3]),
            TreeNode(ref: "", type: "staticText", id: "fixture.text.echo", label: "No text submitted", frame: [16, 319.7, 136.3, 20.3]),
            TreeNode(ref: "", type: "button", id: "fixture.navigation.open", label: "Open detail", frame: [16, 352, 111.7, 34.3]),
            TreeNode(ref: "", type: "button", id: "fixture.duplicate.first", label: "Choose", frame: [16, 398.3, 82.3, 34.3]),
            TreeNode(ref: "", type: "button", id: "fixture.duplicate.second", label: "Choose", frame: [122.3, 398.3, 82.3, 34.3]),
            TreeNode(ref: "", type: "staticText", id: "fixture.duplicate.result", label: "Choice: none", frame: [16, 444.7, 100, 20.3]),
        ]
        edit(&nodes)
        let window = TreeNode(ref: "", type: "window", frame: [0, 0, 430, 932], children: nodes)
        let root = TreeNode(ref: "", type: "application", label: "DeviceLoop", frame: [0, 0, 430, 932], children: [window])
        return TreeResult(app: "com.argmaxinc.deviceloop.host", generation: 1, nodeCount: nodes.count + 3, root: root)
    }

    static func index(of id: String, in nodes: [TreeNode]) -> Int {
        nodes.firstIndex { $0.id == id }!
    }

    @Test func identicalTreesDoNotDiffer() {
        let diff = TreeDiff(Self.fixture(), Self.fixture())
        #expect(diff.lines.isEmpty)
        #expect(!diff.differs)
    }

    @Test func movedButtonIsReportedWithItsDelta() {
        let candidate = Self.fixture { $0[Self.index(of: "fixture.counter.increment", in: $0)].frame[0] = 56 }
        let diff = TreeDiff(Self.fixture(), candidate)
        #expect(
            diff.changed == [
                .init(
                    element: .init(type: "button", id: "fixture.counter.increment", label: "Increment", frame: [16, 181, 100.7, 34.3]),
                    property: .frame, baseline: [16, 181, 100.7, 34.3], candidate: [56, 181, 100.7, 34.3], delta: [40, 0, 0, 0])
            ])
        #expect(
            diff.lines == [
                "frame of button \"Increment\" id=fixture.counter.increment: [16,181,100.7,34.3] to [56,181,100.7,34.3], delta 40,0,0,0"
            ])
    }

    @Test func frameTextIsRoundedToATenthOfAPoint() {
        let candidate = Self.fixture {
            $0[Self.index(of: "fixture.counter.value", in: $0)].frame = [124.66666666666666, 188, 62.66666666666666, 20.333333333333343]
        }
        #expect(
            TreeDiff(Self.fixture(), candidate).lines == [
                "frame of staticText \"Count: 0\" id=fixture.counter.value: [124.7,188,65.3,20.3] to [124.7,188,62.7,20.3], "
                    + "delta 0,0,-2.6,0"
            ])
    }

    @Test func movesWithinTheToleranceAreNotReported() {
        let candidate = Self.fixture { $0[Self.index(of: "fixture.counter.increment", in: $0)].frame = [18, 179, 100.7, 34.3] }
        #expect(!TreeDiff(Self.fixture(), candidate).differs)
    }

    @Test func changedLabelIsReported() {
        let candidate = Self.fixture { $0[Self.index(of: "fixture.counter.value", in: $0)].label = "Count: 1" }
        let diff = TreeDiff(Self.fixture(), candidate)
        #expect(diff.changed.map(\.property) == [.label])
        #expect(diff.lines == ["label of staticText \"Count: 0\" id=fixture.counter.value: \"Count: 0\" to \"Count: 1\""])
    }

    @Test func changedValueIsReported() {
        let candidate = Self.fixture { $0[Self.index(of: "fixture.text.input", in: $0)].value = "hello" }
        #expect(TreeDiff(Self.fixture(), candidate).lines == ["value of textField id=fixture.text.input: null to \"hello\""])
    }

    @Test func disabledButtonIsReported() {
        let candidate = Self.fixture { $0[Self.index(of: "fixture.text.submit", in: $0)].enabled = false }
        #expect(
            TreeDiff(Self.fixture(), candidate).lines == ["enabled of button \"Submit text\" id=fixture.text.submit: true to false"])
    }

    @Test func addedAndRemovedElementsAreReported() {
        let candidate = Self.fixture { nodes in
            nodes.remove(at: Self.index(of: "fixture.text.echo", in: nodes))
            nodes.append(TreeNode(ref: "", type: "button", id: "fixture.counter.reset", label: "Reset", frame: [16, 478, 70, 34.3]))
        }
        let diff = TreeDiff(Self.fixture(), candidate)
        #expect(diff.removed.map(\.id) == ["fixture.text.echo"])
        #expect(diff.added.map(\.id) == ["fixture.counter.reset"])
        #expect(diff.changed.isEmpty)
    }

    @Test func ignoredIDIsNotReported() {
        let candidate = Self.fixture { $0[Self.index(of: "fixture.counter.value", in: $0)].label = "Count: 1" }
        let diff = TreeDiff(Self.fixture(), candidate, ignoring: ["fixture.counter.value"])
        #expect(!diff.differs)
        #expect(diff.lines.isEmpty)
    }

    @Test func ignoredIDLeavesOutTheElementsInsideIt() {
        let candidate = Self.fixture { nodes in
            nodes[Self.index(of: "fixture.text.input", in: nodes)].children = [
                TreeNode(ref: "", type: "staticText", label: "hello", frame: [24, 234, 40, 20])
            ]
        }
        #expect(!TreeDiff(Self.fixture(), candidate, ignoring: ["fixture.text.input"]).differs)
    }

    /// The fixture's two Choose buttons without their ids, with and without their label, moved in the candidate.
    @Test(arguments: ["Choose", nil] as [String?])
    func duplicatePairWithoutIDsIsAmbiguous(label: String?) {
        func pair(down offset: Double) -> TreeResult {
            Self.fixture { nodes in
                for id in ["fixture.duplicate.first", "fixture.duplicate.second"] {
                    let index = Self.index(of: id, in: nodes)
                    nodes[index].id = nil
                    nodes[index].label = label
                    nodes[index].frame[1] += offset
                }
            }
        }
        let diff = TreeDiff(pair(down: 0), pair(down: 40))
        #expect(diff.ambiguous == [.init(type: "button", label: label, baseline: 2, candidate: 2)])
        #expect(diff.added.isEmpty && diff.removed.isEmpty && diff.changed.isEmpty)
        #expect(!diff.differs)
    }

    @Test func ambiguousGroupWithDifferentCountsDiffers() {
        let baseline = Self.fixture { $0[Self.index(of: "fixture.duplicate.second", in: $0)].id = "fixture.duplicate.first" }
        let candidate = Self.fixture { _ = $0.remove(at: Self.index(of: "fixture.duplicate.second", in: $0)) }
        let diff = TreeDiff(baseline, candidate)
        #expect(diff.ambiguous == [.init(type: "button", id: "fixture.duplicate.first", baseline: 2, candidate: 1)])
        #expect(diff.differs)
        #expect(diff.lines == ["ambiguous, not compared: button id=fixture.duplicate.first 2 vs 1"])
    }
}
