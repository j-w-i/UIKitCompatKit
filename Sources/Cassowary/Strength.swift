//
//  Strength.swift
//  Cassowary
//
//  Symbolic strengths, exactly as in Cassowary/kiwi:
//
//      strength(a, b, c, w) = clamp(a * w) * 1,000,000
//                           + clamp(b * w) * 1,000
//                           + clamp(c * w)
//      clamp(x) = min(1000, max(0, x))
//
//  The symbolic levels are lexicographically ordered, which is what allows the
//  solver to sacrifice lower-priority constraints first. Auto Layout's
//  NSLayoutPriority is mapped onto these strengths by `LegacyAutoLayout`
//  (see `RRLayoutPriority`).
//

import Foundation

/// The strength of a constraint: a lexicographically-ordered symbolic weight.
public struct Strength: Hashable, Comparable, CustomStringConvertible {

    /// The raw numeric strength.
    public let value: Double

    private init(value: Double) {
        self.value = value
    }

    /// Creates a strength from symbolic weights `a`, `b`, `c` scaled by `weight`.
    public static func create(_ a: Double, _ b: Double, _ c: Double, _ weight: Double = 1.0) -> Strength {
        var result = 0.0
        result += clampComponent(a * weight) * 1_000_000.0
        result += clampComponent(b * weight) * 1_000.0
        result += clampComponent(c * weight)
        return Strength(value: result)
    }

    /// Clips a raw numeric strength into the legal range `[0, required]`.
    public static func clip(_ value: Double) -> Strength {
        Strength(value: min(required.value, max(0.0, value)))
    }

    /// A required constraint: cannot be violated, or the system is unsatisfiable.
    public static let required = Strength.create(1000.0, 1000.0, 1000.0)

    /// A strong constraint (1,000,000).
    public static let strong = Strength.create(1.0, 0.0, 0.0)

    /// A medium constraint (1,000).
    public static let medium = Strength.create(0.0, 1.0, 0.0)

    /// A weak constraint (1).
    public static let weak = Strength.create(0.0, 0.0, 1.0)

    private static func clampComponent(_ value: Double) -> Double {
        min(1000.0, max(0.0, value))
    }

    public static func < (lhs: Strength, rhs: Strength) -> Bool {
        lhs.value < rhs.value
    }

    public var description: String {
        "Strength(\(value))"
    }
}
