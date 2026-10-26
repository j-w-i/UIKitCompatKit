Vendored from https://github.com/steipete/PSTCollectionView (MIT, see LICENSE).

Local change: one receiver cast in PSTCollectionView.m
(`[(PSTCollectionViewData *)_update[@"oldModel"] numberOfItemsInSection:]`)
so the file compiles against a modern SDK, where the selector is ambiguous.

Used only for iOS 5 builds; the Swift name layer in UIKitCompatKit is
availability-gated so builds targeting iOS 6+ use UIKit's collection view.
