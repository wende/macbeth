import Testing
@testable import macbethd

private func leaf(handle: String, role: String = "AXButton", title: String? = nil) -> AXNode {
    AXNode(
        handleId: handle, role: role, subrole: nil,
        title: title, value: nil, identifier: nil, label: nil,
        enabled: true, focused: false, children: [],
        truncatedChildren: nil
    )
}

@Test func friendlyRoleNames() {
    #expect(friendlyRoleName("AXButton") == "button")
    #expect(friendlyRoleName("AXWindow") == "window")
    #expect(friendlyRoleName("AXTextField") == "text_field")
    #expect(friendlyRoleName("AXStaticText") == "text")
    #expect(friendlyRoleName("AXMenuItem") == "menu_item")
}

@Test func axRoleNames() {
    #expect(axRoleName("button") == "AXButton")
    #expect(axRoleName("window") == "AXWindow")
    #expect(axRoleName("text_field") == "AXTextField")
    #expect(axRoleName("AXButton") == "AXButton")
}

@Test func serializeSimpleTree() {
    let child = leaf(handle: "h_1", title: "OK")
    let root = AXNode(
        handleId: "h_0", role: "AXWindow", subrole: nil,
        title: "Test", value: nil, identifier: nil, label: nil,
        enabled: true, focused: true, children: [child],
        truncatedChildren: nil
    )

    let text = serializeTreeAsText(root)
    #expect(text.contains("[window \"Test\" [focused]] h:h_0"))
    #expect(text.contains("  [button \"OK\"] h:h_1"))
}

@Test func serializeJSON() {
    let node = AXNode(
        handleId: "h_0", role: "AXButton", subrole: nil,
        title: "Save", value: nil, identifier: "save-btn", label: nil,
        enabled: true, focused: false, children: [],
        truncatedChildren: nil
    )

    let json = serializeTreeAsJSON(node)
    #expect(json["handleId"]?.stringValue == "h_0")
    #expect(json["role"]?.stringValue == "AXButton")
    #expect(json["title"]?.stringValue == "Save")
    #expect(json["identifier"]?.stringValue == "save-btn")
    #expect(json["enabled"]?.boolValue == true)
}

@Test func serializeTreeOmitsTruncationWhenComplete() {
    let root = leaf(handle: "h_0", role: "AXWindow")
    #expect(!serializeTreeAsText(root).contains("[truncated:"))
}

@Test func serializeTreeEmitsTextTruncationMarker() {
    let root = AXNode(
        handleId: "h_0", role: "AXWindow", subrole: nil,
        title: "Test", value: nil, identifier: nil, label: nil,
        enabled: true, focused: false, children: [],
        truncatedChildren: 42
    )
    let text = serializeTreeAsText(root)
    #expect(text.contains("[truncated: ~42 more descendants"))
    #expect(text.contains("re-query with handleId h_0"))
    // Both reviewers flagged the old marker — it steered the model to
    // "re-query with maxDepth 5", but the truncation cause is the maxNodes
    // budget. The new wording recommends a higher maxNodes instead.
    #expect(text.contains("maxNodes"))
    #expect(!text.contains("maxDepth 5"))
    // Marker is its own indented line — the parent line should not include
    // the marker so the model can scan for it independently.
    let lines = text.split(separator: "\n").map(String.init)
    let markerLines = lines.filter { $0.contains("[truncated:") }
    #expect(markerLines.count == 1)
}

@Test func truncationMarkerRecommendsHonestBudgetFloor() {
    // Reviewer flagged: max(truncated + 1, (children + 1) * 2) overcounts
    // shallow children and undercounts deep ones (truncated is an immediate-
    // child estimate, not a full subtree count). The new formula floors at
    // `truncated + 1` (budget that would have walked one more node) with
    // a minimum of 50, and the marker text says "or higher" so the model
    // knows the floor is not a target.

    // Small truncation: floor dominates.
    let small = AXNode(
        handleId: "h_0", role: "AXWindow", subrole: nil,
        title: nil, value: nil, identifier: nil, label: nil,
        enabled: true, focused: false, children: [],
        truncatedChildren: 5
    )
    let smallText = serializeTreeAsText(small)
    #expect(smallText.contains("maxNodes 50 or higher"))

    // Larger truncation: truncated + 1 dominates.
    let big = AXNode(
        handleId: "h_0", role: "AXWindow", subrole: nil,
        title: nil, value: nil, identifier: nil, label: nil,
        enabled: true, focused: false, children: [],
        truncatedChildren: 200
    )
    let bigText = serializeTreeAsText(big)
    #expect(bigText.contains("maxNodes 201 or higher"))
    #expect(!bigText.contains("maxNodes 50"))
}

@Test func parseMaxNodesRejectsFloatsAndZero() throws {
    // Integer survives.
    let ok = try parseMaxNodes(JSONValue.number(5))
    #expect(ok != nil)
    #expect(ok?.tryConsume() == true)
    #expect(ok?.tryConsume() == true)

    // Floats must be rejected — intValue used to silently truncate 1.5 → 1.
    #expect(throws: RPCError.self) {
        _ = try parseMaxNodes(JSONValue.number(1.5))
    }
    #expect(throws: RPCError.self) {
        _ = try parseMaxNodes(JSONValue.number(99.9))
    }

    // Sub-1 integers and JSON null are out.
    #expect(throws: RPCError.self) {
        _ = try parseMaxNodes(JSONValue.number(0))
    }
    #expect(throws: RPCError.self) {
        _ = try parseMaxNodes(JSONValue.number(-3))
    }
    let stringy = JSONValue.string("5")
    #expect(throws: RPCError.self) {
        _ = try parseMaxNodes(stringy)
    }

    // Missing and null omit budget.
    #expect(try parseMaxNodes(nil) == nil)
    #expect(try parseMaxNodes(JSONValue.null) == nil)
}

@Test func serializeJSONEmitsTruncatedChildrenField() {
    let root = AXNode(
        handleId: "h_0", role: "AXWindow", subrole: nil,
        title: nil, value: nil, identifier: nil, label: nil,
        enabled: true, focused: false, children: [],
        truncatedChildren: 7
    )
    let json = serializeTreeAsJSON(root)
    #expect(json["truncatedChildren"]?.intValue == 7)
}

@Test func serializeJSONOmitsTruncatedChildrenWhenComplete() {
    let root = leaf(handle: "h_0")
    let json = serializeTreeAsJSON(root)
    #expect(json["truncatedChildren"] == nil)
}

@Test func nodeBudgetConsumesAndStops() {
    let budget = NodeBudget(3)
    #expect(budget.tryConsume())
    #expect(budget.tryConsume())
    #expect(budget.tryConsume())
    #expect(!budget.tryConsume())
    #expect(budget.isExhausted)
}

@Test func nodeBudgetDoesNotGoBelowZero() {
    let budget = NodeBudget(1)
    #expect(budget.tryConsume())
    #expect(!budget.tryConsume())
    #expect(!budget.tryConsume())
}
