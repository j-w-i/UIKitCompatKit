//
//  Solver.swift
//  Cassowary
//
//  An incremental Cassowary constraint solver (sparse simplex tableau with
//  primal and dual optimization).
//
//  Ported from the reference `kiwi` implementation:
//    Copyright (c) 2013-2026, Nucleic Development Team.
//    Distributed under the terms of the Modified BSD License.
//    https://github.com/nucleic/kiwi (kiwi/solverimpl.h, kiwi/solver.h)
//
//  The Cassowary algorithm was created by Greg Badros and Alan Borning at the
//  University of Washington (https://constraints.cs.washington.edu/cassowary/).
//
//  Determinism: the reference implementation walks hash maps in unspecified
//  order. This port orders every traversal that can influence pivot selection by
//  numeric symbol id, so an identical sequence of calls always produces an
//  identical solution, independent of the process hash seed.
//

import Foundation

/// How a constraint is tracked in the tableau.
///
/// `marker` is the slack, error or dummy symbol that must be kept at zero for a
/// required constraint, or is penalized in the objective for an optional one.
/// `other` is the second error symbol of an equality, or the error symbol of an
/// inequality; it is `.invalid` when unused.
internal struct ConstraintTag {
    internal var marker: Symbol = .invalid
    internal var other: Symbol = .invalid
}

/// The internal state of an edit variable.
internal struct EditInfo {
    /// The symbols of the edit constraint `variable == constant`.
    internal var tag: ConstraintTag
    /// The constraint that holds the variable at `constant`.
    internal var constraint: Constraint
    /// The most recently suggested value.
    internal var constant: Double
}

/// An incremental Cassowary constraint solver.
///
/// The solver maintains a tableau of basic/non-basic variables and supports
/// adding and removing constraints, as well as edit variables for cheap
/// re-solving (used by the layout pass when a container resizes).
///
/// The solver is a reference type; all mutating methods update it in place.
/// Methods that can fail throw a `SolverError` and leave the solver in a
/// consistent state: a failed `addConstraint` restores the previous solution
/// exactly.
public final class Solver {

    /// Constraints currently held by the solver, in insertion order.
    public private(set) var constraints: [Constraint] = []

    /// The tag of every constraint in the tableau, including the internal
    /// constraints that implement edit variables. Keyed by object identity.
    private var constraintTags: [ObjectIdentifier: ConstraintTag] = [:]

    /// The basic rows of the tableau, keyed by their basic symbol.
    private var rows: [Symbol: Row] = [:]

    /// Maps caller-created variables to their tableau symbols. Symbols are
    /// allocated lazily, the first time a variable appears in a constraint.
    private var variableSymbols: [Variable: Symbol] = [:]

    /// The objective function: the weighted sum of the error symbols of all
    /// non-required constraints.
    private var objective = Row()

    /// The artificial objective used by phase one of the two-phase method,
    /// non-nil only while `addWithArtificialVariable` is running.
    private var artificialRow: Row?

    /// Basic rows whose constant is negative; they need a dual pivot.
    private var infeasibleRows: [Symbol] = []

    /// The registered edit variables.
    private var edits: [Variable: EditInfo] = [:]

    /// The last values written back by `updateVariables()`.
    private var externalValues: [Variable: Double] = [:]

    /// Variables whose external value changed since the last `fetchChanges()`.
    private var changedVariables: Set<Variable> = []

    /// The next symbol id. Ids are unique per solver and never reused except by
    /// `reset()`, which returns the solver to its initial state.
    private var idTick = 1

    public init() {}

    /// The number of symbols known to the solver, including the internal slack,
    /// error and dummy symbols.
    public var variableCount: Int {
        idTick - 1
    }

    /// The number of constraints held by the solver (edit-variable constraints
    /// are internal and not counted).
    public var constraintCount: Int {
        constraints.count
    }

    // MARK: - Constraints

    /// Adds a single constraint.
    ///
    /// - Throws: `SolverError.duplicateConstraint` if the exact constraint
    ///   object was already added.
    /// - Throws: `SolverError.unsatisfiableConstraint` if the constraint is
    ///   required and cannot be satisfied together with the constraints already
    ///   in the solver. The solver state is unchanged in that case.
    public func addConstraint(_ constraint: Constraint) throws {
        try addConstraintInternal(constraint)
        constraints.append(constraint)
    }

