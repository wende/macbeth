@preconcurrency import ApplicationServices
import Foundation

/// Register native Accessibility-based menu inspection and selection methods.
/// These deliberately avoid System Events and AppleScript so menu automation uses
/// the same app identity, permission, and bounded AX messaging path as other actions.
func registerMenuBarMethods(
    dispatcher: Dispatcher,
    appManager: AppConnectionManager
) {
    Task {
        await dispatcher.register(method: "list_menu_bar") { params in
            let (appElement, connection) = try await menuApp(
                params: params,
                appManager: appManager
            )
            let menuBar = try findMenuBar(in: appElement, connection: connection)
            let output = serializeMenuBar(menuBar)
            return .object(["menu": .string(output)])
        }

        await dispatcher.register(method: "select_menu_item") { params in
            guard let obj = params?.objectValue,
                  let pathValues = obj["menuPath"]?.arrayValue else {
                throw RPCError.invalidParams("Missing 'menuPath'")
            }
            let menuPath = pathValues.compactMap(\.stringValue)
            guard menuPath.count == pathValues.count, menuPath.count >= 2 else {
                throw RPCError.invalidParams(
                    "menuPath must contain at least a menu bar item and a menu item"
                )
            }

            let (appElement, connection) = try await menuApp(
                params: params,
                appManager: appManager
            )
            let menuBar = try findMenuBar(in: appElement, connection: connection)
            let item = try resolveMenuItem(
                path: menuPath,
                menuBar: menuBar,
                connection: connection
            )

            if getBoolAttribute(item, kAXEnabledAttribute) == false {
                throw RPCError.menuItemDisabled(
                    "Menu item is disabled: \(menuPath.joined(separator: " > ")) "
                    + "(app: \(menuIdentity(connection)))"
                )
            }

            let result = AXUIElementPerformAction(item, kAXPressAction as CFString)
            switch result {
            case .success:
                return .object(["selected": .string(menuPath.joined(separator: " > "))])
            case .cannotComplete:
                throw RPCError.appBusy(
                    "Target app did not complete AXPress for "
                    + "\(menuPath.joined(separator: " > ")) "
                    + "(AX error \(result.rawValue), app: \(menuIdentity(connection)))"
                )
            default:
                throw RPCError.actionFailed(
                    "AXPress failed for \(menuPath.joined(separator: " > ")) "
                    + "(AX error \(result.rawValue), app: \(menuIdentity(connection)))"
                )
            }
        }
    }
}

private func menuApp(
    params: JSONValue?,
    appManager: AppConnectionManager
) async throws -> (AXUIElement, AppConnectionManager.Connection) {
    guard AXIsProcessTrusted() else {
        throw RPCError.permissionDenied(
            "Accessibility permission is required for menu automation. "
            + "Run `npx macbeth doctor` and grant Accessibility access."
        )
    }
    guard let obj = params?.objectValue,
          let appHandle = obj["appHandle"]?.stringValue else {
        throw RPCError.invalidParams("Missing 'appHandle'")
    }
    guard let connection = await appManager.get(appHandle) else {
        throw RPCError.appNotFound("Invalid app handle: \(appHandle)")
    }
    return (connection.appElement.element, connection)
}

private func findMenuBar(
    in app: AXUIElement,
    connection: AppConnectionManager.Connection
) throws -> AXUIElement {
    let candidates = getChildren(app).filter {
        getStringAttribute($0, kAXRoleAttribute) == "AXMenuBar"
    }
    if let populated = candidates.first(where: { menuBarItems($0).contains(where: menuElementHasTitle) }) {
        return populated
    }
    if let first = candidates.first { return first }
    throw RPCError.axLookupFailed(
        "No AXMenuBar exposed by \(menuIdentity(connection)); "
        + "the app may be launching, busy, or not exposing native menus."
    )
}

private func menuBarItems(_ menuBar: AXUIElement) -> [AXUIElement] {
    getChildren(menuBar).filter {
        getStringAttribute($0, kAXRoleAttribute) == "AXMenuBarItem"
    }
}

private func menuItems(_ menu: AXUIElement) -> [AXUIElement] {
    getChildren(menu).filter {
        getStringAttribute($0, kAXRoleAttribute) == "AXMenuItem"
    }
}

private func childMenu(of element: AXUIElement) -> AXUIElement? {
    getChildren(element).first {
        getStringAttribute($0, kAXRoleAttribute) == "AXMenu"
    }
}

