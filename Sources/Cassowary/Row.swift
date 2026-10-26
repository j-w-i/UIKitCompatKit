//
//  Row.swift
//  Cassowary
//
//  A sparse row of the Cassowary simplex tableau.
//
//  Ported from the reference `kiwi` implementation:
//    Copyright (c) 2013-2026, Nucleic Development Team.
//    Distributed under the terms of the Modified BSD License.
//    https://github.com/nucleic/kiwi (kiwi/row.h)
//
//  The Cassowary algorithm was created by Greg Badros and Alan Borning at the
//  University of Washington (https://constraints.cs.washington.edu/cassowary/).
//

import Foundation

/// The numerical tolerance used throughout the solver, matching the reference
/// `kiwi` implementation (`1e-8`). Values whose magnitude is below the
/// tolerance are treated as zero.
internal func nearZero(_ value: Double) -> Bool {
    let epsilon = 1.0e-8
    return value < 0.0 ? -value < epsilon : value < epsilon
}

/// A sparse row of the simplex tableau: `constant + sum(cell * symbol) == 0`.
///
/// Rows have value semantics. The solver uses shallow snapshots of its tableau
/// to roll a failed `addConstraint` back; Swift's copy-on-write dictionaries
/// make those snapshots cheap and let the rows be restored exactly.
///
/// All traversals go through `symbols`, which is sorted by symbol id, so a row
/// never exposes dictionary iteration order.
internal struct Row {

    /// The non-zero coefficients of the row, keyed by symbol.
    private var cells: [Symbol: Double]

    /// The constant term of the row.
    internal private(set) var constant: Double

    internal init(constant: Double = 0.0) {
        self.cells = [:]
        self.constant = constant
    }

    /// Whether the row contains no variable terms.
    internal var isEmpty: Bool {
        cells.isEmpty
    }

    /// The number of non-zero coefficients in the row.
    internal var cellCount: Int {
        cells.count
    }

    /// The symbols with a non-zero coefficient, sorted by symbol id.
    internal var symbols: [Symbol] {
        cells.keys.sorted()
    }

    /// The coefficient of `symbol`, or `0` when the symbol is absent.
    internal func coefficient(for symbol: Symbol) -> Double {
        cells[symbol] ?? 0.0
    }

    /// Adds `value` to the constant term and returns the new constant.
    @discardableResult
    internal mutating func add(_ value: Double) -> Double {
        constant += value
        return constant
    }

    /// Inserts `coefficient * symbol` into the row.
    ///
    /// If the symbol is already present its coefficient is accumulated. If the
    /// resulting coefficient is (close to) zero the symbol is removed, keeping
    /// the row sparse.
    internal mutating func insert(_ symbol: Symbol, _ coefficient: Double = 1.0) {
        let value = (cells[symbol] ?? 0.0) + coefficient
        if nearZero(value) {
            cells.removeValue(forKey: symbol)
        } else {
            cells[symbol] = value
        }
    }

    /// Inserts `coefficient * other` into this row.
    ///
    /// The cells of `other` are merged in dictionary order on purpose: the
    /// update of each cell is independent of the others, so this cannot
    /// influence the resulting coefficients (or therefore the solution), and it
    /// avoids sorting a row on every substitution — a hot path during pivots.
    internal mutating func insert(_ other: Row, _ coefficient: Double = 1.0) {
        constant += other.constant * coefficient
        for (symbol, otherCoefficient) in other.cells {
            insert(symbol, otherCoefficient * coefficient)
        }
    }

    /// Removes `symbol` from the row.
    internal mutating func remove(_ symbol: Symbol) {
        cells.removeValue(forKey: symbol)
    }

    /// Reverses the sign of the constant and of every cell.
    internal mutating func reverseSign() {
        constant = -constant
        cells = cells.mapValues { -$0 }
    }

    /// Solves the row for `symbol`.
    ///
    /// The row is assumed to be of the form `a * symbol + rest = 0`; afterwards
    /// it represents `symbol = -rest / a`. The solved-for symbol is removed and
    /// the constant and remaining cells are scaled by `-1 / a`.
    ///
    /// - Throws: `SolverError.internalInconsistency` if the symbol is absent.
    internal mutating func solveFor(_ symbol: Symbol) throws {
        guard let coefficient = cells.removeValue(forKey: symbol) else {
            throw SolverError.internalInconsistency("row does not contain the symbol to solve for")
        }
        let multiplier = -1.0 / coefficient
        constant *= multiplier
        cells = cells.mapValues { $0 * multiplier }
    }

    /// Solves the row for `lhs` in terms of `rhs`.
    ///
    /// The row is assumed to be of the form `rhs = rest`; afterwards it
    /// represents `lhs = rest / rhsCoefficient`. `lhs` must not already appear
    /// in the row, `rhs` must appear in it.
    internal mutating func solveFor(_ lhs: Symbol, _ rhs: Symbol) throws {
        insert(lhs, -1.0)
        try solveFor(rhs)
    }

    /// Substitutes `symbol` in this row with the contents of `other`.
    ///
    /// Given `symbol = other` and this row `a * symbol + rest = 0`, the row
    /// becomes `a * other + rest = 0`. A no-op when the symbol is absent.
    internal mutating func substitute(_ symbol: Symbol, with other: Row) {
        guard let coefficient = cells.removeValue(forKey: symbol) else { return }
        insert(other, coefficient)
    }
}