    /// Adds a batch of constraints, in order.
    ///
    /// If one of the constraints fails, the ones added before it remain in the
    /// solver; the failing constraint itself leaves the solver unchanged.
    public func addConstraints(_ constraints: [Constraint]) throws {
        for constraint in constraints {
            try addConstraint(constraint)
        }
    }

    /// Removes a previously added constraint.
    ///
    /// - Throws: `SolverError.unknownConstraint` if the constraint object was
    ///   not added to this solver.
    public func removeConstraint(_ constraint: Constraint) throws {
        let identifier = ObjectIdentifier(constraint)
        guard let tag = constraintTags[identifier] else {
            throw SolverError.unknownConstraint
        }
        let snapshot = makeSnapshot()
        do {
            try removeConstraintInternal(constraint, tag: tag)
            if let index = constraints.firstIndex(where: { $0 === constraint }) {
                constraints.remove(at: index)
            }
        } catch {
            restore(snapshot)
            throw error
        }
    }

    /// Whether `constraint` is held by the solver.
    public func hasConstraint(_ constraint: Constraint) -> Bool {
        constraints.contains { $0 === constraint }
    }

    // MARK: - Edit variables

    /// Registers `variable` as an edit variable, i.e. a variable whose value is
    /// driven externally through `suggestValue(_:_:)` and that is continuously
    /// resolved.
    ///
    /// The variable is held at its current external value until a value is
    /// suggested, as in Cassowary.
    ///
    /// - Throws: `SolverError.duplicateEditVariable` if the variable is already
    ///   an edit variable.
    /// - Throws: `SolverError.internalInconsistency` if `strength` is required:
    ///   requiring an edit variable would make the system unsatisfiable as soon
    ///   as a different value is suggested.
    public func addEditVariable(_ variable: Variable, strength: Strength = .strong) throws {
        if edits[variable] != nil {
            throw SolverError.duplicateEditVariable
        }
        let clipped = Strength.clip(strength.value)
        guard clipped < Strength.required else {
            throw SolverError.internalInconsistency("an edit variable cannot have required strength")
        }
        let constant = externalValues[variable] ?? 0.0
        // The edit constraint is `variable - constant == 0`; note that
        // `Expression(variable, coefficient)` takes a coefficient, so the
        // constant has to be built explicitly.
        let editExpression = Expression(variable, 1.0).minus(Expression(constant: constant))
        let constraint = Constraint(editExpression, .equal, strength: clipped)
        try addConstraintInternal(constraint)
        guard let tag = constraintTags[ObjectIdentifier(constraint)] else {
            throw SolverError.internalInconsistency("the edit constraint was not registered")
        }
        edits[variable] = EditInfo(tag: tag, constraint: constraint, constant: constant)
    }

    /// Removes a previously registered edit variable.
    ///
    /// - Throws: `SolverError.unknownEditVariable` if the variable is not an
    ///   edit variable.
    public func removeEditVariable(_ variable: Variable) throws {
        guard let info = edits[variable] else {
            throw SolverError.unknownEditVariable
        }
        let snapshot = makeSnapshot()
        do {
            try removeConstraintInternal(info.constraint, tag: info.tag)
            edits.removeValue(forKey: variable)
        } catch {
            restore(snapshot)
            throw error
        }
    }

    /// Whether `variable` is registered as an edit variable.
    public func hasEditVariable(_ variable: Variable) -> Bool {
        edits[variable] != nil
    }

