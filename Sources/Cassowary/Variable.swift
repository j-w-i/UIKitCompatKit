//
//  Variable.swift
//  Cassowary
//
//  A decision variable in a Cassowary constraint system.
//
//  The Cassowary algorithm was created by Greg Badros and Alan Borning at the
//  University of Washington (https://constraints.cs.washington.edu/cassowary/).
//  The public API of this module is modelled on the reference `kiwi` solver
//  (https://github.com/nucleic/kiwi, Copyright (c) 2013-2026, Nucleic Development
//  Team, Modified BSD License) so that layout code can be ported faithfully.
//

import Foundation

/// A variable in a Cassowary constraint system.
///
/// Variables are reference types with identity semantics: two variables created
/// with the same name are distinct variables. Names are for debugging only.
public final class Variable: Hashable, CustomStringConvertible {

    private static let counter = Counter()

    /// A unique identifier, used for deterministic ordering and hashing.
    internal let id: Int

    /// The debug name of the variable. Empty by default.
    public let name: String

    public init(_ name: String = "") {
        self.id = Variable.counter.next()
        self.name = name
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    public static func == (lhs: Variable, rhs: Variable) -> Bool {
        lhs === rhs
    }

    public var description: String {
        name.isEmpty ? "v\(id)" : name
    }
}

/// Small lock-protected counter so variable creation is safe from multiple queues.
private final class Counter {

    private let lock = NSLock()
    private var value = 0

    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        let current = value
        value += 1
        return current
    }
}
