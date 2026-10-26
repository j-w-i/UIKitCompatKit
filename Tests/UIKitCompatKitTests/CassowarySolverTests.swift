//
//  CassowarySolverTests.swift
//  UIKitCompatKitTests
//
//  Tests for the pure-Swift Cassowary solver.
//
//  The cases are ported from the reference implementations:
//  * `kiwi` (https://github.com/nucleic/kiwi, Modified BSD, Copyright (c)
//    2013-2026 Nucleic Development Team) — `py/tests/test_solver.py` and the
//    classic `simpleNew`/`simple0`/`simple1`/`casso1`/`addDelete`/
//    `inconsistent` suite that shipped with kiwi and its ports.
//  * kiwi-java (https://github.com/alexbirkett/kiwi-java, BSD) for the classic
//    `casso1`, `addDelete1` and `addDelete2` cases.
//  * The Cassowary paper (Badros & Borning, "The Cassowary Linear Arithmetic
//    Constraint Solving Algorithm") for the edit-variable "one-way" example.
//

import XCTest
import Cassowary

// Modern Foundation exposes a generic `Expression` type (macOS 15+/iOS 18+),
// which makes the unqualified name ambiguous inside the test target. Alias the
// solver type once for the whole file.
private typealias Expression = Cassowary.Expression

final class CassowarySolverTests: XCTestCase {

    private let defaultAccuracy = 1.0e-6

    // MARK: - Expression / constraint builders
    //
    // The module deliberately exposes no operator sugar (the public contract is
    // the explicit `Expression`/`Constraint` API), so the tests build
    // constraints explicitly. These helpers keep the cases readable.

    private func expression(_ terms: [(Variable, Double)] = [],
                            constant: Double = 0.0) -> Expression {
        var result = Expression(constant: constant)
        for (variable, coefficient) in terms {
            result = result.plus(Expression(variable, coefficient))
        }
        return result
    }

    private func equal(_ lhs: Expression,
                       _ rhs: Expression,
                       strength: Strength = .required,
                       name: String? = nil) -> Constraint {
        Constraint(lhs.minus(rhs), .equal, strength: strength, name: name)
    }

    private func equal(_ lhs: Expression,
                       _ rhs: Double,
                       strength: Strength = .required,
                       name: String? = nil) -> Constraint {
        equal(lhs, Expression(constant: rhs), strength: strength, name: name)
    }

    private func lessThanOrEqual(_ lhs: Expression,
                                 _ rhs: Double,
                                 strength: Strength = .required,
                                 name: String? = nil) -> Constraint {
        Constraint(lhs.minus(Expression(constant: rhs)), .lessThanOrEqual, strength: strength, name: name)
    }

    private func lessThanOrEqual(_ lhs: Expression,
                                 _ rhs: Expression,
                                 strength: Strength = .required,
                                 name: String? = nil) -> Constraint {
        Constraint(lhs.minus(rhs), .lessThanOrEqual, strength: strength, name: name)
    }

    private func greaterThanOrEqual(_ lhs: Expression,
                                    _ rhs: Double,
                                    strength: Strength = .required,
                                    name: String? = nil) -> Constraint {
        Constraint(lhs.minus(Expression(constant: rhs)), .greaterThanOrEqual, strength: strength, name: name)
    }

    private func greaterThanOrEqual(_ lhs: Expression,
                                    _ rhs: Expression,
                                    strength: Strength = .required,
                                    name: String? = nil) -> Constraint {
        Constraint(lhs.minus(rhs), .greaterThanOrEqual, strength: strength, name: name)
    }

    /// Evaluates `expression` against the solver's current external values.
    private func value(of expression: Cassowary.Expression, in solver: Solver) -> Double {
        var result = expression.constant
        for term in expression.terms {
            result += term.coefficient * solver.value(of: term.variable)
        }
        return result
    }

    private func assertValue(_ solver: Solver,
                             _ variable: Variable,
                             _ expected: Double,
                             accuracy: Double? = nil,
                             file: StaticString = #filePath,
                             line: UInt = #line) {
        XCTAssertEqual(solver.value(of: variable), expected,
                       accuracy: accuracy ?? defaultAccuracy,
                       file: file, line: line)
    }

    // MARK: - Simple systems

    func testSimpleNew() throws {
        let solver = Solver()
        let x = Variable("x")

        // x + 2 == 20
        try solver.addConstraint(equal(expression([(x, 1.0)], constant: 2.0), 20.0))
        solver.updateVariables()

        assertValue(solver, x, 18.0)
    }

    func testSimple0() throws {
        let solver = Solver()
        let x = Variable("x")
        let y = Variable("y")

        // x == 20
        try solver.addConstraint(equal(expression([(x, 1.0)]), 20.0))
        // x + 2 == y + 10
        try solver.addConstraint(equal(expression([(x, 1.0)], constant: 2.0),
                                       expression([(y, 1.0)], constant: 10.0)))
        solver.updateVariables()

        assertValue(solver, x, 20.0)
        assertValue(solver, y, 12.0)
    }

    func testSimple1() throws {
        let solver = Solver()
        let x = Variable("x")
        let y = Variable("y")

        // x == y, an under-constrained system: any common value is a solution.
        try solver.addConstraint(equal(expression([(x, 1.0)]), expression([(y, 1.0)])))
        solver.updateVariables()

        XCTAssertEqual(solver.value(of: x), solver.value(of: y), accuracy: defaultAccuracy)
    }

    func testSimpleInequalities() throws {
        let solver = Solver()
        let x = Variable("x")
        let y = Variable("y")

        try solver.addConstraint(greaterThanOrEqual(expression([(x, 1.0)]), 100.0))
        try solver.addConstraint(lessThanOrEqual(expression([(y, 1.0)]), -100.0))
        solver.updateVariables()

        assertValue(solver, x, 100.0)
        assertValue(solver, y, -100.0)
    }