    /// Suggests a new value for an edit variable, causing the solver to
    /// re-optimize.
    ///
    /// - Throws: `SolverError.unknownEditVariable` if the variable is not an
    ///   edit variable.
    public func suggestValue(_ variable: Variable, _ value: Double) throws {
        guard var info = edits[variable] else {
            throw SolverError.unknownEditVariable
        }
        let snapshot = makeSnapshot()
        do {
            let delta = value - info.constant
            info.constant = value
            edits[variable] = info

            // The edit constraint's row holds one of its two error symbols, or
            // neither. Move the constant of the row so the suggested value is
            // reflected, and note every row that became infeasible.
            if var row = rows[info.tag.marker] {
                let newConstant = row.add(-delta)
                rows[info.tag.marker] = row
                if newConstant < 0.0 {
                    infeasibleRows.append(info.tag.marker)
                }
            } else if var row = rows[info.tag.other] {
                let newConstant = row.add(delta)
                rows[info.tag.other] = row
                if newConstant < 0.0 {
                    infeasibleRows.append(info.tag.other)
                }
            } else {
                for basic in rows.keys.sorted() {
                    guard var row = rows[basic] else { continue }
                    let coefficient = row.coefficient(for: info.tag.marker)
                    if coefficient != 0.0 {
                        let newConstant = row.add(delta * coefficient)
                        rows[basic] = row
                        if newConstant < 0.0 && !basic.isExternal {
                            infeasibleRows.append(basic)
                        }
                    }
                }
            }

            guard dualOptimize() else {
                throw SolverError.internalInconsistency("the dual simplex failed to re-optimize the edited system")
            }
        } catch {
            restore(snapshot)
            throw error
        }
    }

    // MARK: - External values

    /// Updates the external (user-facing) value of all variables from the
    /// current tableau.
    ///
    /// Variables that were never written to the tableau report `0`.
    public func updateVariables() {
        let sorted = variableSymbols.sorted { $0.value < $1.value }
        for (variable, symbol) in sorted {
            let newValue = rows[symbol]?.constant ?? 0.0
            if let oldValue = externalValues[variable] {
                if oldValue != newValue {
                    externalValues[variable] = newValue
                    changedVariables.insert(variable)
                }
            } else {
                externalValues[variable] = newValue
                // The implicit previous value of an unknown variable is zero.
                if newValue != 0.0 {
                    changedVariables.insert(variable)
                }
            }
        }
    }

    /// Re-optimizes the system after edit-variable values changed, then
    /// refreshes the external values.
    ///
    /// Calling this after `suggestValue(_:_:)` is optional — the solver
    /// re-optimizes immediately — but it is harmless and keeps the "suggest,
    /// resolve" workflow of Cassowary available.
    public func resolve() {
        _ = dualOptimize()
        updateVariables()
    }

    /// The current value of a variable in the last solution (0 if it never
    /// appeared / was never updated).
    public func value(of variable: Variable) -> Double {
        externalValues[variable] ?? 0.0
    }

    /// Variables whose external values changed since the previous call, with
    /// their new values.
    ///
    /// The change set is cleared by this call. Changes are reported in variable
    /// creation order.
    public func fetchChanges() -> [(Variable, Double)] {
        updateVariables()
        let sorted = changedVariables.sorted { $0.id < $1.id }
        changedVariables.removeAll()
        return sorted.map { ($0, externalValues[$0] ?? 0.0) }
    }

    /// Removes all constraints, edit variables and external values.
    public func reset() {
        constraints.removeAll()
        constraintTags.removeAll()
        rows.removeAll()
        variableSymbols.removeAll()
        objective = Row()
        artificialRow = nil
        infeasibleRows.removeAll()
        edits.removeAll()
        externalValues.removeAll()
        changedVariables.removeAll()
        idTick = 1
    }

    // MARK: - Tableau snapshots

    /// A shallow copy of the complete solver state.
    ///
    /// The rows share their cell dictionaries with the live tableau and Swift's
    /// copy-on-write makes both taking and restoring a snapshot cheap, so every
    /// operation that can fail is transactional.
    private struct Snapshot {
        var constraints: [Constraint]
        var constraintTags: [ObjectIdentifier: ConstraintTag]
        var rows: [Symbol: Row]
        var variableSymbols: [Variable: Symbol]
        var objective: Row
        var artificialRow: Row?
        var infeasibleRows: [Symbol]
        var edits: [Variable: EditInfo]
        var externalValues: [Variable: Double]
        var changedVariables: Set<Variable>
        var idTick: Int
    }

