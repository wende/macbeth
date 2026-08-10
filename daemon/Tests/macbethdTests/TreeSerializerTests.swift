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
    // Marker is its own indented line — the parent line should not include
    // the marker so the model can scan for it independently.
    let lines = text.split(separator: "\n").map(String.init)
    let markerLines = lines.filter { $0.contains("[truncated:") }
    #expect(markerLines.count == 1)
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