    func testWeakInequalityIsSacrificedForRequiredEquality() throws {
        let solver = Solver()
        let x = Variable("x")

        // x == 0 is required, x >= 10 is weak: the weak constraint loses.
        try solver.addConstraint(equal(expression([(x, 1.0)]), 0.0))
        try solver.addConstraint(greaterThanOrEqual(expression([(x, 1.0)]), 10.0, strength: .weak))
        solver.updateVariables()

        assertValue(solver, x, 0.0)
    }

    func testCasso1() throws {
        let solver = Solver()
        let x = Variable("x")
        let y = Variable("y")

        // The classic `casso1` case: two weak preferences inside a required
        // one-way relationship. The optimal set is the interval [7, 10]; a
        // simplex solver lands on one of its vertices.
        try solver.addConstraint(lessThanOrEqual(expression([(x, 1.0)]), expression([(y, 1.0)])))
        try solver.addConstraint(equal(expression([(y, 1.0)]), expression([(x, 1.0)], constant: 3.0)))
        try solver.addConstraint(equal(expression([(x, 1.0)]), 10.0, strength: .weak))
        try solver.addConstraint(equal(expression([(y, 1.0)]), 10.0, strength: .weak))
        solver.updateVariables()

        if abs(solver.value(of: x) - 10.0) < defaultAccuracy {
            assertValue(solver, x, 10.0)
            assertValue(solver, y, 13.0)
        } else {
            assertValue(solver, x, 7.0)
            assertValue(solver, y, 10.0)
        }
    }

    // MARK: - Add / remove churn

    func testAddDelete1() throws {
        let solver = Solver()
        let x = Variable("x")

        try solver.addConstraint(lessThanOrEqual(expression([(x, 1.0)]), 100.0, strength: .weak))
        solver.updateVariables()
        assertValue(solver, x, 100.0)

        let c10 = lessThanOrEqual(expression([(x, 1.0)]), 10.0)
        let c20 = lessThanOrEqual(expression([(x, 1.0)]), 20.0)

        try solver.addConstraint(c10)
        try solver.addConstraint(c20)
        solver.updateVariables()
        assertValue(solver, x, 10.0)

        try solver.removeConstraint(c10)
        solver.updateVariables()
        assertValue(solver, x, 20.0)

        try solver.removeConstraint(c20)
        solver.updateVariables()
        assertValue(solver, x, 100.0)

        let c10again = lessThanOrEqual(expression([(x, 1.0)]), 10.0)
        try solver.addConstraint(c10again)
        try solver.addConstraint(c10)
        solver.updateVariables()
        assertValue(solver, x, 10.0)

        try solver.removeConstraint(c10)
        solver.updateVariables()
        assertValue(solver, x, 10.0)

        try solver.removeConstraint(c10again)
        solver.updateVariables()
        assertValue(solver, x, 100.0)
    }

    func testAddDelete2() throws {
        let solver = Solver()
        let x = Variable("x")
        let y = Variable("y")

        try solver.addConstraint(equal(expression([(x, 1.0)]), 100.0, strength: .weak))
        try solver.addConstraint(equal(expression([(y, 1.0)]), 120.0, strength: .strong))

        let c10 = lessThanOrEqual(expression([(x, 1.0)]), 10.0)
        let c20 = lessThanOrEqual(expression([(x, 1.0)]), 20.0)
        try solver.addConstraint(c10)
        try solver.addConstraint(c20)
        solver.updateVariables()
        assertValue(solver, x, 10.0)
        assertValue(solver, y, 120.0)

        try solver.removeConstraint(c10)
        solver.updateVariables()
        assertValue(solver, x, 20.0)
        assertValue(solver, y, 120.0)

        // 2 * x == y
        let cxy = equal(expression([(x, 2.0)]), expression([(y, 1.0)]))
        try solver.addConstraint(cxy)
        solver.updateVariables()
        assertValue(solver, x, 20.0)
        assertValue(solver, y, 40.0)

        try solver.removeConstraint(c20)
        solver.updateVariables()
        assertValue(solver, x, 60.0)
        assertValue(solver, y, 120.0)

        try solver.removeConstraint(cxy)
        solver.updateVariables()
        assertValue(solver, x, 100.0)
        assertValue(solver, y, 120.0)

        XCTAssertEqual(solver.constraintCount, 2)
    }

    func testConstraintChurn() throws {
        let solver = Solver()
        let variables = (0..<30).map { Variable("x\($0)") }

        for (index, variable) in variables.enumerated() {
            try solver.addConstraint(equal(expression([(variable, 1.0)]), Double(index)))
        }
        solver.updateVariables()
        for (index, variable) in variables.enumerated() {
            assertValue(solver, variable, Double(index))
        }

        // Remove every second equality; the remaining system still determines
        // the other half, and the removed variables fall back to zero.
        for index in stride(from: 0, to: variables.count, by: 2) {
            try solver.removeConstraint(solver.constraints.first { $0.expression.coefficient(of: variables[index]) != 0.0 }!)
        }
        solver.updateVariables()
        for (index, variable) in variables.enumerated() {
            assertValue(solver, variable, index % 2 == 0 ? 0.0 : Double(index))
        }

        // Remove the rest; the solver ends up empty but usable.
        while let constraint = solver.constraints.first {
            try solver.removeConstraint(constraint)
        }
        XCTAssertEqual(solver.constraintCount, 0)
        XCTAssertEqual(solver.constraints.count, 0)
        solver.updateVariables()
        for variable in variables {
            assertValue(solver, variable, 0.0)
        }

        // The same solver can be reused after being emptied.
        try solver.addConstraint(equal(expression([(variables[0], 1.0)]), 42.0))
        solver.updateVariables()
        assertValue(solver, variables[0], 42.0)
    }

