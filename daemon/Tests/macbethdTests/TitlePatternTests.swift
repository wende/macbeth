import Foundation
import Testing
@testable import macbethd

private let nfcUbersicht = "\u{00DC}bersicht"
private let nfdUbersicht = "U\u{0308}bersicht"

@Test func titleMatchesUnifiesNfcPatternWithNfdHaystack() throws {
    // Locator titlePattern is case-sensitive and compiles the pattern itself;
    // both sides must still NFC-normalize or Übersicht (composed) misses NFD AX titles.
    let regex = try NSRegularExpression(
        pattern: nfcUbersicht.precomposedStringWithCanonicalMapping
    )
    #expect(titleMatches(nfdUbersicht, regex: regex))
    #expect(titleMatches(nfcUbersicht, regex: regex))
}

@Test func compileTitlePatternUnifiesNfdPatternWithNfcHaystack() throws {
    let regex = try compileTitlePattern(nfdUbersicht)
    #expect(titleMatches(nfcUbersicht, regex: regex))
    #expect(titleMatches(nfdUbersicht, regex: regex))
}
