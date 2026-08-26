import Foundation

/// Compile a case-insensitive regex for `titlePattern` parameters used by the
/// `list_windows` and `list_menu_bar` filters. Behaviour intentionally
/// differs from `ElementQuery`'s locator `titlePattern`:
///   - case-insensitive (`NSRegularExpression` default is sensitive)
///   - invalid pattern throws `invalidParams` rather than silently failing
///   - both pattern and haystack are NFC-normalized (`titleMatches`), because
///     `NSRegularExpression` compares UTF-16 code units and will not treat
///     composed `Ü` as equal to `U` + combining diaeresis
///
/// Keep this file the single place that owns list-filter regex semantics so
/// the two call sites stay in lockstep.
func compileTitlePattern(_ pattern: String) throws -> NSRegularExpression {
    do {
        return try NSRegularExpression(
            pattern: pattern.precomposedStringWithCanonicalMapping,
            options: [.caseInsensitive]
        )
    } catch {
        throw RPCError.invalidParams(
            "Invalid titlePattern: \(error.localizedDescription)")
    }
}

func titleMatches(_ value: String, regex: NSRegularExpression) -> Bool {
    let normalized = value.precomposedStringWithCanonicalMapping
    let range = NSRange(normalized.startIndex..., in: normalized)
    return regex.firstMatch(in: normalized, range: range) != nil
}
