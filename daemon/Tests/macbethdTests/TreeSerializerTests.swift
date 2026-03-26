import Testing
@testable import macbethd

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
    let child = AXNode(
        handleId: "h_1", role: "AXButton", subrole: nil,
        title: "OK", value: nil, identifier: nil, label: nil,
        enabled: true, focused: false, children: []
    )
    let root = AXNode(
        handleId: "h_0", role: "AXWindow", subrole: nil,
        title: "Test", value: nil, identifier: nil, label: nil,
        enabled: true, focused: true, children: [child]
    )

    let text = serializeTreeAsText(root)
    #expect(text.contains("[window \"Test\" [focused]] h:h_0"))
    #expect(text.contains("  [button \"OK\"] h:h_1"))
}

@Test func serializeJSON() {
    let node = AXNode(
        handleId: "h_0", role: "AXButton", subrole: nil,
        title: "Save", value: nil, identifier: "save-btn", label: nil,
        enabled: true, focused: false, children: []
    )

    let json = serializeTreeAsJSON(node)
    #expect(json["handleId"]?.stringValue == "h_0")
    #expect(json["role"]?.stringValue == "AXButton")
    #expect(json["title"]?.stringValue == "Save")
    #expect(json["identifier"]?.stringValue == "save-btn")
    #expect(json["enabled"]?.boolValue == true)
}
