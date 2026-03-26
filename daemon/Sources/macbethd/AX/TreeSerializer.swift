import Foundation

/// Serialize an AXNode tree to indented text (LLM-friendly format).
func serializeTreeAsText(_ node: AXNode, indent: Int = 0) -> String {
    var result = ""
    let prefix = String(repeating: "  ", count: indent)

    // Build the line: [role "title" value:"val"] h:handle_id
    var parts: [String] = [friendlyRoleName(node.role)]

    if let title = node.title, !title.isEmpty {
        parts.append("\"\(title)\"")
    }

    if let value = node.value, !value.isEmpty {
        parts.append("value:\"\(truncate(value, maxLen: 50))\"")
    }

    if let identifier = node.identifier, !identifier.isEmpty {
        parts.append("id:\"\(identifier)\"")
    }

    var flags: [String] = []
    if !node.enabled { flags.append("disabled") }
    if node.focused { flags.append("focused") }

    let flagStr = flags.isEmpty ? "" : " [\(flags.joined(separator: ", "))]"

    result += "\(prefix)[\(parts.joined(separator: " "))\(flagStr)] h:\(node.handleId)\n"

    for child in node.children {
        result += serializeTreeAsText(child, indent: indent + 1)
    }

    return result
}

/// Serialize an AXNode tree to a JSONValue (for programmatic use).
func serializeTreeAsJSON(_ node: AXNode) -> JSONValue {
    var obj: [String: JSONValue] = [
        "handleId": .string(node.handleId),
        "role": .string(node.role),
        "enabled": .bool(node.enabled),
        "focused": .bool(node.focused),
    ]

    if let title = node.title { obj["title"] = .string(title) }
    if let value = node.value { obj["value"] = .string(value) }
    if let identifier = node.identifier { obj["identifier"] = .string(identifier) }
    if let label = node.label { obj["label"] = .string(label) }
    if let subrole = node.subrole { obj["subrole"] = .string(subrole) }

    if !node.children.isEmpty {
        obj["children"] = .array(node.children.map { serializeTreeAsJSON($0) })
    }

    return .object(obj)
}

// MARK: - Helpers

/// Map AX role strings to shorter, friendlier names.
func friendlyRoleName(_ axRole: String) -> String {
    let map: [String: String] = [
        "AXApplication": "app",
        "AXWindow": "window",
        "AXSheet": "sheet",
        "AXDialog": "dialog",
        "AXButton": "button",
        "AXRadioButton": "radio",
        "AXCheckBox": "checkbox",
        "AXPopUpButton": "popup",
        "AXMenuButton": "menu_button",
        "AXTextField": "text_field",
        "AXTextArea": "text_area",
        "AXStaticText": "text",
        "AXImage": "image",
        "AXGroup": "group",
        "AXSplitGroup": "split_group",
        "AXScrollArea": "scroll_area",
        "AXScrollBar": "scrollbar",
        "AXTable": "table",
        "AXRow": "row",
        "AXColumn": "column",
        "AXCell": "cell",
        "AXOutline": "outline",
        "AXDisclosureTriangle": "disclosure",
        "AXList": "list",
        "AXTabGroup": "tab_group",
        "AXTab": "tab",
        "AXToolbar": "toolbar",
        "AXMenuBar": "menubar",
        "AXMenu": "menu",
        "AXMenuItem": "menu_item",
        "AXSlider": "slider",
        "AXValueIndicator": "value_indicator",
        "AXProgressIndicator": "progress",
        "AXComboBox": "combo_box",
        "AXColorWell": "color_well",
        "AXSplitter": "splitter",
        "AXLayoutArea": "layout",
        "AXLayoutItem": "layout_item",
        "AXLink": "link",
        "AXHelpTag": "help_tag",
        "AXWebArea": "web_area",
        "AXBrowser": "browser",
        "AXRuler": "ruler",
    ]
    return map[axRole] ?? axRole.replacingOccurrences(of: "AX", with: "").lowercased()
}

/// Reverse map: friendly name → AX role.
func axRoleName(_ friendlyName: String) -> String {
    let map: [String: String] = [
        "app": "AXApplication",
        "window": "AXWindow",
        "sheet": "AXSheet",
        "dialog": "AXDialog",
        "button": "AXButton",
        "radio": "AXRadioButton",
        "checkbox": "AXCheckBox",
        "popup": "AXPopUpButton",
        "menu_button": "AXMenuButton",
        "text_field": "AXTextField",
        "text_area": "AXTextArea",
        "text": "AXStaticText",
        "image": "AXImage",
        "group": "AXGroup",
        "split_group": "AXSplitGroup",
        "scroll_area": "AXScrollArea",
        "scrollbar": "AXScrollBar",
        "table": "AXTable",
        "row": "AXRow",
        "column": "AXColumn",
        "cell": "AXCell",
        "outline": "AXOutline",
        "disclosure": "AXDisclosureTriangle",
        "list": "AXList",
        "tab_group": "AXTabGroup",
        "tab": "AXTab",
        "toolbar": "AXToolbar",
        "menubar": "AXMenuBar",
        "menu": "AXMenu",
        "menu_item": "AXMenuItem",
        "slider": "AXSlider",
        "value_indicator": "AXValueIndicator",
        "progress": "AXProgressIndicator",
        "combo_box": "AXComboBox",
        "color_well": "AXColorWell",
        "splitter": "AXSplitter",
        "layout": "AXLayoutArea",
        "layout_item": "AXLayoutItem",
        "link": "AXLink",
        "help_tag": "AXHelpTag",
        "web_area": "AXWebArea",
        "browser": "AXBrowser",
        "ruler": "AXRuler",
    ]
    // Try direct lookup, then try with AX prefix, then return as-is
    if let axRole = map[friendlyName] { return axRole }
    if friendlyName.hasPrefix("AX") { return friendlyName }
    return "AX" + friendlyName.prefix(1).uppercased() + friendlyName.dropFirst()
}

private func truncate(_ str: String, maxLen: Int) -> String {
    if str.count <= maxLen { return str }
    return String(str.prefix(maxLen - 3)) + "..."
}