    func testRepeatedAddRemoveOfSameConstraint() throws {
        let solver = Solver()
        let x = Variable("x")
        let constraint = equal(expression([(x, 1.0)]), 10.0)

        for _ in 0..<10 {
            try solver.addConstraint(constraint)
            solver.updateVariables()
            assertValue(solver, x, 10.0)
            try solver.removeConstraint(constraint)
            XCTAssertFalse(solver.hasConstraint(constraint))
            XCTAssertThrowsError(try solver.removeConstraint(constraint)) { error in
                XCTAssertEqual(error as? SolverError, .unknownConstraint)
            }
        }
        XCTAssertEqual(solver.constraintCount, 0)
    }

    func testAddingRedundantRequiredEquality() throws {
        let solver = Solver()
        let x = Variable("x")

        // Two distinct constraint objects describing the same equality must be
        // accepted: the second row reduces to a redundant all-dummy row.
        let first = equal(expression([(x, 1.0)]), 5.0)
        let second = equal(expression([(x, 1.0)]), 5.0)
        try solver.addConstraint(first)
        XCTAssertNoThrow(try solver.addConstraint(second))
        solver.updateVariables()

        assertValue(solver, x, 5.0)
        XCTAssertEqual(solver.constraintCount, 2)
    }

    func testConstantOnlyConstraints() throws {
        let solver = Solver()

        // 0 == 0 is a redundant required constraint and must be accepted.
        XCTAssertNoThrow(try solver.addConstraint(equal(Expression(constant: 0.0), 0.0)))
        // 5 == 0 is unsatisfiable at required strength.
        XCTAssertThrowsError(try solver.addConstraint(equal(Expression(constant: 5.0), 0.0))) { error in
            XCTAssertEqual(error as? SolverError, .unsatisfiableConstraint)
        }
        // 0 <= 5 and 5 >= 0 hold trivially.
        XCTAssertNoThrow(try solver.addConstraint(lessThanOrEqual(Expression(constant: 0.0), 5.0)))
        XCTAssertNoThrow(try solver.addConstraint(greaterThanOrEqual(Expression(constant: 5.0), 0.0)))
        // 5 <= 0 and 0 >= 5 are unsatisfiable.
        XCTAssertThrowsError(try solver.addConstraint(lessThanOrEqual(Expression(constant: 5.0), 0.0)))
        XCTAssertThrowsError(try solver.addConstraint(greaterThanOrEqual(Expression(constant: 0.0), 5.0)))
        XCTAssertEqual(solver.constraintCount, 3)

        // The solver is still usable after those failures.
        let x = Variable("x")
        try solver.addConstraint(equal(expression([(x, 1.0)]), 7.0))
        solver.updateVariables()
        assertValue(solver, x, 7.0)
    }

    func testNearZeroCoefficientsAreIgnored() throws {
        let solver = Solver()
        let x = Variable("x")

        // kiwi ignores coefficients below the 1e-8 tolerance, so this is a
        // constant 0 == 0 row (redundant) rather than a constraint on x.
        try solver.addConstraint(Constraint(expression([(x, 1.0e-9)]), .equal))
        solver.updateVariables()
        assertValue(solver, x, 0.0)
        XCTAssertEqual(solver.constraintCount, 1)
    }

    func testRemoveOptionalConstraintRestoresPreference() throws {
        let solver = Solver()
        let x = Variable("x")

        try solver.addConstraint(equal(expression([(x, 1.0)]), 10.0, strength: .weak))
        solver.updateVariables()
        assertValue(solver, x, 10.0)

        // A required equality temporarily overrules the weak preference.
        let required = equal(expression([(x, 1.0)]), 20.0)
        try solver.addConstraint(required)
        solver.updateVariables()
        assertValue(solver, x, 20.0)

        // Removing it removes its objective effects and restores the optimum.
        try solver.removeConstraint(required)
        solver.updateVariables()
        assertValue(solver, x, 10.0)
    }

    func testRemoveStrongOptionalConstraint() throws {
        let solver = Solver()
        let x = Variable("x")

        let weak = equal(expression([(x, 1.0)]), 10.0, strength: .weak)
        let strong = equal(expression([(x, 1.0)]), 20.0, strength: .strong)
        try solver.addConstraint(weak)
        try solver.addConstraint(strong)
        solver.updateVariables()
        assertValue(solver, x, 20.0)

        try solver.removeConstraint(strong)
        solver.updateVariables()
        assertValue(solver, x, 10.0)

        try solver.removeConstraint(weak)
        solver.updateVariables()
        assertValue(solver, x, 0.0)
        XCTAssertEqual(solver.constraintCount, 0)
    }

    func testBatchAddStopsAtFirstFailure() throws {
        let solver = Solver()
        let x = Variable("x")

        XCTAssertThrowsError(try solver.addConstraints([
            equal(expression([(x, 1.0)]), 1.0),
            equal(expression([(x, 1.0)]), 2.0),
            equal(expression([(x, 1.0)]), 3.0)
        ])) { error in
            XCTAssertEqual(error as? SolverError, .unsatisfiableConstraint)
        }

        // The constraints before the failing one were added, the rest were not.
        XCTAssertEqual(solver.constraintCount, 1)
        solver.updateVariables()
        assertValue(solver, x, 1.0)
    }

    // MARK: - Errors and inconsistent systems

    func testInconsistent1() throws {
        let solver = Solver()
        let x = Variable("x")

        try solver.addConstraint(equal(expression([(x, 1.0)]), 10.0))
        XCTAssertThrowsError(try solver.addConstraint(equal(expression([(x, 1.0)]), 5.0))) { error in
            XCTAssertEqual(error as? SolverError, .unsatisfiableConstraint)
        }

        // The failed constraint is not recorded and the solution is unchanged.
        XCTAssertEqual(solver.constraintCount, 1)
        solver.updateVariables()
        assertValue(solver, x, 10.0)

        // The solver remains usable: replacing the constraint succeeds.
        try solver.removeConstraint(solver.constraints[0])
        try solver.addConstraint(equal(expression([(x, 1.0)]), 5.0))
        solver.updateVariables()
        assertValue(solver, x, 5.0)
    }