    private func makeSnapshot() -> Snapshot {
        Snapshot(
            constraints: constraints,
            constraintTags: constraintTags,
            rows: rows,
            variableSymbols: variableSymbols,
            objective: objective,
            artificialRow: artificialRow,
            infeasibleRows: infeasibleRows,
            edits: edits,
            externalValues: externalValues,
            changedVariables: changedVariables,
            idTick: idTick
        )
    }

    private func restore(_ snapshot: Snapshot) {
        constraints = snapshot.constraints
        constraintTags = snapshot.constraintTags
        rows = snapshot.rows
        variableSymbols = snapshot.variableSymbols
        objective = snapshot.objective
        artificialRow = snapshot.artificialRow
        infeasibleRows = snapshot.infeasibleRows
        edits = snapshot.edits
        externalValues = snapshot.externalValues
        changedVariables = snapshot.changedVariables
        idTick = snapshot.idTick
    }

    // MARK: - Adding constraints

    /// Adds a constraint to the tableau, registering its tag but not adding it
    /// to the public `constraints` list. Used for both user constraints and the
    /// internal constraints behind edit variables.
    private func addConstraintInternal(_ constraint: Constraint) throws {
        let identifier = ObjectIdentifier(constraint)
        if constraintTags[identifier] != nil {
            throw SolverError.duplicateConstraint
        }
        let snapshot = makeSnapshot()
        do {
            let tag = try createRowAndAddConstraint(constraint)
            constraintTags[identifier] = tag
        } catch {
            restore(snapshot)
            throw error
        }
    }

    /// Creates the tableau row for `constraint` and brings it into the basis.
    ///
    /// Required constraints are added with the two-phase method: if the row has
    /// no valid subject, an artificial variable is introduced and phase one
    /// drives its value to zero. Non-required constraints are added as weighted
    /// error terms of the objective.
    private func createRowAndAddConstraint(_ constraint: Constraint) throws -> ConstraintTag {
        var tag = ConstraintTag()
        var row = createRow(constraint, tag: &tag)
        var subject = chooseSubject(row, tag: tag)

        // If no valid subject was found, the only remaining option is a
        // redundant constraint: an all-dummy row that must have a zero constant.
        if subject == .invalid && allDummies(row) {
            guard nearZero(row.constant) else {
                throw SolverError.unsatisfiableConstraint
            }
            subject = tag.marker
        }

        if subject == .invalid {
            guard try addWithArtificialVariable(row) else {
                throw SolverError.unsatisfiableConstraint
            }
        } else {
            try row.solveFor(subject)
            substitute(subject, row)
            rows[subject] = row
        }

        try optimize(objectiveRow: .main)
        return tag
    }

    /// Builds the tableau row for `constraint`.
    ///
    /// Terms of the constraint whose variables are already basic are
    /// substituted in, so the new row only contains non-basic symbols. The row
    /// is then extended with the slack/error/dummy symbols that encode the
    /// relational operator and the strength. The constant is made positive so
    /// the slack variables are non-negative.
    private func createRow(_ constraint: Constraint, tag: inout ConstraintTag) -> Row {
        var row = Row(constant: constraint.expression.constant)

        for term in constraint.expression.terms {
            if !nearZero(term.coefficient) {
                let symbol = symbol(for: term.variable)
                if let basicRow = rows[symbol] {
                    row.insert(basicRow, term.coefficient)
                } else {
                    row.insert(symbol, term.coefficient)
                }
            }
        }

        switch constraint.op {
        case .lessThanOrEqual, .greaterThanOrEqual:
            // expression <= 0  =>  expression + slack = 0
            // expression >= 0  =>  expression - slack = 0
            let coefficient = constraint.op == .lessThanOrEqual ? 1.0 : -1.0
            let slack = makeSymbol(.slack)
            tag.marker = slack
            row.insert(slack, coefficient)
            if !constraint.isRequired {
                let error = makeSymbol(.error)
                tag.other = error
                row.insert(error, -coefficient)
                objective.insert(error, constraint.strength.value)
            }

        case .equal:
            if constraint.isRequired {
                let dummy = makeSymbol(.dummy)
                tag.marker = dummy
                row.insert(dummy)
            } else {
                // expression == errPlus - errMinus, both penalized.
                let errorPlus = makeSymbol(.error)
                let errorMinus = makeSymbol(.error)
                tag.marker = errorPlus
                tag.other = errorMinus
                row.insert(errorPlus, -1.0)
                row.insert(errorMinus, 1.0)
                objective.insert(errorPlus, constraint.strength.value)
                objective.insert(errorMinus, constraint.strength.value)
            }
        }

        // The row must start with a positive constant; otherwise invert it.
        if row.constant < 0.0 {
            row.reverseSign()
        }
        return row
    }

