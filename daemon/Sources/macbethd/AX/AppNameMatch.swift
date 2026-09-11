import Foundation

/// Name/bundle/alias fields used to resolve `connect_app` without constructing
/// `NSRunningApplication` in tests.
struct AppNameCandidate: Equatable, Sendable {
    var localizedName: String?
    var bundleIdentifier: String?
    var aliases: [String]
    var isRegular: Bool
}

struct AppNameMatch: Equatable, Sendable {
    var index: Int
    var kind: AppConnectionManager.MatchKind
    var value: String
}

/// Fold for app-name comparison: NFC then lowercase, so APFS/NFD names
/// (`U` + combining diaeresis) match the composed `Ü` an agent types.
func foldedAppName(_ string: String) -> String {
    string.precomposedStringWithCanonicalMapping.lowercased()
}

/// Resolve a fuzzy app name against running-app records.
///
/// Dock (`.regular`) apps are searched first, with the same exact → alias →
/// bundle → partial priority as before. If nothing matches, LSUIElement /
/// menu-bar (`.accessory`) apps are searched the same way. `.prohibited`
/// helpers are not passed in.
func matchApp(byName name: String, among apps: [AppNameCandidate]) -> AppNameMatch? {
    let query = foldedAppName(name)
    return firstAppMatch(query: query, fallbackName: name, in: apps, regular: true)
        ?? firstAppMatch(query: query, fallbackName: name, in: apps, regular: false)
}

private func firstAppMatch(
    query: String,
    fallbackName: String,
    in apps: [AppNameCandidate],
    regular: Bool
) -> AppNameMatch? {
    func eligible(_ candidate: AppNameCandidate) -> Bool {
        candidate.isRegular == regular
    }

    if let index = apps.firstIndex(where: { candidate in
        eligible(candidate) && candidate.localizedName.map(foldedAppName) == query
    }) {
        return AppNameMatch(
            index: index,
            kind: .exactName,
            value: apps[index].localizedName ?? fallbackName
        )
    }

    for (index, candidate) in apps.enumerated() where eligible(candidate) {
        if let alias = candidate.aliases.first(where: { foldedAppName($0) == query }) {
            return AppNameMatch(index: index, kind: .declaredAlias, value: alias)
        }
    }

    if let index = apps.firstIndex(where: { candidate in
        eligible(candidate) && candidate.bundleIdentifier.map(foldedAppName) == query
    }) {
        return AppNameMatch(
            index: index,
            kind: .bundleIdentifier,
            value: apps[index].bundleIdentifier ?? fallbackName
        )
    }

    if let index = apps.firstIndex(where: { candidate in
        eligible(candidate)
            && candidate.localizedName.map { foldedAppName($0).contains(query) } == true
    }) {
        return AppNameMatch(
            index: index,
            kind: .partialName,
            value: apps[index].localizedName ?? fallbackName
        )
    }

    for (index, candidate) in apps.enumerated() where eligible(candidate) {
        if let alias = candidate.aliases.first(where: { foldedAppName($0).contains(query) }) {
            return AppNameMatch(index: index, kind: .partialAlias, value: alias)
        }
    }

    if let index = apps.firstIndex(where: { candidate in
        eligible(candidate)
            && candidate.bundleIdentifier.map { foldedAppName($0).contains(query) } == true
    }) {
        return AppNameMatch(
            index: index,
            kind: .partialBundleIdentifier,
            value: apps[index].bundleIdentifier ?? fallbackName
        )
    }

    return nil
}
