import Testing
@testable import macbethd

@Test func menuTitlesMatchCaseInsensitively() {
    #expect(menuTitleMatches("File", requested: "file"))
    #expect(menuTitleMatches("Save As…", requested: "save as..."))
    #expect(!menuTitleMatches("Edit", requested: "File"))
    #expect(!menuTitleMatches(nil, requested: "File"))
}

@Test func normalizeMenuTitleUnifiesEllipsisAndWhitespace() {
    #expect(normalizeMenuTitle("  Save As...  ") == "Save As\u{2026}")
    #expect(normalizeMenuTitle("Save As…") == "Save As\u{2026}")
}
