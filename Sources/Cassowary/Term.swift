//
//  Term.swift
//  Cassowary
//
//  A `coefficient * variable` term in a linear expression.
//

import Foundation

/// A single term of a linear expression: `coefficient * variable`.
public final class Term: Hashable, CustomStringConvertible {

    public let variable: Variable
    public let coefficient: Double

    public init(_ variable: Variable, _ coefficient: Double = 1.0) {
        self.variable = variable
        self.coefficient = coefficient
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(variable)
        hasher.combine(coefficient)
    }

    public static func == (lhs: Term, rhs: Term) -> Bool {
        lhs.variable === rhs.variable && lhs.coefficient == rhs.coefficient
    }

    public var description: String {
        coefficient == 1.0
            ? variable.description
            : "\(coefficient) * \(variable.description)"
    }
}