    /// Chooses the subject symbol for a new row.
    ///
    /// Precedence, as in kiwi:
    /// 1. the first external variable in the row,
    /// 2. a slack or error tag symbol with a negative coefficient.
    ///
    /// Returns `.invalid` when the row needs an artificial variable.
    private func chooseSubject(_ row: Row, tag: ConstraintTag) -> Symbol {
        for symbol in row.symbols {
            if symbol.isExternal {
                return symbol
            }
        }
        if tag.marker.isPivotable && row.coefficient(for: tag.marker) < 0.0 {
            return tag.marker
        }
        if tag.other.isPivotable && row.coefficient(for: tag.other) < 0.0 {
            return tag.other
        }
        return .invalid
    }

    /// Whether the row consists solely of dummy symbols.
    private func allDummies(_ row: Row) -> Bool {
        for symbol in row.symbols {
            if !symbol.isDummy {
                return false
            }
        }
        return true
    }

    // MARK: - Artificial variables (phase one)

    /// Adds a row using the artificial-variable two-phase method.
    ///
    /// Phase one minimizes the artificial variable; the constraint is
    /// satisfiable exactly when that minimum is zero. Returns `false` when it is
    /// not (the caller rolls the tableau back).
    private func addWithArtificialVariable(_ row: Row) throws -> Bool {
        let artificialSymbol = makeSymbol(.slack)
        rows[artificialSymbol] = row
        artificialRow = row

        try optimize(objectiveRow: .artificial)

        // The artificial objective is zero exactly when the constraint is
        // satisfiable together with the ones already in the solver.
        let success = nearZero(artificialRow?.constant ?? 0.0)
        artificialRow = nil

        // If the artificial variable is still basic, pivot it out of the basis.
        if var artificialTableauRow = rows[artificialSymbol] {
            rows.removeValue(forKey: artificialSymbol)
            if artificialTableauRow.isEmpty {
                return success
            }
            let entering = anyPivotableSymbol(artificialTableauRow)
            guard entering != .invalid else {
                return false
            }
            try artificialTableauRow.solveFor(artificialSymbol, entering)
            substitute(entering, artificialTableauRow)
            rows[entering] = artificialTableauRow
        }

        // Remove every remaining trace of the artificial variable.
        for basic in rows.keys.sorted() {
            guard var basicRow = rows[basic] else { continue }
            basicRow.remove(artificialSymbol)
            rows[basic] = basicRow
        }
        objective.remove(artificialSymbol)
        return success
    }

    // MARK: - Tableau operations

    /// Substitutes `symbol` with `row` everywhere in the tableau and objective.
    ///
    /// Newly infeasible rows are recorded so a later dual optimization can fix
    /// them.
    private func substitute(_ symbol: Symbol, _ row: Row) {
        for basic in rows.keys.sorted() {
            guard let stored = rows[basic] else { continue }
            guard stored.coefficient(for: symbol) != 0.0 else {
                // Most rows do not contain the symbol. Keep the feasibility
                // bookkeeping identical to the reference implementation, but
                // skip the copy-on-write round trip for untouched rows.
                if !basic.isExternal && stored.constant < 0.0 {
                    infeasibleRows.append(basic)
                }
                continue
            }
            var basicRow = stored
            basicRow.substitute(symbol, with: row)
            rows[basic] = basicRow
            if !basic.isExternal && basicRow.constant < 0.0 {
                infeasibleRows.append(basic)
            }
        }
        objective.substitute(symbol, with: row)
        artificialRow?.substitute(symbol, with: row)
    }

