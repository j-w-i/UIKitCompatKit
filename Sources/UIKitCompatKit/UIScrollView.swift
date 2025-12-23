#if !targetEnvironment(macCatalyst)
#if compiler(<6.0)
#if !MODERN_BUILD
import UIKit

extension UIScrollView {
    private struct Keys {
        static var contentGuide = "contentLayoutGuideShim"
        static var frameGuide = "frameLayoutGuideShim"
    }

    @available(iOS, introduced: 6.0, deprecated: 11.0)
    @_disfavoredOverload
    public var contentLayoutGuide: UILayoutGuideShim {
        if let guide = objc_getAssociatedObject(self, &Keys.contentGuide) as? UILayoutGuideShim {
            return guide
        }
        let guide = UILayoutGuideShim()
        self.addLayoutGuide(guide)
        objc_setAssociatedObject(self, &Keys.contentGuide, guide, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return guide
    }
    
    @available(iOS, introduced: 6.0, deprecated: 11.0)
    @_disfavoredOverload
    public var frameLayoutGuide: UILayoutGuideShim {
        if let guide = objc_getAssociatedObject(self, &Keys.frameGuide) as? UILayoutGuideShim {
            return guide
        }
        let guide = UILayoutGuideShim()
        self.addLayoutGuide(guide)
        objc_setAssociatedObject(self, &Keys.frameGuide, guide, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return guide
    }
}

#endif
#endif
#endif


import UIKit

private var RefreshControlKey: UInt8 = 0

extension UIScrollView {

    @available(iOS, introduced: 6.0, deprecated: 10.0)
    @_disfavoredOverload
    public var refreshControl: UIRefreshControl? {
        get {
            return objc_getAssociatedObject(self, &RefreshControlKey) as? UIRefreshControl
        }
        set {
            let old = refreshControl
            old?.removeFromSuperview()

            objc_setAssociatedObject(
                self,
                &RefreshControlKey,
                newValue,
                .OBJC_ASSOCIATION_RETAIN_NONATOMIC
            )

            guard let control = newValue else { return }

            if let tableView = self as? UITableView {
                tableView.backgroundView?.addSubview(control)
                tableView.backgroundView = UIView()
                tableView.addSubview(control)
            } else if let collectionView = self as? UICollectionView {
                collectionView.addSubview(control)
            } else {
                addSubview(control)
            }
        }
    }
}
