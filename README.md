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

You don't have to call `installIfNeeded()` yourself. Swift has no `+load` hook, so the bridge installs
lazily on the first legacy constraint mutation (`NSLayoutConstraint.activate(...)`, `isActive = true`,
`addConstraint(...)`, `setNeedsUpdateConstraints`, or any `legacy*` call). Calling
`LegacyAutoLayout.installIfNeeded()` early (e.g. in the app delegate) is still supported and makes
startup deterministic; it is a no-op on iOS 6+.

Compile-time note: Swift has no `__IPHONE_OS_VERSION_MAX_ALLOWED` conditional compilation, so the
gate that decides *whether the engine runs* is a **runtime availability check**. Separately, whether
*source-level names* such as `NSLayoutConstraint` resolve to this backport is decided by Swift's
availability-gated name lookup against your **deployment target** (see the next section).

### Compiling for iOS 5: the same `NSLayoutConstraint` API

`LegacyAutoLayout` exports availability-shadowed names so that, **when the deployment target is below
iOS 6**, unmodified UIKit constraint source resolves to the Cassowary backport — and the exact same
source compiled for iOS 6+ resolves to UIKit:

```swift
import UIKitCompatKit

LegacyAutoLayout.installIfNeeded()   // optional; installs lazily on first activation anyway (no-op on iOS 6+)

let child = UIView()
container.addSubview(child)
child.translatesAutoresizingMaskIntoConstraints = false

NSLayoutConstraint.activate([
    NSLayoutConstraint(item: child, attribute: .leading, relatedBy: .equal,
                       toItem: container, attribute: .leading,
                       multiplier: 1, constant: 16),
    child.widthAnchor.constraint(equalToConstant: 120),
])
```

At deployment target < 6, `NSLayoutConstraint`, `NSLayoutConstraint.Attribute/.Relation/.Axis`,
`NSLayoutConstraint.activate/deactivate`, `isActive`, `.defaultHigh`-style priorities,
`UIView.translatesAutoresizingMaskIntoConstraints`, `constraints`, `addConstraint(s)`,
`removeConstraint(s)`, `updateConstraints…`, `intrinsicContentSize`, content hugging/compression
priorities and the anchor properties all resolve to the legacy implementation (backed by the
Cassowary engine). At deployment target ≥ 6 they are obsoleted by availability and UIKit's own
declarations are used. Both package manifests declare iOS 5.0 as the package platform, so an iOS 5
app (with a Swift runtime that supports it) can depend on the package.

The `Anchor` class and `isActive`/`activate`/`deactivate` code is the *existing* UIKitCompatKit
backport, not a reimplementation. It keeps its legacy-build gating (`compiler(<6.0)` &&
`!MODERN_BUILD`, which is the iOS 5 build configuration) and its availability spans `iOS 5.0...<9.0`,
so at deployment target < 6 it drives `RRLayoutConstraint` (Cassowary) and at iOS 6–8 it drives
UIKit's `NSLayoutConstraint`. Frontend code is unchanged in both cases.

Requirements and limits:

* The shadow only wins if the **deployment target is actually < iOS 6** — Swift filters by deployment
  target, not runtime OS. A build that keeps deployment target ≥ 6 while running on iOS 5 cannot use
  the automatic name switch; use `RRLayoutConstraint`/`legacy*` explicitly or shadow the names in the
  app module for an iOS-5-only build configuration (see docs/legacy-autolayout.md §6.1).
* Activated constraints (`NSLayoutConstraint.activate`, `isActive = true`) are solved from the legacy
  active-constraint registry; they do not appear in a view's `constraints` array (use `addConstraint`
  if you need ownership semantics).
* No explicit install call is required: the bridge installs itself lazily from the first constraint
  activation / `addConstraint` (the iOS 5 name shims force-install for builds compiled with a
  deployment target below iOS 6, even if they then run on a newer OS; Swift has no `+load`). Calling
  `installIfNeeded()` explicitly at startup remains supported and deterministic.
* Methods declared in extensions cannot be overridden: iOS 5 subclasses cannot
  `override func updateConstraints()` / `override var intrinsicContentSize` — use
  `legacyIntrinsicContentSize` or the legacy update hooks instead.
* Visual Format Language, `UILayoutGuide`, margins, safe-area/first-baseline anchors and
  nib/storyboard constraint class registration (needs an Objective-C trampoline) are not part of the
  iOS 5 name layer.

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
  engine and the source-level name drop-in, not the runtime). One thing Swift still cannot do on
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