    func testInconsistent2() throws {
        let solver = Solver()
        let x = Variable("x")

        try solver.addConstraint(greaterThanOrEqual(expression([(x, 1.0)]), 10.0))
        XCTAssertThrowsError(try solver.addConstraint(lessThanOrEqual(expression([(x, 1.0)]), 5.0))) { error in
            XCTAssertEqual(error as? SolverError, .unsatisfiableConstraint)
        }
        solver.updateVariables()
        XCTAssertGreaterThanOrEqual(solver.value(of: x), 10.0 - defaultAccuracy)
    }

    func testInconsistent3() throws {
        let solver = Solver()
        let w = Variable("w")
        let x = Variable("x")
        let y = Variable("y")
        let z = Variable("z")

        try solver.addConstraint(greaterThanOrEqual(expression([(w, 1.0)]), 10.0))
        try solver.addConstraint(greaterThanOrEqual(expression([(x, 1.0)]), expression([(w, 1.0)])))
        try solver.addConstraint(greaterThanOrEqual(expression([(y, 1.0)]), expression([(x, 1.0)])))
        try solver.addConstraint(greaterThanOrEqual(expression([(z, 1.0)]), expression([(y, 1.0)])))
        try solver.addConstraint(greaterThanOrEqual(expression([(z, 1.0)]), 8.0))
        XCTAssertThrowsError(try solver.addConstraint(lessThanOrEqual(expression([(z, 1.0)]), 4.0))) { error in
            XCTAssertEqual(error as? SolverError, .unsatisfiableConstraint)
        }

        solver.updateVariables()
        XCTAssertGreaterThanOrEqual(solver.value(of: z), 8.0 - defaultAccuracy)
        XCTAssertEqual(solver.constraintCount, 5)
    }

    func testUnsatisfiableRequiredConstraintLeavesSolverUnchanged() throws {
        let solver = Solver()
        let x = Variable("x")
        let y = Variable("y")

        try solver.addConstraint(equal(expression([(x, 1.0)]), 0.0, strength: .weak))
        try solver.addConstraint(equal(expression([(y, 1.0)]), 0.0, strength: .medium))
        let sum = greaterThanOrEqual(expression([(x, 1.0), (y, 1.0)]), 10.0)
        try solver.addConstraint(sum)
        try solver.addConstraint(greaterThanOrEqual(expression([(x, 1.0), (y, -1.0)]), 2.0))

        solver.updateVariables()
        assertValue(solver, x, 10.0)
        assertValue(solver, y, 0.0)
        let changeCountBefore = solver.constraintCount

        // An inequality that can only be added by pivoting must still roll back.
        let bound = lessThanOrEqual(expression([(x, 1.0)]), 5.0)
        XCTAssertThrowsError(try solver.addConstraint(bound)) { error in
            XCTAssertEqual(error as? SolverError, .unsatisfiableConstraint)
        }
        XCTAssertFalse(solver.hasConstraint(bound))
        XCTAssertEqual(solver.constraintCount, changeCountBefore)
        solver.updateVariables()
        assertValue(solver, x, 10.0)
        assertValue(solver, y, 0.0)

        // Removing the conflicting sum makes the bound satisfiable again.
        try solver.removeConstraint(sum)
        try solver.addConstraint(bound)
        solver.updateVariables()
        assertValue(solver, x, 2.0)
        assertValue(solver, y, 0.0)
    }

    func testDuplicateAndUnknownConstraint() throws {
        let solver = Solver()
        let x = Variable("x")
        let constraint = equal(expression([(x, 1.0)]), 1.0)
        let other = equal(expression([(x, 1.0)]), 2.0)

        XCTAssertFalse(solver.hasConstraint(constraint))
        try solver.addConstraint(constraint)
        XCTAssertTrue(solver.hasConstraint(constraint))
        XCTAssertThrowsError(try solver.addConstraint(constraint)) { error in
            XCTAssertEqual(error as? SolverError, .duplicateConstraint)
        }
        XCTAssertThrowsError(try solver.removeConstraint(other)) { error in
            XCTAssertEqual(error as? SolverError, .unknownConstraint)
        }
        try solver.removeConstraint(constraint)
        XCTAssertFalse(solver.hasConstraint(constraint))
        XCTAssertEqual(solver.constraintCount, 0)
    }

    func testAddConstraintsBatch() throws {
        let solver = Solver()
        let x = Variable("x")
        let y = Variable("y")

        try solver.addConstraints([
            equal(expression([(x, 1.0)]), 1.0),
            equal(expression([(y, 1.0)]), 2.0)
        ])
        solver.updateVariables()
        assertValue(solver, x, 1.0)
        assertValue(solver, y, 2.0)
        XCTAssertEqual(solver.constraintCount, 2)
    }

    // MARK: - Strengths

    func testSolvingWithStrength() throws {
        let solver = Solver()
        let v1 = Variable("v1")
        let v2 = Variable("v2")

        // v1 + v2 == 0 (required), v1 == 10 (required), v2 >= 0 (weak).
        try solver.addConstraint(equal(expression([(v1, 1.0), (v2, 1.0)]), 0.0))
        try solver.addConstraint(equal(expression([(v1, 1.0)]), 10.0))
        try solver.addConstraint(greaterThanOrEqual(expression([(v2, 1.0)]), 0.0, strength: .weak))
        solver.updateVariables()
        assertValue(solver, v1, 10.0)
        assertValue(solver, v2, -10.0)

        // The strong preference for v2 == 2 wins over the medium v1 >= 10.
        solver.reset()
        try solver.addConstraint(equal(expression([(v1, 1.0), (v2, 1.0)]), 0.0))
        try solver.addConstraint(greaterThanOrEqual(expression([(v1, 1.0)]), 10.0, strength: .medium))
        try solver.addConstraint(equal(expression([(v2, 1.0)]), 2.0, strength: .strong))
        solver.updateVariables()
        assertValue(solver, v1, -2.0)
        assertValue(solver, v2, 2.0)
    }

