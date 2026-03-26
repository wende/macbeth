import Contacts
import Dispatch
import EventKit
import Foundation

enum BridgeError: Error, LocalizedError {
    case invalidArguments(String)
    case parseError(String)
    case notFound(String)

    var errorDescription: String? {
        switch self {
        case .invalidArguments(let msg): return msg
        case .parseError(let msg): return msg
        case .notFound(let msg): return msg
        }
    }
}

struct CLI {
    let command: String
    let options: [String: String]
    let flags: Set<String>

    init(argv: [String]) throws {
        guard argv.count >= 2 else {
            throw BridgeError.invalidArguments("Missing command")
        }

        command = argv[1]
        var options: [String: String] = [:]
        var flags: Set<String> = []

        var i = 2
        while i < argv.count {
            let token = argv[i]
            if token.hasPrefix("--") {
                let key = String(token.dropFirst(2))
                if i + 1 < argv.count && !argv[i + 1].hasPrefix("--") {
                    options[key] = argv[i + 1]
                    i += 2
                } else {
                    flags.insert(key)
                    i += 1
                }
            } else {
                i += 1
            }
        }

        self.options = options
        self.flags = flags
    }

    func option(_ key: String) -> String? { options[key] }
    func required(_ key: String) throws -> String {
        guard let value = options[key], !value.isEmpty else {
            throw BridgeError.invalidArguments("Missing --\(key)")
        }
        return value
    }

    func hasFlag(_ key: String) -> Bool { flags.contains(key) }
}

func isoString(from date: Date?) -> String? {
    guard let date else { return nil }
    return ISO8601DateFormatter().string(from: date)
}

func parseISODate(_ value: String) throws -> Date {
    let formatter = ISO8601DateFormatter()
    if let d = formatter.date(from: value) {
        return d
    }

    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = fractional.date(from: value) {
        return d
    }

    let fallback = DateFormatter()
    fallback.locale = Locale(identifier: "en_US_POSIX")
    fallback.dateFormat = "yyyy-MM-dd HH:mm"
    if let d = fallback.date(from: value) {
        return d
    }

    throw BridgeError.parseError("Invalid date format: \(value). Use ISO 8601, e.g. 2026-03-26T09:00:00Z")
}

func jsonOut(_ value: Any) {
    do {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
        if let text = String(data: data, encoding: .utf8) {
            print(text)
        }
    } catch {
        print("{\"ok\":false,\"error\":\"JSON serialization failed\"}")
    }
}

func fetchReminders(eventStore: EKEventStore, predicate: NSPredicate) async -> [EKReminder] {
    await withCheckedContinuation { continuation in
        eventStore.fetchReminders(matching: predicate) { reminders in
            continuation.resume(returning: reminders ?? [])
        }
    }
}

struct AppleDataBridge {
    static func run() async throws {
        let cli = try CLI(argv: CommandLine.arguments)
        switch cli.command {
        case "reminders-list":
            try await remindersList(cli)
        case "reminders-add":
            try await remindersAdd(cli)
        case "reminders-complete":
            try await remindersComplete(cli)
        case "calendar-list":
            try await calendarList(cli)
        case "calendar-add":
            try await calendarAdd(cli)
        case "contacts-search":
            try contactsSearch(cli)
        case "contacts-add":
            try contactsAdd(cli)
        default:
            throw BridgeError.invalidArguments("Unknown command: \(cli.command)")
        }
    }

    static func remindersList(_ cli: CLI) async throws {
        let store = EKEventStore()
        _ = try await store.requestFullAccessToReminders()

        let listName = cli.option("list")
        let includeCompleted = cli.hasFlag("include-completed")

        var calendars = store.calendars(for: .reminder)
        if let listName {
            calendars = calendars.filter { $0.title.caseInsensitiveCompare(listName) == .orderedSame }
        }

        let predicate = store.predicateForReminders(in: calendars)
        let reminders = await fetchReminders(eventStore: store, predicate: predicate)
        let filtered = reminders
            .filter { includeCompleted || !$0.isCompleted }
            .sorted { lhs, rhs in
                let l = lhs.dueDateComponents?.date ?? .distantFuture
                let r = rhs.dueDateComponents?.date ?? .distantFuture
                return l < r
            }

        let out = filtered.map { reminder in
            [
                "id": reminder.calendarItemIdentifier,
                "title": reminder.title ?? "",
                "completed": reminder.isCompleted,
                "list": reminder.calendar.title,
                "due": isoString(from: reminder.dueDateComponents?.date) as Any,
                "notes": reminder.notes as Any,
                "priority": reminder.priority
            ] as [String: Any]
        }

        jsonOut(["ok": true, "items": out])
    }

