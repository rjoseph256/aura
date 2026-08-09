import Foundation

/// A decoded JSON value, in the seven shapes a `route` column can arrive in.
///
/// This type exists so the rule below can be tested. The rule was written against Supabase's
/// `AnyJSON`, which is a symbol of the app target's SDK and is not visible from this package, and
/// the app target's only test bundle is `AuraUITests` — so as long as the rule lived beside the row
/// decoder, nothing could reach it. `RouteJSON` mirrors `AnyJSON`'s cases one for one
/// (`null, bool, integer, double, string, object, array`, the last two recursive) so the mapping at
/// the call site is a case-for-case translation with nothing to decide.
///
/// **Keep `integer` and `double` apart.** They look like one case worth collapsing and are not:
/// `Double` holds integers exactly only to 2^53, so a wide identifier — a millisecond timestamp is
/// already 10^12 — would come back changed, and the damage would be silent, in a payload the round
/// trip is supposed to preserve byte-for-byte. The mirror is faithful precisely so that the
/// question of which values survive never has to be asked.
public enum RouteJSON: Equatable, Sendable {
    case null
    case bool(Bool)
    case integer(Int)
    case double(Double)
    case string(String)
    case object([String: RouteJSON])
    case array([RouteJSON])
}

extension RouteJSON: Codable {
    /// Ordered narrowest-first. `Bool` is tried before `Int` because Foundation's decoder is strict
    /// about the two — `true` is not 1 and 1 is not `true` — and `Int` before `Double` so a whole
    /// number keeps its integer case rather than being widened on the way in.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null; return }
        if let value = try? container.decode(Bool.self) { self = .bool(value); return }
        if let value = try? container.decode(Int.self) { self = .integer(value); return }
        if let value = try? container.decode(Double.self) { self = .double(value); return }
        if let value = try? container.decode(String.self) { self = .string(value); return }
        if let value = try? container.decode([RouteJSON].self) { self = .array(value); return }
        if let value = try? container.decode([String: RouteJSON].self) { self = .object(value); return }
        throw DecodingError.dataCorruptedError(in: container,
                                               debugDescription: "Value is not JSON this type can represent.")
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        }
    }
}

/// The rule that decides whether a ride has a route at all (ROH-114).
public enum RouteEnvelope {
    /// The bytes of the ride's route, or nil for a destination-free ride — **and a JSON `null`
    /// folds to nil too**.
    ///
    /// This is the layer the first ROH-114 spec revision missed, and it was ship-dead. `AnyJSON`
    /// has a `.null` case, so a SQL-NULL `route` column does not fail to decode and does not arrive
    /// absent — a non-optional property would receive `.null` and encode back to the four bytes
    /// `null`. `GroupRideSession.join` would then see non-nil bytes, fail the `Route` decode, land
    /// in `.routeUnavailable`, and call `leaveRide` — showing every guest of an open ride an error
    /// and removing them from the ride server-side.
    ///
    /// An optional parameter handles the usual decode path (`decodeIfPresent` returns nil for a
    /// JSON null); the explicit `.null` fold covers a decoder that hands back the case instead.
    /// Both roads lead to nil, which is the only value that means "open ride".
    ///
    /// Everything else is re-encoded unchanged and left for the caller to decode as a `Route`. A
    /// present payload that is not a route is a corrupt route, not an open ride — that distinction
    /// is the caller's (spec D1.2), and collapsing it here would turn corruption into silence.
    public static func routeData(_ value: RouteJSON?) throws -> Data? {
        guard let value else { return nil }
        if case .null = value { return nil }
        return try JSONEncoder().encode(value)
    }
}
