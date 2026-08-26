import Testing
@testable import macbethd

private let nfcUbersicht = "\u{00DC}bersicht"
private let nfdUbersicht = "U\u{0308}bersicht"

private func candidate(
    _ name: String?,
    bundle: String? = nil,
    aliases: [String] = [],
    regular: Bool
) -> AppNameCandidate {
    AppNameCandidate(
        localizedName: name,
        bundleIdentifier: bundle,
        aliases: aliases,
        isRegular: regular
    )
}

@Test func matchAppPrefersRegularExactNameOverAccessory() {
    let apps = [
        candidate("Cursor Helper", regular: false),
        candidate("Cursor", regular: true),
    ]
    let match = matchApp(byName: "Cursor", among: apps)
    #expect(match?.index == 1)
    #expect(match?.kind == .exactName)
}

@Test func matchAppFallsBackToAccessoryExactName() {
    let apps = [
        candidate("Finder", regular: true),
        candidate(nfdUbersicht, bundle: "tracesOf.Uebersicht", regular: false),
    ]
    let match = matchApp(byName: nfcUbersicht, among: apps)
    #expect(match?.index == 1)
    #expect(match?.kind == .exactName)
    #expect(match?.value == nfdUbersicht)
}

@Test func matchAppExactAccessoryBeatsPartialHelper() {
    let apps = [
        candidate("\(nfdUbersicht) Web Content", bundle: "com.apple.WebKit.WebContent", regular: false),
        candidate(nfdUbersicht, bundle: "tracesOf.Uebersicht", regular: false),
    ]
    let match = matchApp(byName: nfcUbersicht, among: apps)
    #expect(match?.index == 1)
    #expect(match?.kind == .exactName)
}

@Test func matchAppPartialBundleResolvesAsciiSpellingOfAccessoryApp() {
    let apps = [
        candidate(nfdUbersicht, bundle: "tracesOf.Uebersicht", regular: false),
    ]
    let match = matchApp(byName: "Uebersicht", among: apps)
    #expect(match?.kind == .partialBundleIdentifier)
    #expect(match?.value == "tracesOf.Uebersicht")
}

@Test func matchAppRegularPartialStillWinsBeforeAccessory() {
    let apps = [
        candidate("Notes Helper", regular: false),
        candidate("Apple Notes", regular: true),
    ]
    let match = matchApp(byName: "Notes", among: apps)
    #expect(match?.index == 1)
    #expect(match?.kind == .partialName)
}

@Test func matchAppDeclaredAliasOnAccessory() {
    let apps = [
        candidate("ChatGPT", aliases: ["Codex"], regular: false),
    ]
    let match = matchApp(byName: "codex", among: apps)
    #expect(match?.kind == .declaredAlias)
    #expect(match?.value == "Codex")
}

@Test func matchAppReturnsNilWhenNothingMatches() {
    let apps = [
        candidate("Finder", regular: true),
        candidate(nfdUbersicht, regular: false),
    ]
    #expect(matchApp(byName: "Definitely Missing", among: apps) == nil)
}

@Test func foldedAppNameUnifiesNfcAndNfd() {
    #expect(foldedAppName(nfcUbersicht) == foldedAppName(nfdUbersicht))
}