    /// The objective used by `optimize(objectiveRow:)`.
    private enum ObjectiveRow {
        case main
        case artificial
    }

    /// Runs the primal simplex method on `objectiveRow` until it is optimal.
    ///
    /// - Throws: `SolverError.internalInconsistency` if the objective is
    ///   unbounded, which indicates a numerical failure.
    private func optimize(objectiveRow: ObjectiveRow) throws {
        while true {
            let context: Row
            switch objectiveRow {
            case .main:
                context = objective
            case .artificial:
                guard let artificial = artificialRow else { return }
                context = artificial
            }

            let entering = getEnteringSymbol(context)
            if entering == .invalid {
                return
            }
            guard let leaving = getLeavingRow(entering) else {
                throw SolverError.internalInconsistency("the objective is unbounded")
            }
            guard var leavingRow = rows[leaving] else {
                throw SolverError.internalInconsistency("the tableau lost a basic row")
            }
            rows.removeValue(forKey: leaving)
            try leavingRow.solveFor(leaving, entering)
            substitute(entering, leavingRow)
            rows[entering] = leavingRow
        }
    }

    /// Runs the dual simplex method until every recorded infeasible row is
    /// feasible again. The objective is assumed to be optimal already, which is
    /// the case after a constraint is removed or an edit value is suggested.
    ///
    /// - Returns: `false` when a row could not be made feasible.
    private func dualOptimize() -> Bool {
        while !infeasibleRows.isEmpty {
            let leaving = infeasibleRows.removeLast()
            guard let row = rows[leaving] else { continue }
            if nearZero(row.constant) || row.constant >= 0.0 {
                continue
            }
            let entering = getDualEnteringSymbol(row)
            guard entering != .invalid else {
                return false
            }
            var leavingRow = row
            rows.removeValue(forKey: leaving)
            do {
                try leavingRow.solveFor(leaving, entering)
            } catch {
                return false
            }
            substitute(entering, leavingRow)
            rows[entering] = leavingRow
        }
        return true
    }

    /// The first non-dummy symbol with a negative coefficient in the objective.
    private func getEnteringSymbol(_ objective: Row) -> Symbol {
        for symbol in objective.symbols {
            if !symbol.isDummy && objective.coefficient(for: symbol) < 0.0 {
                return symbol
            }
        }
        return .invalid
    }

    /// The symbol whose ratio `objectiveCoefficient / rowCoefficient` is
    /// smallest among the positive coefficients of an infeasible row.
    private func getDualEnteringSymbol(_ row: Row) -> Symbol {
        var ratio = Double.greatestFiniteMagnitude
        var entering = Symbol.invalid
        for symbol in row.symbols {
            let coefficient = row.coefficient(for: symbol)
            if coefficient > 0.0 && !symbol.isDummy {
                let objectiveCoefficient = objective.coefficient(for: symbol)
                let candidate = objectiveCoefficient / coefficient
                if candidate < ratio {
                    ratio = candidate
                    entering = symbol
                }
            }
        }
        return entering
    }

    /// The first slack or error symbol in the row, if any.
    private func anyPivotableSymbol(_ row: Row) -> Symbol {
        for symbol in row.symbols {
            if symbol.isPivotable {
                return symbol
            }
        }
        return .invalid
    }

    /// The basic symbol whose row has the smallest ratio of `-constant /
    /// coefficient` among rows with a negative coefficient for `entering`.
    private func getLeavingRow(_ entering: Symbol) -> Symbol? {
        var ratio = Double.greatestFiniteMagnitude
        var found: Symbol?
        for basic in rows.keys.sorted() {
            guard !basic.isExternal, let row = rows[basic] else { continue }
            let coefficient = row.coefficient(for: entering)
            if coefficient < 0.0 {
                let candidate = -row.constant / coefficient
                if candidate < ratio {
                    ratio = candidate
                    found = basic
                }
            }
        }
        return found
    }

