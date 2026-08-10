import Foundation

/// Compile a case-insensitive regex for `titlePattern` parameters used by the
/// `list_windows` and `list_menu_bar` filters. Behaviour intentionally
/// differs from `ElementQuery`'s locator `titlePattern`:
///   - case-insensitive (`NSRegularExpression` default is sensitive)
///   - invalid pattern throws `invalidParams` rather than silently failing
///
/// Keep this file the single place that owns list-filter regex semantics so
/// the two call sites stay in lockstep.
func compileTitlePattern(_ pattern: String) throws -> NSRegularExpression {
    do {
        return try NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    } catch {
        throw RPCError.invalidParams(
            "Invalid titlePattern: \(error.localizedDescription)")
    }
}

func titleMatches(_ value: String, regex: NSRegularExpression) -> Bool {
    let range = NSRange(value.startIndex..., in: value)
    return regex.firstMatch(in: value, range: range) != nil
}