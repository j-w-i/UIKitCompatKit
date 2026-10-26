//
//  Symbol.swift
//  Cassowary
//
//  A symbol in the Cassowary simplex tableau.
//
//  Ported from the reference `kiwi` implementation:
//    Copyright (c) 2013-2026, Nucleic Development Team.
//    Distributed under the terms of the Modified BSD License.
//    https://github.com/nucleic/kiwi (kiwi/symbol.h)
//
//  The Cassowary algorithm was created by Greg Badros and Alan Borning at the
//  University of Washington (https://constraints.cs.washington.edu/cassowary/).
//

import Foundation

/// A symbol identifies one column of the simplex tableau.
///
/// Symbols are either external variables (the variables the caller creates),
/// or internal variables introduced by the solver:
///
/// * `slack`   — a non-negative slack variable for an inequality.
/// * `error`   — a non-negative error variable that lets a non-required
///               constraint be violated at a cost.
/// * `dummy`   — a zero-width column used to encode required equalities.
///
/// Every symbol gets a monotonically increasing id from its solver. The id is
/// used both for hashing and for ordering: the solver sorts all tableau
/// traversals by id so that pivot selection — and therefore the solution — is
/// deterministic and independent of the process hash seed.
internal struct Symbol: Hashable, Comparable, CustomStringConvertible {

    /// The kind of a tableau column.
    internal enum Kind: UInt8 {
        case invalid
        case external
        case slack
        case error
        case dummy
    }

    internal let kind: Kind
    internal let id: Int

    internal init(_ kind: Kind, _ id: Int) {
        self.kind = kind
        self.id = id
    }

    /// The sentinel returned when no symbol was found. Its id is never assigned
    /// to a real symbol (ids start at 1).
    internal static let invalid = Symbol(.invalid, 0)

    /// Whether the symbol can leave/enter the basis as a slack or error column.
    internal var isPivotable: Bool {
        kind == .slack || kind == .error
    }

    /// Whether the symbol represents a caller-created variable.
    internal var isExternal: Bool {
        kind == .external
    }

    /// Whether the symbol is a zero-width dummy column.
    internal var isDummy: Bool {
        kind == .dummy
    }

    internal static func == (lhs: Symbol, rhs: Symbol) -> Bool {
        lhs.id == rhs.id
    }

    internal static func < (lhs: Symbol, rhs: Symbol) -> Bool {
        lhs.id < rhs.id
    }

    internal func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    internal var description: String {
        switch kind {
        case .invalid:
            return "invalid"
        case .external:
            return "v\(id)"
        case .slack:
            return "s\(id)"
        case .error:
            return "e\(id)"
        case .dummy:
            return "d\(id)"
        }
    }
}