    func testStrengthOrderingAndValues() {
        XCTAssertLessThan(Strength.weak, Strength.medium)
        XCTAssertLessThan(Strength.medium, Strength.strong)
        XCTAssertLessThan(Strength.strong, Strength.required)
        XCTAssertEqual(Strength.create(1.0, 0.0, 0.0), .strong)
        XCTAssertEqual(Strength.create(0.0, 1.0, 0.0), .medium)
        XCTAssertEqual(Strength.create(0.0, 0.0, 1.0), .weak)
        XCTAssertEqual(Strength.clip(-1.0), Strength.create(0.0, 0.0, 0.0))
        XCTAssertEqual(Strength.clip(1.0e12), Strength.required)
        // The raw values follow the kiwi formula.
        XCTAssertEqual(Strength.strong.value, 1_000_000.0)
        XCTAssertEqual(Strength.medium.value, 1_000.0)
        XCTAssertEqual(Strength.weak.value, 1.0)
        XCTAssertEqual(Strength.required.value, 1_001_001_000.0)
        XCTAssertGreaterThan(Strength.create(0.0, 2.0, 0.0), Strength.create(0.0, 0.0, 1000.0))
    }

    func testStrengthWeightsOrderPreferences() throws {
        let solver = Solver()
        let x = Variable("x")

        // No required constraint: the strongest preference wins.
        try solver.addConstraint(equal(expression([(x, 1.0)]), 10.0, strength: .weak))
        try solver.addConstraint(equal(expression([(x, 1.0)]), 20.0, strength: .strong))
        solver.updateVariables()
        assertValue(solver, x, 20.0)
        XCTAssertEqual(solver.constraintCount, 2)
    }

    // MARK: - Edit variables

    func testManagingEditVariables() throws {
        let solver = Solver()
        let v1 = Variable("foo")
        let v2 = Variable("bar")

        XCTAssertFalse(solver.hasEditVariable(v1))

        try solver.addEditVariable(v1, strength: .weak)
        XCTAssertTrue(solver.hasEditVariable(v1))
        // Edit constraints are internal: they do not show up as user constraints.
        XCTAssertEqual(solver.constraintCount, 0)

        XCTAssertThrowsError(try solver.addEditVariable(v1, strength: .medium)) { error in
            XCTAssertEqual(error as? SolverError, .duplicateEditVariable)
        }
        XCTAssertThrowsError(try solver.removeEditVariable(v2)) { error in
            XCTAssertEqual(error as? SolverError, .unknownEditVariable)
        }
        try solver.removeEditVariable(v1)
        XCTAssertFalse(solver.hasEditVariable(v1))

        // Required strength would make every suggested value unsatisfiable.
        XCTAssertThrowsError(try solver.addEditVariable(v1, strength: .required))
        XCTAssertFalse(solver.hasEditVariable(v1))

        try solver.addEditVariable(v2, strength: .strong)
        XCTAssertTrue(solver.hasEditVariable(v2))
        XCTAssertThrowsError(try solver.suggestValue(v1, 10.0)) { error in
            XCTAssertEqual(error as? SolverError, .unknownEditVariable)
        }

        solver.reset()
        XCTAssertFalse(solver.hasEditVariable(v2))
        XCTAssertEqual(solver.constraintCount, 0)
    }

    func testEditVariableHoldsCurrentValueUntilSuggested() throws {
        let solver = Solver()
        let value = Variable("value")

        try solver.addConstraint(equal(expression([(value, 1.0)]), 1.0, strength: .weak))
        solver.updateVariables()
        assertValue(solver, value, 1.0)

        // Adding the edit variable starts it at the variable's current value.
        try solver.addEditVariable(value, strength: .strong)
        solver.updateVariables()
        assertValue(solver, value, 1.0)

        try solver.suggestValue(value, 7.0)
        solver.updateVariables()
        assertValue(solver, value, 7.0)
    }

    func testSuggestValueAndResolve() throws {
        let solver = Solver()
        let value = Variable("value")

        try solver.addEditVariable(value, strength: .strong)
        try solver.suggestValue(value, 3.0)
        solver.resolve()
        assertValue(solver, value, 3.0)

        try solver.suggestValue(value, -4.0)
        solver.resolve()
        assertValue(solver, value, -4.0)

        // `updateVariables` alone is not enough to see a suggested value, but
        // `resolve` is.
        XCTAssertEqual(solver.value(of: value), -4.0)
    }

    func testRemoveEditVariableKeepsUserConstraints() throws {
        let solver = Solver()
        let x = Variable("x")
        let y = Variable("y")

        try solver.addConstraint(equal(expression([(x, 1.0), (y, 1.0)]), 10.0))
        try solver.addEditVariable(x, strength: .strong)
        try solver.suggestValue(x, 4.0)
        solver.updateVariables()
        assertValue(solver, x, 4.0)
        assertValue(solver, y, 6.0)

        try solver.removeEditVariable(x)
        XCTAssertFalse(solver.hasEditVariable(x))
        XCTAssertEqual(solver.constraintCount, 1)
        solver.updateVariables()
        // The system is under-constrained again, but the user constraint holds.
        XCTAssertEqual(solver.value(of: x) + solver.value(of: y), 10.0, accuracy: defaultAccuracy)
    }

    func testEditExample() throws {
        let solver = Solver()
        let left = Variable("left")
        let mid = Variable("mid")
        let right = Variable("right")

        // mid == (left + right) / 2, right == left + 10, right <= 100, left >= 0
        try solver.addConstraint(equal(expression([(mid, 1.0)]),
                                       expression([(left, 0.5), (right, 0.5)])))
        try solver.addConstraint(equal(expression([(right, 1.0)]),
                                       expression([(left, 1.0)], constant: 10.0)))
        try solver.addConstraint(lessThanOrEqual(expression([(right, 1.0)]), 100.0))
        try solver.addConstraint(greaterThanOrEqual(expression([(left, 1.0)]), 0.0))

        try solver.addEditVariable(mid, strength: .strong)
        try solver.suggestValue(mid, 2.0)
        solver.updateVariables()

        assertValue(solver, left, 0.0)
        assertValue(solver, mid, 5.0)
        assertValue(solver, right, 10.0)
    }

