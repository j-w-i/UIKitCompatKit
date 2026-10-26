//
//  RRLayoutPriority.swift
//  LegacyAutoLayout
//
//  Swift port of RRAutoLayout's `RRLayoutPriority` constant block, extended with
//  the mapping onto Cassowary symbolic strengths used by the legacy solver.
//
//  RRAutoLayout
//  Copyright (c) 2012 Rolandas Razma <rolandas@razma.lt>
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in
//  all copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
//  SOFTWARE.
//
//  ---------------------------------------------------------------------------
//  Priority -> Cassowary strength
//  ---------------------------------------------------------------------------
//
//  `NSLayoutPriority` is a float in the closed range 0...1000 where 1000 means
//  "required" (must be satisfied) and everything below it is an optional
//  preference. RRAutoLayout only ever compared priorities numerically; the real
//  Auto Layout engine must translate them into a weighted objective that the
//  Cassowary simplex can optimise. The translation used here follows Apple's
//  documented ordering guarantee together with the Cassowary/kiwi strength
//  representation:
//
//    * required (priority >= 1000)  -> `Strength.required`
//      Cassowary treats required rows with the two-phase artificial-variable
//      path, so they are satisfied or reported unsatisfiable -- never traded off.
//
//    * 0 < priority < 1000          -> `Strength.create(priority / 1000, 0, 0)`
//      kiwi's `Strength.create(a, b, c, weight)` computes
//          clamp(a * weight) * 1_000_000 + clamp(b * weight) * 1_000 + clamp(c * weight)
//      with `clamp(x) = min(1000, max(0, x))` (see `Sources/Cassowary/Strength.swift`;
//      the same formula is in the reference implementation `kiwi` by the Nucleic
//      Development Team, Modified BSD). Using the first symbolic level only maps
//      priority p to a raw weight of p * 1000 (since a = p / 1000 is in (0, 1),
//      so a * 1_000_000 = p * 1000). The mapping is therefore:
//          * strictly monotonic in p (higher UIKit priority always wins);
//          * spaced 1000 apart for adjacent integer priorities, i.e. each priority
//            step dominates any amount of lower-level violation -- exactly the
//            lexicographic ordering UIKit's priority ladder describes;
//          * strictly below `.required` for every p < 1000.
//      Auto Layout does not document a numeric weight, only the ordering; a
//      linear weight is the natural choice and preserves it. (Apple engineers are
//      on record, e.g. in the WWDC "Auto Layout" sessions and the `NSLayoutPriority`
//      documentation, that priorities express "how strongly" a constraint may be
//      violated and that 1000 is reserved for required constraints.)
//
//    * priority <= 0                -> `Strength.create(0, 0, 1)` (i.e. `.weak`)
//      A "0 priority" constraint means "do not enforce, but use to resolve
//      ambiguity". It must never become a zero-strength row (kiwi requires a
//      non-zero objective weight for optional constraints); the weakest symbolic
//      level (raw value 1) is the smallest legal strength and is exactly what
//      `NSLayoutPriority` 0 is used for. Non-finite priorities are treated the
//      same way so a corrupt archive can never produce an invalid system.
//
//  Cross-reference: /tmp/autolayout-semantics.md §1.4 recommends the equivalent
//  `Strength.create(priority, 0, 0)` (raw weight p * 10^6). Scaling every optional
//  weight by the same positive constant (1000 here) leaves the Cassowary optimum
//  unchanged -- only the ordering and the objective's relative weights matter --
//  so this file keeps the p/1000 form specified by the module contract while
//  matching the spec's lexicographic behaviour exactly:
//
//      0 < p_1 < p_2 < 1000  =>  create(p_1/1000) < create(p_2/1000) < required.
//
//  The "broken constraint" level used when a required constraint cannot be
//  satisfied is documented in `LegacyLayoutSolver.brokenStrength`
//  (`Strength.clip(required.value - 1)`), which is exactly §1.4's `REQUIRED - 1`.
//  Modern UIKit also rejects priorities <= 0 at creation; this backport maps them
//  to `.weak` defensively instead of trapping (see `RRLayoutConstraint.priority`).
//

import Foundation
import Cassowary

/// The priority of a layout constraint.
///
/// `NSLayoutPriority` / `UILayoutPriority` are a `Float` typealias; using the same
/// underlying type keeps the API source-compatible with code written against
/// UIKit and lets archived `NSPriority` values round-trip.
public typealias RRLayoutPriority = Float

/// Well-known priority constants, named as in `UILayoutPriority`.
public enum RRLayoutPriorityValue {

    /// A required constraint. Do not exceed this value.
    public static let required: RRLayoutPriority = 1000

    /// The priority level with which a button resists compressing its content.
    public static let defaultHigh: RRLayoutPriority = 750

    /// The priority level at which a button hugs its contents horizontally.
    public static let defaultLow: RRLayoutPriority = 250

    /// The priority level with which a view wants to conform to the target size
    /// in a `systemLayoutSizeFittingSize:` computation. It is generally not
    /// appropriate to make a constraint at exactly this priority.
    public static let fittingSizeLevel: RRLayoutPriority = 50
}

/// Internal translation from UIKit priorities to Cassowary strengths.
///
/// Kept internal: `LegacyLayoutResult` and behaviour are the public contract, the
/// numeric objective weights are an implementation detail. Unit-tested through
/// `@testable import LegacyAutoLayout`.
internal enum RRLayoutPriorityMapping {

    /// The Cassowary strength for a UIKit layout priority.
    internal static func strength(for priority: RRLayoutPriority) -> Strength {
        // A non-finite priority is corrupt input: treat it like priority 0
        // ("do not enforce") instead of letting it poison the solver.
        guard priority.isFinite else {
            return Strength.create(0, 0, 1)
        }
        if priority >= RRLayoutPriorityValue.required {
            return .required
        }
        if priority > 0 {
            return Strength.create(Double(priority) / 1000.0, 0, 0)
        }
        return Strength.create(0, 0, 1)
    }
}
