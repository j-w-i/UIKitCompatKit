# Status: vendored, not wired

These sources are kept for the iOS 5 collection-view work but are **not** part of
any package target, so they do not affect normal builds.

Why not wired yet: making `UICollectionView` mean PST on iOS 5 and UIKit on
iOS 6+ without changing app source needs either
  * compile-time type substitution in the compiler (map UIKit's imported
    `UICollectionView*` declarations onto these classes for iOS 5 builds), or
  * per-target selection (iOS 5 build uses PST, iOS 6+ build uses UIKit).

The shortcuts that were tried and rejected:
  * Swift `typealias UICollectionView = PSTCollectionView` — ambiguous with
    UIKit at a 5.0 deployment target, and `obsoleted: 6.0` does not stop the
    ambiguity.
  * hiding UIKit's declarations — breaks dependencies (DifferenceKit,
    DiffableDataSources) that extend `UICollectionView`.
  * runtime-resolved classes (`ForeignKind::RuntimeOnly`) — the compiler refuses
    `class MyCell: UICollectionViewCell` ("only visible via the Objective-C
    runtime"), so cell subclassing is impossible.

PST itself is fine: every file compiles for armv7-apple-ios5.0 (one receiver
cast patched for modern SDKs), and at runtime it registers classes named
`UICollectionView`, `UICollectionViewCell`, ... below iOS 6 and re-parents its
classes onto UIKit on iOS 6+.

## Update: import-visibility problem

Renaming UIKit's declarations for iOS 5 and giving the PST classes UIKit Swift
names works, but only for modules that import the PST module. A dependency that
writes `extension UICollectionView` while importing just UIKit fails:

    DifferenceKit/Sources/Extensions/UIKitExtension.swift:128:18:
      error: cannot find type 'UICollectionView' in scope

Swift has no implicit/global import flag (`-module-alias` renames modules, not
types), so this cannot be solved inside the package. The viable design is to ship
PST as a *clang module in the toolchain* and have the importer substitute it for
UIKit's declarations, so every module sees it without an import.
