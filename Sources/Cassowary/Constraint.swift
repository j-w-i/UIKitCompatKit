//
//  Constraint.swift
//  Cassowary
//
//  A relational constraint between two linear expressions.
//

import Foundation

/// The relational operator of a constraint.
public enum RelationalOperator: String, Hashable, CaseIterable {
    case lessThanOrEqual = "<="
    case equal = "=="
    case greaterThanOrEqual = ">="
}

/// A linear constraint: `expression <op> 0`, optionally weighted by a strength.
public final class Constraint: CustomStringConvertible {

    /// The expression that is compared against zero.
    public let expression: Expression

    /// The relational operator.
    public let op: RelationalOperator

    /// The strength of the constraint. Required constraints must be satisfied.
    public var strength: Strength

    /// Optional debug name.
    public var name: String?

    public init(_ expression: Expression,
                _ op: RelationalOperator,
                strength: Strength = .required,
                name: String? = nil) {
        self.expression = expression
        self.op = op
        self.strength = strength
        self.name = name
    }

    /// Whether this constraint is required.
    public var isRequired: Bool {
        strength == .required
    }

    /// Whether this constraint is an inequality.
    public var isInequality: Bool {
        op != .equal
    }

    /// Returns a copy of this constraint with a different strength.
    public func or(_ strength: Strength) -> Constraint {
        Constraint(expression, op, strength: strength, name: name)
    }

    /// Returns a copy of this constraint with a different operator and strength.
    public func or(_ op: RelationalOperator, _ strength: Strength) -> Constraint {
        Constraint(expression, op, strength: strength, name: name)
    }

    public var description: String {
        var text = "\(expression) \(op.rawValue) 0"
        if let name = name {
            text = "\(name): \(text)"
        }
        if strength != .required {
            text += " |\(strength.value)"
        }
        return text
    }
}
