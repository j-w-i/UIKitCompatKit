# UIKitCompatKit

Backports of newer UIKit APIs for apps that still support older deployment targets, with the
modern API surface and (where it matters) the modern behaviour.

## Legacy Auto Layout (Cassowary)

This package includes a Swift port of [RRAutoLayout](https://github.com/RolandasRazma/RRAutoLayout) —
Rolandas Razma's backport of iOS 6's constraint-based Auto Layout to iOS 5 — rebuilt around a real
[Cassowary](https://constraints.cs.washington.edu/cassowary/) constraint solver.

### Why a Cassowary solver?

UIKit's Auto Layout engine is a Cassowary implementation: it solves a system of linear equalities and
inequalities, with priorities expressed as symbolic strengths. RRAutoLayout reimplemented the plumbing
around Auto Layout (constraint storage, Interface Builder loading, the `layoutSubviews` pass) but its
constraint application was hand-written rectangle arithmetic that only handled a handful of
relationships, so layouts did not match UIKit.

This port keeps RRAutoLayout's model and call flow, but replaces the rectangle arithmetic with a
faithful incremental Cassowary v2 solver (`Sources/Cassowary`):

* required and optional constraints (priorities map onto Cassowary strengths),
* equalities and inequalities,
* multipliers and constants with Apple's attribute semantics,
* `translatesAutoresizingMaskIntoConstraints` mask translation,
* intrinsic content size, content hugging and compression resistance,
* the same layout-pass ordering (`setNeedsUpdateConstraints` → `updateConstraints` → solve → apply).

The test suite contains a UIKit-parity suite that runs the same constraints through system Auto Layout
and through this engine and compares the resulting frames. See
[`docs/legacy-autolayout.md`](docs/legacy-autolayout.md) for the full design and interface contract.

### When is it used?

**Only when the target has no system Auto Layout, i.e. iOS < 6.** On iOS 6 and later the system
constraint-based layout is authoritative and this backport is inert:

* `LegacyAutoLayout.isRequired` is `true` only when `#available(iOS 6.0, *)` is `false`.
* `LegacyAutoLayout.installIfNeeded()` installs the UIKit bridge (constraint storage, nib decoding,
  layout-hook swizzling) **only** in that case. On iOS 6+ it is a strict no-op and returns `false`;
  it never swizzles UIKit, never writes to `-[UIView constraints]`.
* The engine itself can be invoked explicitly on any OS via `legacyLayoutIfNeeded()`. That is the
  documented opt-in path used by tests and by the library's older shims; it does not change how the
  rest of the app lays out.

The legacy bridge installs lazily when the iOS 5 compatibility path first activates a
constraint. `LegacyAutoLayout.installIfNeeded()` is also available for explicit startup;
it is always a no-op on iOS 6+.

### Compiling for iOS 5 and newer

Use `CompatLayout` rather than shadowing UIKit names. Availability annotations do not
reliably select between same-named imported types in Swift 5.10, and compile-time
aliases cannot switch backend when an iOS 5 binary runs on iOS 6.

```swift
import UIKitCompatKit
let child = UIView()
container.addSubview(child)
CompatLayout.setTranslatesAutoresizingMaskIntoConstraints(false, on: child)
CompatLayout.activate([
    CompatLayout.anchor(child, .leading).constraint(equalTo: CompatLayout.anchor(container, .leading), constant: 16),
    CompatLayout.anchor(child, .width).constraint(equalToConstant: 120)
])
```

The same compiled code uses Cassowary on **iOS 5 only**, native constraints on iOS 6–7,
and native `isActive` on iOS 8+. No UIKit declarations are shadowed, and the installer
has no force-install bypass on iOS 6+. Keep handles to change constants or deactivate.
The facade currently covers equal anchor/constant constraints; VFL, safe areas and NIB
class impersonation are not included. See [the implementation notes](docs/legacy-autolayout.md#61-runtime-routed-compatibility-api).

### Fidelity notes

* Constraints are translated into Cassowary equations by expanding `NSLayoutAttribute` values
  algebraically (`centerX ≡ minX + width/2`, and so on), exactly like UIKit. Illegal attribute
  pairings that UIKit rejects at creation (size↔location, location equal to a constant, …) raise
  `NSInvalidArgumentException` from `RRLayoutConstraint.init` too, and are exposed through the
  non-throwing `RRLayoutConstraint.validationError(...)`.
* Priorities map to symbolic strengths (`priority → create(priority/1000, 0, 0)`; 1000 is required).
  Unsatisfiable required constraints are kept at an internal just-below-required strength, matching
  Apple's documented treatment of broken constraints.
* `translatesAutoresizingMaskIntoConstraints` generates the real
  `NSAutoresizingMaskLayoutConstraint` equations (fixed edges, flexible margins, proportional
  two-margin layout), not a naive frame pin.
* `leading`/`trailing` follow the layout direction (`left`/`right`/`centerX` are absolute). RTL swaps
  the edges, negates the constant and reverses inequalities for directional attributes — verified
  against UIKit's simulator behaviour for pure and mixed pairings.
* Baselines: iOS 6 has only `.baseline` (`lastBaseline`). Views without a baseline provider do not
  get invented equations; constraints referring to their baseline are recorded as broken.

### Usage

`UIKitCompatKit` re-exports `LegacyAutoLayout`, so a single import is enough:

```swift
import UIKitCompatKit

// Optional: the bridge also installs lazily on the first constraint mutation.
// On iOS < 6 this installs the bridge; on iOS 6+ it is a no-op.
LegacyAutoLayout.installIfNeeded()

let container = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
let child = UIView(frame: .zero)
container.addSubview(child)
child.legacyTranslatesAutoresizingMaskIntoConstraints = false

container.legacyAddConstraints([
    RRLayoutConstraint(item: child, attribute: .leading, relatedBy: .equal,
                       toItem: container, attribute: .leading,
                       multiplier: 1, constant: 16),
    RRLayoutConstraint(item: child, attribute: .trailing, relatedBy: .equal,
                       toItem: container, attribute: .trailing,
                       multiplier: 1, constant: -16),
    RRLayoutConstraint(item: child, attribute: .height, relatedBy: .equal,
                       toItem: nil, attribute: .notAnAttribute,
                       multiplier: 1, constant: 44),
    RRLayoutConstraint(item: child, attribute: .top, relatedBy: .equal,
                       toItem: container, attribute: .top,
                       multiplier: 1, constant: 24),
])
container.legacyLayoutIfNeeded()
```

Standalone modules are also available:

```swift
import Cassowary        // pure-Swift incremental solver
import LegacyAutoLayout // RRAutoLayout port + UIKit bridge
```

### Modules

| Module | Contents |
| --- | --- |
| `Cassowary` | Incremental Cassowary v2 solver: variables, expressions, constraints, symbolic strengths, edit variables. No UIKit dependency. |
| `LegacyAutoLayout` | `RRLayoutConstraint` (an `NSLayoutConstraint`-shaped model), `LegacyLayoutEngine` (constraint graph → Cassowary → frames), and the iOS < 6 UIKit bridge/gate. |
| `UIKitCompatKit` | The umbrella library; re-exports `LegacyAutoLayout` alongside the other UIKit backports. |

### Verification

The package is iOS-only (`UIKit`), so build and test with `xcodebuild`:

```bash
xcodebuild -scheme UIKitCompatKit -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/dd-legacy build

xcodebuild test -scheme UIKitCompatKit -destination 'platform=iOS Simulator,name=iPhone 17' \
  -derivedDataPath /tmp/dd-legacy
```

The suite contains (**140 tests**, all green on the iOS simulator):

* 48 tests ported from the reference Cassowary/kiwi solver suite (`CassowarySolverTests`),
* 54 engine/model tests (`LegacyLayoutEngineTests`, `RRLayoutConstraintTests`) covering geometry,
  priorities, hugging/compression, autoresizing masks and resizes, RTL, broken constraints and
  malformed input,
* 22 UIKit bridge and gating tests (`LegacyAutoLayoutIntegrationTests`) proving the bridge is inert
  on iOS 6+ and works end-to-end below it,
* 15 UIKit-vs-legacy parity methods (`AutoLayoutParityTests`) over 31 fully-determined fixtures plus
  60 seeded randomized layouts, comparing frames (0.5 pt) against system Auto Layout — including
  nested views, RTL equalities/inequalities, autoresizing-mask resizes and priority conflicts.

### Limitations

* An iOS 5 Swift binary requires a back-deployed Swift runtime (this package provides the layout
  engine and compatibility facade, not the Swift runtime). One thing Swift still cannot do on
  iOS 5 is impersonate the Objective-C class name `NSLayoutConstraint` for nib/storyboard
  unarchiving: nib-driven constraints need the original RRAutoLayout-style Objective-C trampoline
  (`objc_registerClassPair`). Pure Swift nib archives are decoded through this module's own decoder
  (`UIViewAutolayoutConstraints` + `NS*`/`NS*V2` keys) instead.
* Layout guides (`UILayoutGuide`), stack-view distribution internals and margins are not part of the
  legacy solver; build those on top of the constraint model.
* Intrinsic content size is modelled with the two documented inequalities (`width <= intrinsic` at the
  hugging priority and `width >= intrinsic` at the compression-resistance priority), not UIKit's
  private edit-variable representation. The documented behaviour matches; exotic priority games
  between 750 and 1000 may differ.
* Ambiguous layouts can have multiple valid solutions. Like UIKit, the engine picks one; the engine
  additionally keeps the incumbent geometry via weak stay constraints, so repeated layout passes are
  stable (UIKit's choice in ambiguous cases is explicitly unspecified). The parity suite only asserts
  on fully-determined systems.
* The engine solves the subtree passed to it, whereas UIKit solves once per window. Constraints must be
  installed on the closest common ancestor (as UIKit requires); with that rule the results are
  identical. Stays keep frames stable if an intermediate view's pass sees a partial constraint set.
* Layout direction is process-wide, as it was on iOS 6 (there is no per-view semantic-content API
  before iOS 9).

## Third-party notices

* RRAutoLayout — Copyright (c) 2012 Rolandas Razma — MIT License. Model, nib keys and layout call flow
  are ported from it (see `Sources/LegacyAutoLayout`).
* Cassowary — Copyright (c) 1998–2000 Greg J. Badros, Alan Borning and others — BSD-style license.
  `Sources/Cassowary` implements the published incremental Cassowary algorithm.
* kiwi — Copyright (c) 2013–2026 Nucleic Development Team — Modified BSD License. The solver API and
  the ported reference tests are modelled on kiwi.