    /// Chooses the row to pivot the marker of a removed constraint into.
    ///
    /// Precedence, as in kiwi:
    /// 1. a restricted row with a negative marker coefficient and the smallest
    ///    ratio `-constant / coefficient`,
    /// 2. a restricted row with the smallest ratio `constant / coefficient`,
    /// 3. the last unrestricted row containing the marker.
    private func getMarkerLeavingRow(_ marker: Symbol) -> Symbol? {
        let maximum = Double.greatestFiniteMagnitude
        var firstRatio = maximum
        var secondRatio = maximum
        var first: Symbol?
        var second: Symbol?
        var third: Symbol?

        for basic in rows.keys.sorted() {
            guard let row = rows[basic] else { continue }
            let coefficient = row.coefficient(for: marker)
            if coefficient == 0.0 {
                continue
            }
            if basic.isExternal {
                third = basic
            } else if coefficient < 0.0 {
                let ratio = -row.constant / coefficient
                if ratio < firstRatio {
                    firstRatio = ratio
                    first = basic
                }
            } else {
                let ratio = row.constant / coefficient
                if ratio < secondRatio {
                    secondRatio = ratio
                    second = basic
                }
            }
        }
        if let first = first {
            return first
        }
        if let second = second {
            return second
        }
        return third
    }

    // MARK: - Constraint bookkeeping

    /// Removes `constraint` from the tableau. The caller is responsible for the
    /// surrounding snapshot/restore and for removing the public bookkeeping.
    private func removeConstraintInternal(_ constraint: Constraint, tag: ConstraintTag) throws {
        // The error effects must be removed from the objective *before*
        // pivoting, or substitutions into the objective would use the wrong
        // weights.
        removeConstraintEffects(constraint, tag: tag)

        // If the marker is basic, drop its row. Otherwise pivot the marker into
        // the basis first, then drop the row it left.
        if rows[tag.marker] != nil {
            rows.removeValue(forKey: tag.marker)
        } else {
            guard let leaving = getMarkerLeavingRow(tag.marker) else {
                throw SolverError.internalInconsistency("failed to find a leaving row for the removed constraint")
            }
            guard var leavingRow = rows[leaving] else {
                throw SolverError.internalInconsistency("the tableau lost a basic row")
            }
            // Pivot the marker into the basis, substitute it throughout the
            // tableau and then drop the row: nothing references the marker any
            // more, so keeping a dead basic row would leave the tableau
            // primal-infeasible for the next constraint that is added.
            rows.removeValue(forKey: leaving)
            try leavingRow.solveFor(leaving, tag.marker)
            substitute(tag.marker, leavingRow)
        }

        // Re-optimize: removing a non-basic marker can make the objective
        // sub-optimal, so the primal simplex restores optimality.
        try optimize(objectiveRow: .main)
        constraintTags.removeValue(forKey: ObjectIdentifier(constraint))
    }

    /// Removes the objective contribution of a constraint's error symbols.
    private func removeConstraintEffects(_ constraint: Constraint, tag: ConstraintTag) {
        if tag.marker.kind == .error {
            removeMarkerEffects(tag.marker, strength: constraint.strength.value)
        }
        if tag.other.kind == .error {
            removeMarkerEffects(tag.other, strength: constraint.strength.value)
        }
    }

    /// Removes the objective contribution of a single error marker.
    private func removeMarkerEffects(_ marker: Symbol, strength: Double) {
        if let row = rows[marker] {
            objective.insert(row, -strength)
        } else {
            objective.insert(marker, -strength)
        }
    }

    // MARK: - Symbols

    /// The symbol for `variable`, allocating one on first use.
    ///
    /// Allocation order determines every symbol id, so the ids — and therefore
    /// all tie-breaks — depend only on the sequence of calls into the solver.
    private func symbol(for variable: Variable) -> Symbol {
        if let symbol = variableSymbols[variable] {
            return symbol
        }
        let symbol = makeSymbol(.external)
        variableSymbols[variable] = symbol
        return symbol
    }

    /// Allocates a fresh symbol of the given kind.
    private func makeSymbol(_ kind: Symbol.Kind) -> Symbol {
        let symbol = Symbol(kind, idTick)
        idTick += 1
        return symbol
    }
}