    func testParallelTopsExample() throws {
        let parentTop = Variable("parent.top")
        let parentHeight = Variable("parent.height")
        let childTop = Variable("child.top")
        let childHeight = Variable("child.height")

        let solver = Solver()
        // child.top == parent.top
        try solver.addConstraint(equal(expression([(childTop, 1.0)]), expression([(parentTop, 1.0)])))
        // child.bottom == parent.bottom
        try solver.addConstraint(equal(expression([(childTop, 1.0)], constant: 0.0).plus(expression([(childHeight, 1.0)])),
                                       expression([(parentTop, 1.0)]).plus(expression([(parentHeight, 1.0)]))))

        try solver.addEditVariable(childHeight, strength: .strong)
        try solver.suggestValue(childHeight, 24.0)
        solver.updateVariables()

        assertValue(solver, parentHeight, 24.0)
    }

    func testGreaterThanOrEqualWithEditVariables() throws {
        let solver = Solver()
        let v1 = Variable("v1")
        let v2 = Variable("v2")

        try solver.addConstraint(greaterThanOrEqual(expression([(v2, 1.0)]),
                                                   expression([(v1, 1.0)], constant: 10.0)))
        try solver.addEditVariable(v1, strength: .strong)
        try solver.addEditVariable(v2, strength: .medium)
        try solver.suggestValue(v2, 0.0)
        try solver.suggestValue(v1, 10.0)
        solver.updateVariables()

        assertValue(solver, v1, 10.0)
        assertValue(solver, v2, 20.0)
    }

    func testUnderConstrainedSystemWithEditVariable() throws {
        let solver = Solver()
        let variable = Variable("foo")

        // 2 * variable + 1 >= 0
        let constraint = greaterThanOrEqual(expression([(variable, 2.0)], constant: 1.0), 0.0)
        try solver.addEditVariable(variable, strength: .weak)
        try solver.addConstraint(constraint)
        try solver.suggestValue(variable, 10.0)
        solver.updateVariables()

        XCTAssertEqual(constraint.expression.constant, 1.0, accuracy: defaultAccuracy)
        XCTAssertEqual(value(of: constraint.expression, in: solver), 21.0, accuracy: defaultAccuracy)
        assertValue(solver, variable, 10.0)
    }

    func testHandlingInfeasibleConstraints() throws {
        // The edit-variable example from the Cassowary paper. Suggesting a
        // value that makes the required inequalities infeasible exercises the
        // dual optimization path.
        let xm = Variable("xm")
        let xl = Variable("xl")
        let xr = Variable("xr")
        let solver = Solver()

        try solver.addEditVariable(xm, strength: .strong)
        try solver.addEditVariable(xl, strength: .weak)
        try solver.addEditVariable(xr, strength: .weak)
        try solver.addConstraint(equal(expression([(xm, 2.0)]),
                                       expression([(xl, 1.0), (xr, 1.0)])))
        try solver.addConstraint(lessThanOrEqual(expression([(xl, 1.0)], constant: 20.0),
                                                 expression([(xr, 1.0)])))
        try solver.addConstraint(greaterThanOrEqual(expression([(xl, 1.0)]), -10.0))
        try solver.addConstraint(lessThanOrEqual(expression([(xr, 1.0)]), 100.0))

        try solver.suggestValue(xm, 40.0)
        try solver.suggestValue(xr, 50.0)
        try solver.suggestValue(xl, 30.0)
        // A normal update.
        try solver.suggestValue(xm, 60.0)
        // An infeasible condition that triggers a dual optimization.
        try solver.suggestValue(xm, 90.0)
        solver.updateVariables()

        assertValue(solver, xm, 90.0)
        assertValue(solver, xl, 80.0)
        assertValue(solver, xr, 100.0)
        XCTAssertEqual(solver.value(of: xl) + solver.value(of: xr),
                       2.0 * solver.value(of: xm), accuracy: defaultAccuracy)
    }

    func testDraggingWithMultipleEditVariables() throws {
        let solver = Solver()
        let left = Variable("left")
        let right = Variable("right")
        let width = Variable("width")

        try solver.addConstraint(equal(expression([(width, 1.0)]),
                                       expression([(left, -1.0), (right, 1.0)])))
        try solver.addConstraint(greaterThanOrEqual(expression([(width, 1.0)]), 0.0))
        try solver.addConstraint(greaterThanOrEqual(expression([(left, 1.0)]), 0.0))
        try solver.addEditVariable(left, strength: .strong)
        try solver.addEditVariable(width, strength: .strong)

        try solver.suggestValue(left, 10.0)
        try solver.suggestValue(width, 30.0)
        solver.updateVariables()
        assertValue(solver, left, 10.0)
        assertValue(solver, width, 30.0)
        assertValue(solver, right, 40.0)

        // Dragging the same edit variables repeatedly keeps the system valid.
        for step in 1...20 {
            try solver.suggestValue(width, Double(30 + step))
            solver.updateVariables()
            assertValue(solver, width, Double(30 + step), accuracy: 1.0e-3)
            XCTAssertEqual(solver.value(of: right) - solver.value(of: left),
                           solver.value(of: width), accuracy: 1.0e-3)
        }
    }

    // MARK: - fetchChanges

