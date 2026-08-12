@preconcurrency import ApplicationServices
import Foundation

private let formRoles: Set<String> = [
    "AXTextField", "AXTextArea", "AXSlider", "AXCheckBox",
    "AXRadioButton", "AXPopUpButton", "AXComboBox",
    "AXIncrementor", "AXStepper", "AXValueIndicator",
]

func registerReadForm(
    dispatcher: Dispatcher,
    appManager: AppConnectionManager,
    handleTable: HandleTable
) {
    Task {
        await dispatcher.register(method: "read_form") { params in
            guard let obj = params?.objectValue,
                  let appHandle = obj["appHandle"]?.stringValue else {
                throw RPCError.invalidParams("Missing 'appHandle'")
            }

            let maxDepth = Int(obj["maxDepth"]?.numberValue ?? 10)
            let pin = obj["pin"]?.boolValue ?? false
            let root: AXUIElement

            if let handleId = obj["handleId"]?.stringValue {
                root = try await resolveLiveHandle(handleId, in: handleTable).element
            } else if let querySteps = QueryStep.fromArray(obj["query"]) {
                guard let appElement = await appManager.getElement(appHandle) else {
                    throw RPCError.appNotFound("Invalid app handle: \(appHandle)")
                }
                guard let conn = await appManager.get(appHandle) else {
                    throw RPCError.appNotFound("Invalid app handle: \(appHandle)")
                }
                let path = QueryPath(steps: querySteps)
                let (element, _) = try await resolveQuery(
                    path: path, root: appElement.element, pid: conn.pid, handleTable: handleTable,
                    pin: pin
                )
                root = element
            } else {
                guard let appElement = await appManager.getElement(appHandle) else {
                    throw RPCError.appNotFound("Invalid app handle: \(appHandle)")
                }
                root = appElement.element
            }

            guard let conn = await appManager.get(appHandle) else {
                throw RPCError.appNotFound("Invalid app handle: \(appHandle)")
            }

            let fields = await collectFormFields(
                element: root,
                pid: conn.pid,
                handleTable: handleTable,
                depth: 0,
                maxDepth: maxDepth,
                pin: pin
            )

            return .object(["fields": .array(fields)])
        }
    }
}

private func collectFormFields(
    element: AXUIElement,
    pid: pid_t,
    handleTable: HandleTable,
    depth: Int,
    maxDepth: Int,
    pin: Bool
) async -> [JSONValue] {
    var fields: [JSONValue] = []
    let role = getStringAttribute(element, kAXRoleAttribute) ?? "unknown"

    if formRoles.contains(role) {
        let field = await buildFormField(element: element, role: role, pid: pid, handleTable: handleTable, pin: pin)
        fields.append(field)
    }

    guard depth < maxDepth else { return fields }

    let children = getChildren(element)
    for child in children {
        let childFields = await collectFormFields(
            element: child,
            pid: pid,
            handleTable: handleTable,
            depth: depth + 1,
            maxDepth: maxDepth,
            pin: pin
        )
        fields.append(contentsOf: childFields)
    }

    return fields
}

private func buildFormField(
    element: AXUIElement,
    role: String,
    pid: pid_t,
    handleTable: HandleTable,
    pin: Bool
) async -> JSONValue {
    let value = getValueAsString(element)
    let title = getStringAttribute(element, kAXTitleAttribute)
    let label = inferLabel(element)
    let identifier = getStringAttribute(element, kAXIdentifierAttribute)

    let handleId = await handleTable.store(
        SendableElement(element),
        pid: pid,
        fingerprint: ElementFingerprint(
            role: role,
            subrole: getStringAttribute(element, kAXSubroleAttribute),
            identifier: identifier
        ),
        pinned: pin
    )
    let enabled = getBoolAttribute(element, kAXEnabledAttribute) ?? true

    var settableRef: DarwinBoolean = false
    let settableResult = AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settableRef)
    let isSettable = settableResult == .success && settableRef.boolValue

    let kind = classifyKind(role: role)

    var obj: [String: JSONValue] = [
        "handleId": .string(handleId),
        "role": .string(friendlyRole(role)),
        "kind": .string(kind),
        "editable": .bool(isSettable),
        "enabled": .bool(enabled),
    ]

    if let title { obj["title"] = .string(title) }
    if let value { obj["value"] = .string(value) }
    if let label { obj["label"] = .string(label) }
    if let identifier { obj["identifier"] = .string(identifier) }

    if role == "AXSlider" {
        if let minVal = getNumberAttribute(element, "AXMinValue") {
            obj["min"] = .number(minVal)
        }
        if let maxVal = getNumberAttribute(element, "AXMaxValue") {
            obj["max"] = .number(maxVal)
        }
    }

    return .object(obj)
}

private func inferLabel(_ element: AXUIElement) -> String? {
    var titleUIRef: CFTypeRef?
    let titleUIResult = AXUIElementCopyAttributeValue(element, "AXTitleUIElement" as CFString, &titleUIRef)
    if titleUIResult == .success, let titleElement = titleUIRef {
        let titleEl = titleElement as! AXUIElement
        if let text = getStringAttribute(titleEl, kAXValueAttribute) { return text }
        if let text = getStringAttribute(titleEl, kAXTitleAttribute) { return text }
    }

    if let desc = getStringAttribute(element, kAXDescriptionAttribute) { return desc }
    if let ph = getStringAttribute(element, "AXPlaceholderValue") { return ph }

    return nil
}

private func classifyKind(role: String) -> String {
    switch role {
    case "AXTextField", "AXTextArea": return "text"
    case "AXSlider", "AXIncrementor", "AXStepper", "AXValueIndicator": return "number"
    case "AXCheckBox", "AXRadioButton": return "boolean"
    case "AXPopUpButton", "AXComboBox": return "choice"
    default: return "unknown"
    }
}

private func friendlyRole(_ role: String) -> String {
    switch role {
    case "AXTextField": return "text_field"
    case "AXTextArea": return "text_area"
    case "AXSlider": return "slider"
    case "AXCheckBox": return "checkbox"
    case "AXRadioButton": return "radio_button"
    case "AXPopUpButton": return "popup_button"
    case "AXComboBox": return "combo_box"
    case "AXIncrementor": return "incrementor"
    case "AXStepper": return "stepper"
    case "AXValueIndicator": return "value_indicator"
    default: return role
    }
}

func getNumberAttribute(_ element: AXUIElement, _ attribute: String) -> Double? {
    var ref: CFTypeRef?
    let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &ref)
    guard result == .success, let num = ref as? NSNumber else { return nil }
    return num.doubleValue
}
