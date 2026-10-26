#if !targetEnvironment(macCatalyst)
#if compiler(<6.0)
#if !MODERN_BUILD
import UIKit
import ObjectiveC

// MARK: - UIView layoutMargins backport
private var layoutMarginsKey: UInt8 = 0
@available(iOS, introduced: 6.0, obsoleted: 9.0)
public extension UIView {
    var layoutMargins: UIEdgeInsets {
        get {
            (objc_getAssociatedObject(self, &layoutMarginsKey) as? NSValue)?.uiEdgeInsetsValue
            ?? UIEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        }
        set {
            objc_setAssociatedObject(self, &layoutMarginsKey, NSValue(uiEdgeInsets: newValue), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
    }
}

// MARK: - UILayoutGuideShim (proxy-based)
@MainActor
@available(iOS, introduced: 6.0, deprecated: 9.0)
public class UILayoutGuideShim {
    fileprivate weak var owningView: UIView?
    fileprivate let proxyView: UIView

    public init() {
        proxyView = UIView()
        proxyView.translatesAutoresizingMaskIntoConstraints = false
        proxyView.isHidden = true
    }

    fileprivate func attach(to view: UIView) {
        owningView = view
        proxyView.frame = view.bounds
        view.addSubview(proxyView)
    }

    // MARK: - Anchors forwarding to proxyView
    public var topAnchor: Anchor { Anchor(view: proxyView, attribute: .top) }
    public var bottomAnchor: Anchor { Anchor(view: proxyView, attribute: .bottom) }
    public var leadingAnchor: Anchor { Anchor(view: proxyView, attribute: .leading) }
    public var trailingAnchor: Anchor { Anchor(view: proxyView, attribute: .trailing) }
    public var leftAnchor: Anchor { Anchor(view: proxyView, attribute: .left) }
    public var rightAnchor: Anchor { Anchor(view: proxyView, attribute: .right) }
    public var widthAnchor: Anchor { Anchor(view: proxyView, attribute: .width) }
    public var heightAnchor: Anchor { Anchor(view: proxyView, attribute: .height) }
    public var centerXAnchor: Anchor { Anchor(view: proxyView, attribute: .centerX) }
    public var centerYAnchor: Anchor { Anchor(view: proxyView, attribute: .centerY) }

    // MARK: - layoutFrame returns actual frame
    public var layoutFrame: CGRect {
        guard let view = owningView else { return .zero }
        view.layoutIfNeeded()
        return proxyView.frame
    }
}

@available(iOS, introduced: 6.0, obsoleted: 9.0)
public typealias UILayoutGuide = UILayoutGuideShim

// MARK: - UIView layout guides storage
private var layoutGuidesKey: UInt8 = 0
private var layoutMarginsGuideKey: UInt8 = 0
private var safeAreaGuideKey: UInt8 = 0


public extension UIView {

    // MARK: - addLayoutGuide backport
    @available(iOS, introduced: 6.0, deprecated: 9.0)
    @_disfavoredOverload
    func addLayoutGuide(_ guide: UILayoutGuideShim) {
        guide.attach(to: self)

        var guides = objc_getAssociatedObject(self, &layoutGuidesKey) as? [UILayoutGuideShim] ?? []
        guides.append(guide)
        objc_setAssociatedObject(self, &layoutGuidesKey, guides, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    @available(iOS, introduced: 6.0, deprecated: 9.0)
    var layoutGuides: [UILayoutGuideShim] {
        get { objc_getAssociatedObject(self, &layoutGuidesKey) as? [UILayoutGuideShim] ?? [] }
        set { objc_setAssociatedObject(self, &layoutGuidesKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    // MARK: - layoutMarginsGuide
    @available(iOS, introduced: 6.0, obsoleted: 11.0)
    @_disfavoredOverload
    var layoutMarginsGuide: UILayoutGuideShim {
        if let guide = objc_getAssociatedObject(self, &layoutMarginsGuideKey) as? UILayoutGuideShim { return guide }

        let guide = UILayoutGuideShim()
        guide.attach(to: self)

        // Pin proxyView to layoutMargins
        NSLayoutConstraint.activate([
            guide.topAnchor.constraint(equalTo: topAnchor, constant: layoutMargins.top),
            guide.leadingAnchor.constraint(equalTo: leadingAnchor, constant: layoutMargins.left),
            guide.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -layoutMargins.right),
            guide.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -layoutMargins.bottom)
        ])

        addLayoutGuide(guide)
        objc_setAssociatedObject(self, &layoutMarginsGuideKey, guide, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return guide
    }

    // MARK: - safeAreaLayoutGuide
    @available(iOS, introduced: 6.0, obsoleted: 11.0)
    @_disfavoredOverload
    var safeAreaLayoutGuide: UILayoutGuideShim {
        if let guide = objc_getAssociatedObject(self, &safeAreaGuideKey) as? UILayoutGuideShim { return guide }

        let guide = UILayoutGuideShim()
        guide.attach(to: self)

        var topInset: CGFloat = 0
        var bottomInset: CGFloat = 0
        if let vc = sequence(first: self.next, next: { $0?.next }).compactMap({ $0 as? UIViewController }).first {
            topInset += vc.topLayoutGuide.length
            bottomInset += vc.bottomLayoutGuide.length
        }

        NSLayoutConstraint.activate([
            guide.topAnchor.constraint(equalTo: topAnchor, constant: topInset),
            guide.leadingAnchor.constraint(equalTo: leadingAnchor),
            guide.trailingAnchor.constraint(equalTo: trailingAnchor),
            guide.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -bottomInset)
        ])

        addLayoutGuide(guide)
        objc_setAssociatedObject(self, &safeAreaGuideKey, guide, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        
        return guide
    }
}

@available(iOS, introduced: 6.0, obsoleted: 11.0)
extension UILayoutGuide: CustomDebugStringConvertible {
    public var debugDescription: String {
        let frameDesc = "\(proxyView.frame)"
        let owning = owningView.map { "\($0)" } ?? "nil"
        return "<UILayoutGuideShim: \(Unmanaged.passUnretained(self).toOpaque()) layoutFrame = \(frameDesc), owningView = \(owning)>"
    }
}

// MARK: - UIViewController layout support shim
private var topGuideKey: UInt8 = 0
private var bottomGuideKey: UInt8 = 0

@available(iOS, introduced: 6.0, deprecated: 9.0)
public class UILayoutSupportShim: NSObject {
    public let length: CGFloat
    public init(length: CGFloat) { self.length = length }
}

@available(iOS, introduced: 6.0, obsoleted: 9.0)
public extension UIViewController {
    @_disfavoredOverload
    var topLayoutGuide: UILayoutSupportShim {
        if let guide = objc_getAssociatedObject(self, &topGuideKey) as? UILayoutSupportShim { return guide }
        let statusBarHeight: CGFloat = UIApplication.shared.isStatusBarHidden ? 0 : 20
        let guide = UILayoutSupportShim(length: statusBarHeight) // default status bar height
        objc_setAssociatedObject(self, &topGuideKey, guide, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return guide
    }
    
    @_disfavoredOverload
    var bottomLayoutGuide: UILayoutSupportShim {
        if let guide = objc_getAssociatedObject(self, &bottomGuideKey) as? UILayoutSupportShim { return guide }
        let guide = UILayoutSupportShim(length: 0)
        objc_setAssociatedObject(self, &bottomGuideKey, guide, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return guide
    }
}


// MARK: - UIView safeAreaInsets backport
private var safeAreaInsetsKey: UInt8 = 0
public extension UIView {
    
    @available(iOS, introduced: 6.0, obsoleted: 11.0)
    @_disfavoredOverload
    var safeAreaInsets: UIEdgeInsets {

        if let insets = objc_getAssociatedObject(self, &safeAreaInsetsKey) as? NSValue {
            return insets.uiEdgeInsetsValue
        }

        var topInset: CGFloat = 0
        var bottomInset: CGFloat = 0
        var leftInset: CGFloat = 0
        var rightInset: CGFloat = 0

        // Status bar height
        if #available(iOS 13.0.0, *) {
            topInset += UIApplication.shared.isStatusBarHidden ? 0 : 20
        }

        // Navigation bar height
        if #available(iOS 13.0.0, *) {
            if let nav = closestViewController()?.navigationController, !nav.isNavigationBarHidden {
                topInset += nav.navigationBar.frame.height
            }
        }

        // Tab bar height
        if let tab = closestViewController()?.tabBarController, !tab.tabBar.isHidden {
            bottomInset += tab.tabBar.frame.height
        }

        let insets = UIEdgeInsets(top: topInset, left: leftInset, bottom: bottomInset, right: rightInset)
        objc_setAssociatedObject(self, &safeAreaInsetsKey, NSValue(uiEdgeInsets: insets), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return insets
    }

    // Helper to find the nearest UIViewController
    private func closestViewController() -> UIViewController? {
        return sequence(first: self.next, next: { $0?.next }).compactMap { $0 as? UIViewController }.first
    }
}

#endif
#endif
#endif
