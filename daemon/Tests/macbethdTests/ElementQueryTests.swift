import Testing
import Foundation
@testable import macbethd

/// Stand-in for an AX subtree. `findMatchingDescendants` is generic over the node type
/// so the traversal rules can be exercised without a live app.
private final class FakeNode {
    let name: String
    let children: [FakeNode]

    init(_ name: String, _ children: [FakeNode] = []) {
        self.name = name
        self.children = children
    }
}

private func find(
    _ root: FakeNode,
    matching predicate: @escaping (FakeNode) -> Bool,
    maxDepth: Int = 50
) -> [String] {
    findMatchingDescendants(
        root: root,
        children: { $0.children },
        isMatch: predicate,
        maxDepth: maxDepth
    ).map(\.name)
}

private func named(_ name: String) -> (FakeNode) -> Bool {
    { $0.name == name }
}

@Test func findsMatchesInDepthFirstOrder() {
    // query_tree prints depth-first, and `index: N` selects positionally from these
    // results — so a breadth-first descent would select a different element than the
    // one the user counted off the printed tree.
    let tree = FakeNode("root", [
        FakeNode("branchA", [
            FakeNode("target"),  // depth 2, DFS position 0
        ]),
        FakeNode("target"),  // depth 1, BFS would rank this first
    ])

    #expect(find(tree, matching: named("target")).count == 2)

    let deepFirst = findMatchingDescendants(
        root: tree,
        children: { $0.children },
        isMatch: named("target")
    )
    #expect(deepFirst[0] === tree.children[0].children[0])
    #expect(deepFirst[1] === tree.children[1])
}

@Test func descentPassesThroughNonMatchingWrappers() {
    // Query paths name only the elements they care about; wrapper containers between
    // steps must not block resolution.
    let tree = FakeNode("root", [
        FakeNode("group", [
            FakeNode("scrollArea", [
                FakeNode("button"),
            ]),
        ]),
    ])

    #expect(find(tree, matching: named("button")) == ["button"])
}

@Test func doesNotRecurseIntoMatchedElements() {
    // A match scopes the subtree for the next query step, so nested matches of the
    // same step must not be collected.
    let tree = FakeNode("root", [
        FakeNode("cell", [
            FakeNode("cell"),
        ]),
    ])

    #expect(find(tree, matching: named("cell")).count == 1)
}

@Test func returnsEmptyWhenNothingMatches() {
    let tree = FakeNode("root", [FakeNode("button")])
    #expect(find(tree, matching: named("textField")).isEmpty)
}

@Test func rootItselfIsNeverAMatch() {
    // Resolution descends from the current scope; the scope element is not a candidate.
    let tree = FakeNode("button", [FakeNode("label")])
    #expect(find(tree, matching: named("button")).isEmpty)
}

@Test func stopsDescendingPastMaxDepth() {
    // root -> d1 -> d2 -> target, so target sits below a maxDepth of 1.
    let tree = FakeNode("root", [
        FakeNode("d1", [
            FakeNode("d2", [
                FakeNode("target"),
            ]),
        ]),
    ])

    #expect(find(tree, matching: named("target"), maxDepth: 1).isEmpty)
    #expect(find(tree, matching: named("target"), maxDepth: 50) == ["target"])
}

@Test func collectsSiblingMatchesInOrder() {
    let tree = FakeNode("root", [
        FakeNode("row", [FakeNode("cell")]),
        FakeNode("row", [FakeNode("cell")]),
    ])

    #expect(find(tree, matching: named("cell")).count == 2)
}
