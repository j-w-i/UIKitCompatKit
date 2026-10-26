// iOS 5 collection view, under UIKit's spelling.
//
// PSTCollectionView's declarations are imported with the UIKit names (swift_name),
// and the compiler imports UIKit's own collection declarations under private names
// for legacy iOS 5 compilations, so these are unambiguous:
//
//   deployment target < 6  -> PSTCollectionView, which registers classes named
//                             UICollectionView/... at load time on iOS 5
//   deployment target >= 6 -> no renaming happens and UIKit's types are used
@_exported import PSTCollectionView