    static func remindersAdd(_ cli: CLI) async throws {
        let store = EKEventStore()
        _ = try await store.requestFullAccessToReminders()

        let title = try cli.required("title")
        let listName = cli.option("list")

        let reminder = EKReminder(eventStore: store)
        reminder.title = title

        if let dueText = cli.option("due") {
            let due = try parseISODate(dueText)
            reminder.dueDateComponents = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute],
                from: due
            )
        }

        if let notes = cli.option("notes") {
            reminder.notes = notes
        }

        if let priority = cli.option("priority"), let intP = Int(priority) {
            reminder.priority = intP
        }

        if let calendar = resolveReminderCalendar(store: store, requestedListName: listName) {
            reminder.calendar = calendar
        } else {
            throw BridgeError.notFound("No writable reminders list found")
        }

        try store.save(reminder, commit: true)

        jsonOut([
            "ok": true,
            "item": [
                "id": reminder.calendarItemIdentifier,
                "title": reminder.title ?? "",
                "list": reminder.calendar.title,
                "due": isoString(from: reminder.dueDateComponents?.date) as Any
            ]
        ])
    }

    static func resolveReminderCalendar(store: EKEventStore, requestedListName: String?) -> EKCalendar? {
        let reminderCalendars = store.calendars(for: .reminder)

        if let requestedListName,
           let named = reminderCalendars.first(where: { $0.title.caseInsensitiveCompare(requestedListName) == .orderedSame && $0.allowsContentModifications }) {
            return named
        }

        if let defaultCalendar = store.defaultCalendarForNewReminders(),
           defaultCalendar.allowsContentModifications {
            return defaultCalendar
        }

        return reminderCalendars.first(where: { $0.allowsContentModifications })
    }

    static func remindersComplete(_ cli: CLI) async throws {
        let store = EKEventStore()
        _ = try await store.requestFullAccessToReminders()

        let id = try cli.required("id")
        let predicate = store.predicateForReminders(in: nil)
        let reminders = await fetchReminders(eventStore: store, predicate: predicate)

        guard let reminder = reminders.first(where: { $0.calendarItemIdentifier == id }) else {
            throw BridgeError.notFound("Reminder not found: \(id)")
        }

        reminder.isCompleted = true
        reminder.completionDate = Date()
        try store.save(reminder, commit: true)

        jsonOut([
            "ok": true,
            "item": [
                "id": reminder.calendarItemIdentifier,
                "completed": true
            ]
        ])
    }

    static func calendarList(_ cli: CLI) async throws {
        let store = EKEventStore()
        _ = try await store.requestFullAccessToEvents()

        let days = Int(cli.option("days") ?? "7") ?? 7
        let calendarName = cli.option("calendar")
        let start = Date()
        let end = Calendar.current.date(byAdding: .day, value: days, to: start) ?? Date().addingTimeInterval(86400 * 7)

        var calendars = store.calendars(for: .event)
        if let calendarName {
            calendars = calendars.filter { $0.title.caseInsensitiveCompare(calendarName) == .orderedSame }
        }

        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: calendars)
        let events = store.events(matching: predicate).sorted(by: { $0.startDate < $1.startDate })

        let out = events.map { event in
            [
                "id": event.calendarItemIdentifier,
                "title": event.title ?? "",
                "calendar": event.calendar.title,
                "start": isoString(from: event.startDate) as Any,
                "end": isoString(from: event.endDate) as Any,
                "allDay": event.isAllDay,
                "location": event.location as Any,
                "notes": event.notes as Any
            ] as [String: Any]
        }

        jsonOut(["ok": true, "items": out])
    }

    static func calendarAdd(_ cli: CLI) async throws {
        let store = EKEventStore()
        _ = try await store.requestFullAccessToEvents()

        let title = try cli.required("title")
        let start = try parseISODate(try cli.required("start"))
        let end = try parseISODate(try cli.required("end"))
        let calendarName = cli.option("calendar")

        let event = EKEvent(eventStore: store)
        event.title = title
        event.startDate = start
        event.endDate = end

        if let notes = cli.option("notes") {
            event.notes = notes
        }

        if let location = cli.option("location") {
            event.location = location
        }

        let eventCalendars = store.calendars(for: .event)
        if let calendarName,
           let cal = eventCalendars.first(where: { $0.title.caseInsensitiveCompare(calendarName) == .orderedSame && $0.allowsContentModifications }) {
            event.calendar = cal
        } else if let defaultCal = store.defaultCalendarForNewEvents, defaultCal.allowsContentModifications {
            event.calendar = defaultCal
        } else if let anyCal = eventCalendars.first(where: { $0.allowsContentModifications }) {
            event.calendar = anyCal
        } else {
            throw BridgeError.notFound("No writable calendar found")
        }

        try store.save(event, span: .thisEvent, commit: true)

        jsonOut([
            "ok": true,
            "item": [
                "id": event.calendarItemIdentifier,
                "title": event.title ?? "",
                "calendar": event.calendar.title,
                "start": isoString(from: event.startDate) as Any,
                "end": isoString(from: event.endDate) as Any
            ]
        ])
    }

    static func contactsSearch(_ cli: CLI) throws {
        let store = CNContactStore()
        var granted = false

        let sem = DispatchSemaphore(value: 0)
        store.requestAccess(for: .contacts) { ok, _ in
            granted = ok
            sem.signal()
        }
        sem.wait()
        guard granted else {
            throw BridgeError.parseError("Contacts permission denied")
        }

        let query = (cli.option("query") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let limit = Int(cli.option("limit") ?? "20") ?? 20

        let keys: [CNKeyDescriptor] = [
            CNContactIdentifierKey as CNKeyDescriptor,
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactOrganizationNameKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor
        ]

        let request = CNContactFetchRequest(keysToFetch: keys)
        var items: [[String: Any]] = []

        try store.enumerateContacts(with: request) { contact, stop in
            let displayName = "\(contact.givenName) \(contact.familyName)".trimmingCharacters(in: .whitespaces)
            let haystack = [displayName, contact.organizationName].joined(separator: " ").lowercased()
            if !query.isEmpty && !haystack.contains(query.lowercased()) {
                return
            }

            items.append([
                "id": contact.identifier,
                "name": displayName,
                "organization": contact.organizationName,
                "emails": contact.emailAddresses.map { String($0.value) },
                "phones": contact.phoneNumbers.map { $0.value.stringValue }
            ])

            if items.count >= limit {
                stop.pointee = true
            }
        }

        jsonOut(["ok": true, "items": items])
    }

    static func contactsAdd(_ cli: CLI) throws {
        let store = CNContactStore()
        var granted = false

        let sem = DispatchSemaphore(value: 0)
        store.requestAccess(for: .contacts) { ok, _ in
            granted = ok
            sem.signal()
        }
        sem.wait()
        guard granted else {
            throw BridgeError.parseError("Contacts permission denied")
        }

        let given = try cli.required("given")
        let family = cli.option("family") ?? ""
        let email = cli.option("email")
        let phone = cli.option("phone")

        let contact = CNMutableContact()
        contact.givenName = given
        contact.familyName = family

        if let email {
            contact.emailAddresses = [CNLabeledValue(label: CNLabelWork, value: email as NSString)]
        }

        if let phone {
            let number = CNPhoneNumber(stringValue: phone)
            contact.phoneNumbers = [CNLabeledValue(label: CNLabelPhoneNumberMobile, value: number)]
        }

        let saveRequest = CNSaveRequest()
        saveRequest.add(contact, toContainerWithIdentifier: nil)
        try store.execute(saveRequest)

        jsonOut([
            "ok": true,
            "item": [
                "name": "\(contact.givenName) \(contact.familyName)".trimmingCharacters(in: .whitespaces),
                "email": email as Any,
                "phone": phone as Any
            ]
        ])
    }
}

var exitCode: Int32 = 0
let done = DispatchSemaphore(value: 0)

Task {
    do {
        try await AppleDataBridge.run()
    } catch {
        jsonOut([
            "ok": false,
            "error": error.localizedDescription
        ])
        exitCode = 1
    }
    done.signal()
}

done.wait()
exit(exitCode)
