@preconcurrency import ApplicationServices
import Foundation

/// Hashable wrapper that gives `AXUIElement` value semantics inside Swift collections.
///
/// `AXUIElement` is a CoreFoundation type, and a reference is (target pid + an opaque
/// token the app supplies). Two references obtained at different times for the same
/// underlying UI object therefore compare equal under `CFEqual` and hash identically
/// under `CFHash` — which is what lets `HandleTable` hand back the *same* handle for an
/// element rediscovered by a later tree walk.
///
/// Both directions of imprecision are handled elsewhere:
///  - Apps that vend a fresh accessibility proxy per query (Chromium/Electron web
///    content especially) can return a non-equal reference for the same on-screen
///    element. Deduplication simply misses and a new handle is minted — exactly the
///    behaviour macbeth had before, so the failure mode is "no worse than before".
///  - Apps that recycle views (`NSTableView` row reuse) can reuse a token for a
///    *different* logical element. That is the dangerous direction — an old handle
///    would silently resolve to the wrong thing — and it is what `ElementFingerprint`
///    exists to catch.
struct ElementKey: Hashable, @unchecked Sendable {
    let element: AXUIElement

    init(_ element: AXUIElement) {
        self.element = element
    }

    static func == (lhs: ElementKey, rhs: ElementKey) -> Bool {
        CFEqual(lhs.element, rhs.element)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(CFHash(element))
    }
}

/// The identity-bearing attributes of an element, recorded when a handle is issued so a
/// later resolve can tell "same element" from "same reference, different element".
///
/// Deliberately excludes title and value: a button that flips between "Play" and "Pause"
/// is still the same button, and treating that as a new identity would make handles
/// churn again for the most common UI in existence.
struct ElementFingerprint: Sendable, Equatable {
    let role: String?
    let subrole: String?
    let identifier: String?

    /// Nothing known — used for call sites that store an element without having read it,
    /// and for elements whose attributes could not be read at all.
    static let unknown = ElementFingerprint(role: nil, subrole: nil, identifier: nil)

    var isEmpty: Bool { role == nil && subrole == nil && identifier == nil }

    /// Read the identity attributes of a live element (3 AX round-trips).
    static func capture(_ element: AXUIElement) -> ElementFingerprint {
        captureChecked(element).fingerprint
    }

    /// Read the fingerprint and report whether the element still exists.
    ///
    /// `alive == false` only for `kAXErrorInvalidUIElement` — the app destroyed the
    /// object. Every other failure (a busy app answering `.cannotComplete`, an
    /// unsupported attribute) leaves the element presumed alive with a partial
    /// fingerprint, so a transient AX hiccup can never be mistaken for staleness.
    ///
    /// This is checked on each of the three reads, not just the first: the app can
    /// destroy the element in the gap between them, and `getStringAttribute` folds
    /// every failure (including `invalidUIElement`) into `nil` indistinguishably from
    /// "attribute not set". Stopping at the first invalid read and reporting `alive` off
    /// only that would let a destroy-then-recycle land with a partial fingerprint — the
    /// missing subrole/identifier would then never contradict a different element reusing
    /// the same reference, which is exactly the case this fingerprint exists to catch.
    static func captureChecked(_ element: AXUIElement) -> (alive: Bool, fingerprint: ElementFingerprint) {
        func readString(_ attribute: String) -> (valid: Bool, value: String?) {
            var ref: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &ref)
            if result == .invalidUIElement {
                return (false, nil)
            }
            return (true, result == .success ? ref as? String : nil)
        }

        let role = readString(kAXRoleAttribute)
        guard role.valid else { return (false, .unknown) }
        let subrole = readString(kAXSubroleAttribute)
        guard subrole.valid else { return (false, .unknown) }
        let identifier = readString(kAXIdentifierAttribute)
        guard identifier.valid else { return (false, .unknown) }

        return (
            true,
            ElementFingerprint(role: role.value, subrole: subrole.value, identifier: identifier.value)
        )
    }

    /// Combine what two reads know about the same element.
    ///
    /// The newer read wins per attribute, but an attribute it failed to fetch never
    /// erases one already recorded: dropping a known `AXIdentifier` because one read
    /// came back empty would leave nothing for a later recycled reference to
    /// contradict, and the handle would resolve to the wrong control.
    func merged(with newer: ElementFingerprint) -> ElementFingerprint {
        ElementFingerprint(
            role: newer.role ?? role,
            subrole: newer.subrole ?? subrole,
            identifier: newer.identifier ?? identifier
        )
    }

    /// True when two fingerprints cannot describe the same UI object.
    ///
    /// Only *contradictions* count. An attribute missing on either side is "unknown",
    /// never a difference: apps populate `AXIdentifier` lazily and fail attribute reads
    /// while busy, and inventing staleness out of that would be worse than missing a
    /// recycled token.
    func conflicts(with other: ElementFingerprint) -> Bool {
        func differs(_ lhs: String?, _ rhs: String?) -> Bool {
            guard let lhs, let rhs else { return false }
            return lhs != rhs
        }
        return differs(role, other.role)
            || differs(subrole, other.subrole)
            || differs(identifier, other.identifier)
    }
}

/// Why a handle that this daemon once issued can no longer be used.
///
/// Distinct from "unknown handle" (never issued), which is a caller bug rather than a
/// recoverable lifecycle event.
enum HandleInvalidation: String, Sendable {
    /// Passed its idle TTL and was evicted.
    case expired
    /// The app destroyed the underlying element (re-render, view teardown).
    case destroyed
    /// The app reused the accessibility reference for a different element.
    case recycled
    /// The owning app quit, or its connection was evicted.
    case appTerminated = "app_terminated"

    /// What the caller should do about it.
    var recovery: String {
        switch self {
        case .expired:
            "The handle passed its idle TTL (5 min, or 60 min when pinned). Re-resolve it "
            + "from its query path, or pass `pin: true` when minting it (read_form, "
            + "query_tree, get_element) to extend the TTL."
        case .destroyed:
            "The app destroyed the element (typically a re-render). Re-resolve it from its "
            + "query path, or re-run query_tree."
        case .recycled:
            "The app reused this accessibility reference for a different element (view "
            + "recycling). Re-run the query that produced it — do not reuse the handle."
        case .appTerminated:
            "The owning app quit or was disconnected. Reconnect with connect_app and query again."
        }
    }
}