    func testFetchChanges() throws {
        let solver = Solver()
        let x = Variable("x")
        let unused = Variable("unused")

        // No values are visible before the first update/fetch.
        XCTAssertEqual(solver.value(of: x), 0.0)
        XCTAssertEqual(solver.constraintCount, 0)

        try solver.addConstraint(equal(expression([(x, 1.0)]), 10.0))
        let first = solver.fetchChanges()
        XCTAssertEqual(first.count, 1)
        XCTAssertTrue(first[0].0 === x)
        XCTAssertEqual(first[0].1, 10.0, accuracy: defaultAccuracy)
        assertValue(solver, x, 10.0)

        // Nothing changed: a second fetch reports an empty change set.
        XCTAssertTrue(solver.fetchChanges().isEmpty)

        // Updates with no change do not report anything either.
        solver.updateVariables()
        XCTAssertTrue(solver.fetchChanges().isEmpty)

        // Replacing the constraint changes the value, so it is reported again.
        try solver.removeConstraint(solver.constraints[0])
        try solver.addConstraint(equal(expression([(x, 1.0)]), 20.0))
        let second = solver.fetchChanges()
        XCTAssertEqual(second.count, 1)
        XCTAssertTrue(second[0].0 === x)
        XCTAssertEqual(second[0].1, 20.0, accuracy: defaultAccuracy)

        // A variable that never appeared in the tableau is never reported.
        XCTAssertFalse(second.contains { $0.0 === unused })
    }

    func testFetchChangesReportsOnlyChangedVariables() throws {
        let solver = Solver()
        let x = Variable("x")
        let y = Variable("y")

        try solver.addConstraint(equal(expression([(x, 1.0)]), 1.0))
        try solver.addConstraint(equal(expression([(y, 1.0)]), 2.0))
        let first = solver.fetchChanges()
        XCTAssertEqual(first.count, 2)
        // Reported in variable creation order.
        XCTAssertTrue(first[0].0 === x)
        XCTAssertTrue(first[1].0 === y)

        _ = solver.fetchChanges()

        // Only y moves.
        try solver.removeConstraint(solver.constraints[1])
        try solver.addConstraint(equal(expression([(y, 1.0)]), 5.0))
        let second = solver.fetchChanges()
        XCTAssertEqual(second.count, 1)
        XCTAssertTrue(second[0].0 === y)
        XCTAssertEqual(second[0].1, 5.0, accuracy: defaultAccuracy)
    }

    func testFetchChangesAfterEdit() throws {
        let solver = Solver()
        let x = Variable("x")
        try solver.addEditVariable(x, strength: .strong)
        _ = solver.fetchChanges()

        try solver.suggestValue(x, 12.0)
        let changes = solver.fetchChanges()
        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(changes.first?.0.name, "x")
        XCTAssertEqual(changes.first?.1 ?? 0.0, 12.0, accuracy: defaultAccuracy)
    }

    // MARK: - reset

    func testReset() throws {
        let solver = Solver()
        let x = Variable("x")

        try solver.addConstraint(equal(expression([(x, 1.0)]), 5.0))
        try solver.addEditVariable(x, strength: .medium)
        solver.updateVariables()
        XCTAssertGreaterThan(solver.variableCount, 0)

        solver.reset()

        XCTAssertEqual(solver.constraintCount, 0)
        XCTAssertEqual(solver.variableCount, 0)
        XCTAssertEqual(solver.constraints.count, 0)
        XCTAssertEqual(solver.value(of: x), 0.0)
        XCTAssertTrue(solver.constraints.isEmpty)
        XCTAssertFalse(solver.hasEditVariable(x))
        XCTAssertTrue(solver.fetchChanges().isEmpty)

        // A reset solver behaves exactly like a fresh one.
        try solver.addConstraint(equal(expression([(x, 1.0)]), -3.0))
        solver.updateVariables()
        assertValue(solver, x, -3.0)
    }

    // MARK: - Determinism

    func testDeterminismForIdenticalCallSequences() throws {
        func solve() throws -> [(Variable, Double)] {
            let solver = Solver()
            let a = Variable("a")
            let b = Variable("b")
            let c = Variable("c")
            try solver.addConstraint(equal(expression([(a, 1.0), (b, 1.0)]), 10.0))
            try solver.addConstraint(lessThanOrEqual(expression([(b, 1.0)]), 3.0, strength: .weak))
            try solver.addConstraint(greaterThanOrEqual(expression([(a, 1.0)]), 2.0, strength: .medium))
            try solver.addConstraint(equal(expression([(c, 1.0)]), 7.0, strength: .weak))
            try solver.addEditVariable(b, strength: .strong)
            try solver.suggestValue(b, 4.0)
            solver.updateVariables()
            return [a, b, c].map { ($0, solver.value(of: $0)) }
        }

        let first = try solve()
        let second = try solve()
        XCTAssertEqual(first.count, second.count)
        for (lhs, rhs) in zip(first, second) {
            XCTAssertEqual(lhs.0.name, rhs.0.name)
            XCTAssertEqual(lhs.1, rhs.1)
        }
    }

    func testSolutionIsStableAcrossRepeatedSolves() throws {
        let solver = Solver()
        let x = Variable("x")
        let y = Variable("y")

        try solver.addConstraint(equal(expression([(x, 1.0), (y, 1.0)]), 100.0))
        try solver.addEditVariable(x, strength: .strong)

        var seen = Set<Double>()
        for step in 0..<10 {
            let suggested = Double(50 + step)
            try solver.suggestValue(x, suggested)
            solver.updateVariables()
            XCTAssertEqual(solver.value(of: x), suggested, accuracy: 1.0e-6)
            XCTAssertEqual(solver.value(of: x) + solver.value(of: y), 100.0, accuracy: 1.0e-6)
            seen.insert(solver.value(of: x))
        }
        XCTAssertEqual(seen.count, 10)
    }

    // MARK: - Parabola (classic second-difference encoding)

    func testParabola() throws {
        // y(i) = 0.5 * i^2 can be encoded exactly with linear constraints: the
        // second difference of a quadratic is constant. This is the classic
        // "parabola" shape used by the original Cassowary tests, expressed in
        // terms a linear solver can handle.
        let solver = Solver()
        let count = 9
        let coefficient = 0.5
        let points = (0..<count).map { Variable("y\($0)") }

        try solver.addConstraint(equal(expression([(points[0], 1.0)]), 0.0))
        try solver.addConstraint(equal(expression([(points[1], 1.0)]), coefficient))
        for index in 1..<(count - 1) {
            // y[i+1] - 2 * y[i] + y[i-1] == 2 * coefficient
            let expression = expression([(points[index + 1], 1.0),
                                         (points[index], -2.0),
                                         (points[index - 1], 1.0)])
            try solver.addConstraint(equal(expression, 2.0 * coefficient))
        }
        solver.updateVariables()

        for index in 0..<count {
            assertValue(solver, points[index], coefficient * Double(index * index), accuracy: 1.0e-5)
        }
    }

