//
//  SolverError.swift
//  Cassowary
//

import Foundation

/// Errors raised by `Solver`.
public enum SolverError: Error, Equatable, CustomStringConvertible {

    /// The constraint was added to the solver twice.
    case duplicateConstraint

    /// The constraint is not known to the solver.
    case unknownConstraint

    /// The edit variable was added twice.
    case duplicateEditVariable

    /// The edit variable is not known to the solver.
    case unknownEditVariable

    /// A required constraint cannot be satisfied together with the existing ones.
    /// The solver is left in its previous consistent state.
    case unsatisfiableConstraint

    /// The solver detected an internal invariant violation.
    case internalInconsistency(String)

    public var description: String {
        switch self {
        case .duplicateConstraint:
            return "duplicate constraint"
        case .unknownConstraint:
            return "unknown constraint"
        case .duplicateEditVariable:
            return "duplicate edit variable"
        case .unknownEditVariable:
            return "unknown edit variable"
        case .unsatisfiableConstraint:
            return "unsatisfiable constraint"
        case .internalInconsistency(let message):
            return "internal inconsistency: \(message)"
        }
    }
}