private func menuElementHasTitle(_ element: AXUIElement) -> Bool {
    guard let title = getStringAttribute(element, kAXTitleAttribute) else { return false }
    return !title.isEmpty
}

private func resolveMenuItem(
    path: [String],
    menuBar: AXUIElement,
    connection: AppConnectionManager.Connection
) throws -> AXUIElement {
    let topLevel = menuBarItems(menuBar)
    guard let menuBarItem = findTitledMenuElement(in: topLevel, requested: path[0]) else {
        throw menuNotFound(path: path, failedAt: path[0], siblings: topLevel, connection: connection)
    }
    guard var menu = childMenu(of: menuBarItem) else {
        throw RPCError.axLookupFailed(
            "Menu bar item \(path[0]) has no AXMenu "
            + "(app: \(menuIdentity(connection)))"
        )
    }

    for (index, component) in path.dropFirst().enumerated() {
        let siblings = menuItems(menu)
        guard let item = findTitledMenuElement(in: siblings, requested: component) else {
            throw menuNotFound(
                path: path,
                failedAt: component,
                siblings: siblings,
                connection: connection
            )
        }
        if index == path.count - 2 {
            return item
        }
        guard let submenu = childMenu(of: item) else {
            throw RPCError.menuItemNotFound(
                "Menu path stops at \(component); it has no submenu "
                + "(requested: \(path.joined(separator: " > ")), "
                + "app: \(menuIdentity(connection)))"
            )
        }
        menu = submenu
    }

    throw RPCError.menuItemNotFound("Menu path did not resolve")
}

/// Prefer an exact raw title match, then a normalized case-insensitive one.
/// Agents often send `...` while macOS menus use the typographic `…`.
func findTitledMenuElement(in elements: [AXUIElement], requested: String) -> AXUIElement? {
    if let exact = elements.first(where: {
        getStringAttribute($0, kAXTitleAttribute) == requested
    }) {
        return exact
    }
    return elements.first(where: {
        menuTitleMatches(getStringAttribute($0, kAXTitleAttribute), requested: requested)
    })
}

func normalizeMenuTitle(_ title: String) -> String {
    title
        .replacingOccurrences(of: "...", with: "\u{2026}")
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

func menuTitleMatches(_ actual: String?, requested: String) -> Bool {
    guard let actual else { return false }
    let left = normalizeMenuTitle(actual)
    let right = normalizeMenuTitle(requested)
    return left.caseInsensitiveCompare(right) == .orderedSame
}

private func menuNotFound(
    path: [String],
    failedAt: String,
    siblings: [AXUIElement],
    connection: AppConnectionManager.Connection
) -> RPCError {
    let available = siblings.compactMap {
        getStringAttribute($0, kAXTitleAttribute)
    }.filter { !$0.isEmpty }.prefix(12).joined(separator: ", ")
    let suffix = available.isEmpty ? "" : "; available here: \(available)"
    return .menuItemNotFound(
        "Menu component not found: \(failedAt) "
        + "(requested: \(path.joined(separator: " > ")), "
        + "app: \(menuIdentity(connection))\(suffix))"
    )
}

private func serializeMenuBar(_ menuBar: AXUIElement) -> String {
    var lines: [String] = []
    for item in menuBarItems(menuBar) {
        guard let title = getStringAttribute(item, kAXTitleAttribute),
              !title.isEmpty, title != "Apple" else { continue }
        lines.append(title)
        if let menu = childMenu(of: item) {
            appendMenu(menu, depth: 1, lines: &lines)
        }
    }
    return lines.isEmpty ? "No menu items found." : lines.joined(separator: "\n")
}

private func appendMenu(_ menu: AXUIElement, depth: Int, lines: inout [String]) {
    guard depth <= 4 else { return }
    let indent = String(repeating: "  ", count: depth)
    for item in menuItems(menu) {
        let title = getStringAttribute(item, kAXTitleAttribute) ?? ""
        if title.isEmpty {
            lines.append("\(indent)---")
            continue
        }
        let disabled = getBoolAttribute(item, kAXEnabledAttribute) == false
        lines.append("\(indent)\(title)\(disabled ? " [disabled]" : "")")
        if let submenu = childMenu(of: item) {
            appendMenu(submenu, depth: depth + 1, lines: &lines)
        }
    }
}

private func menuIdentity(_ connection: AppConnectionManager.Connection) -> String {
    let name = connection.appName ?? "unknown"
    let bundle = connection.bundleId.map { ", bundle: \($0)" } ?? ""
    return "\(name), pid: \(connection.pid)\(bundle)"
}