    // MARK: - API surface

    func testExpressionArithmetic() {
        let x = Variable("x")
        let y = Variable("y")

        let xExpression = Expression(x, 2.0)
        XCTAssertFalse(xExpression.isConstant)
        XCTAssertEqual(xExpression.constant, 0.0)
        XCTAssertEqual(xExpression.terms.count, 1)
        XCTAssertEqual(xExpression.coefficient(of: x), 2.0)

        let constant = Expression(constant: 3.0)
        XCTAssertTrue(constant.isConstant)
        XCTAssertEqual(constant.constant, 3.0)
        XCTAssertTrue(constant.terms.isEmpty)

        // Merging of terms with the same variable.
        let sum = xExpression.plus(Expression(x, 3.0)).plus(Expression(y, 1.0)).plus(Expression(constant: 4.0))
        XCTAssertEqual(sum.coefficient(of: x), 5.0)
        XCTAssertEqual(sum.coefficient(of: y), 1.0)
        XCTAssertEqual(sum.constant, 4.0)
        XCTAssertEqual(sum.terms.count, 2)

        // Subtraction, scaling, division and negation.
        let difference = xExpression.minus(Expression(y, 1.0))
        XCTAssertEqual(difference.coefficient(of: x), 2.0)
        XCTAssertEqual(difference.coefficient(of: y), -1.0)

        let scaled = xExpression.times(3.0)
        XCTAssertEqual(scaled.coefficient(of: x), 6.0)
        XCTAssertEqual(xExpression.coefficient(of: x), 2.0, "times must not mutate the receiver")

        let divided = xExpression.divide(by: 2.0)
        XCTAssertEqual(divided.coefficient(of: x), 1.0)

        let negated = -xExpression
        XCTAssertEqual(negated.coefficient(of: x), -2.0)

        // A term vanishes when its coefficient becomes zero.
        let cancelled = xExpression.minus(Expression(x, 2.0))
        XCTAssertEqual(cancelled.terms.count, 0)
        XCTAssertTrue(cancelled.isConstant)
    }

    func testTermAndVariableBasics() {
        let first = Variable("same")
        let second = Variable("same")
        let third = first

        XCTAssertFalse(first == second)
        XCTAssertTrue(first === third)
        XCTAssertEqual(first, third)
        XCTAssertEqual(first.hashValue, third.hashValue)
        XCTAssertEqual(first.description, "same")
        XCTAssertNotEqual(Variable().description, "")

        let term = Term(first, 2.5)
        XCTAssertTrue(term.variable === first)
        XCTAssertEqual(term.coefficient, 2.5)
        XCTAssertEqual(Term(first).coefficient, 1.0)
    }

    func testConstraintCopyingAndFlags() {
        let x = Variable("x")
        let expression = Expression(x, 1.0)
        let required = Constraint(expression, .equal)
        XCTAssertTrue(required.isRequired)
        XCTAssertFalse(required.isInequality)
        XCTAssertEqual(required.strength, .required)
        XCTAssertEqual(required.op, .equal)

        let weak = required.or(.weak)
        XCTAssertFalse(weak.isRequired)
        XCTAssertEqual(weak.strength, .weak)
        XCTAssertTrue(weak.expression === required.expression)

        let optional = required.or(.greaterThanOrEqual, .strong)
        XCTAssertEqual(optional.op, .greaterThanOrEqual)
        XCTAssertEqual(optional.strength, .strong)
        XCTAssertTrue(optional.isInequality)

        let named = Constraint(expression, .lessThanOrEqual, strength: .medium, name: "width")
        XCTAssertEqual(named.name, "width")
        XCTAssertTrue(named.isInequality)
        XCTAssertTrue(named.description.contains("width"))
    }

    func testRelationalOperators() {
        XCTAssertEqual(RelationalOperator.lessThanOrEqual.rawValue, "<=")
        XCTAssertEqual(RelationalOperator.equal.rawValue, "==")
        XCTAssertEqual(RelationalOperator.greaterThanOrEqual.rawValue, ">=")
        XCTAssertEqual(RelationalOperator.allCases.count, 3)
    }

    func testSolverErrorDescriptions() {
        XCTAssertEqual(SolverError.duplicateConstraint.description, "duplicate constraint")
        XCTAssertEqual(SolverError.unknownConstraint.description, "unknown constraint")
        XCTAssertEqual(SolverError.duplicateEditVariable.description, "duplicate edit variable")
        XCTAssertEqual(SolverError.unknownEditVariable.description, "unknown edit variable")
        XCTAssertEqual(SolverError.unsatisfiableConstraint.description, "unsatisfiable constraint")
        XCTAssertEqual(SolverError.internalInconsistency("boom").description, "internal inconsistency: boom")
        XCTAssertEqual(SolverError.unknownConstraint, SolverError.unknownConstraint)
        XCTAssertNotEqual(SolverError.unknownConstraint, SolverError.duplicateConstraint)
    }

    func testVariablesAreReportedByValueOf() throws {
        let solver = Solver()
        let neverUsed = Variable("neverUsed")

        // Unknown variables report 0, and an empty solver owns no symbols.
        XCTAssertEqual(solver.value(of: neverUsed), 0.0)
        XCTAssertEqual(solver.variableCount, 0)

        try solver.addConstraint(equal(expression([(Variable("x"), 1.0)]), 1.0))
        // External variables and the internal slack/dummy symbols are counted.
        XCTAssertGreaterThanOrEqual(solver.variableCount, 2)
    }
}
