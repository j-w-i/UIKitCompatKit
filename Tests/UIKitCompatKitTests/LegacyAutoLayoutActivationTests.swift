//
//  LegacyAutoLayoutActivationTests.swift
//  UIKitCompatKitTests
//
//  Verifies the "drop-in" activation path: constraints activated through
//  `RRLayoutConstraint.legacyActivate([...])` (the iOS 5 `NSLayoutConstraint.activate` spelling) are
//  picked up by the Cassowary engine on the next legacy layout pass, and that the lazy
//  auto-install hook is a strict no-op on iOS 6+.
//
//  The anchor variant from the README
//  (`stuff.bottomAnchor.constraint(equalTo: view.bottomAnchor)` etc.) resolves to the legacy
//  `Anchor` only when the deployment target is below iOS 6, so it cannot be exercised from this
//  modern-deployment test target; the constraints it produces are exactly the `RRLayoutConstraint`s
//  built here.
//

import XCTest
import UIKit
import LegacyAutoLayout

@MainActor
final class LegacyAutoLayoutActivationTests: XCTestCase {

    /// The equivalent of:
    ///
    ///     NSLayoutConstraint.activate([
    ///         stuff.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ///         stuff.centerXAnchor.constraint(equalTo: view.centerXAnchor),
    ///         stuff.leadingAnchor.constraint(equalTo: view.leadingAnchor),
    ///         stuff.trailingAnchor.constraint(equalTo: view.trailingAnchor),
    ///         stuff.heightAnchor.constraint(equalToConstant: 50)
    ///     ])
    ///
    /// activated constraints are registered even though no `addConstraint` call happens, so the
    /// engine must pick them up on the next pass.
    func testActivationAloneDrivesTheEngine() {
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        let stuff = UIView(frame: .zero)
        container.addSubview(stuff)
        stuff.legacyTranslatesAutoresizingMaskIntoConstraints = false

        let constraints = [
            RRLayoutConstraint(item: stuff, attribute: .bottom, relatedBy: .equal,
                               toItem: container, attribute: .bottom,
                               multiplier: 1, constant: 0),
            RRLayoutConstraint(item: stuff, attribute: .centerX, relatedBy: .equal,
                               toItem: container, attribute: .centerX,
                               multiplier: 1, constant: 0),
            RRLayoutConstraint(item: stuff, attribute: .leading, relatedBy: .equal,
                               toItem: container, attribute: .leading,
                               multiplier: 1, constant: 0),
            RRLayoutConstraint(item: stuff, attribute: .trailing, relatedBy: .equal,
                               toItem: container, attribute: .trailing,
                               multiplier: 1, constant: 0),
            RRLayoutConstraint(item: stuff, attribute: .height, relatedBy: .equal,
                               toItem: nil, attribute: .notAnAttribute,
                               multiplier: 1, constant: 50),
        ]
        RRLayoutConstraint.legacyActivate(constraints)
        defer { RRLayoutConstraint.legacyDeactivate(constraints) }

        container.legacyLayoutIfNeeded()

        let frame = stuff.frame
        XCTAssertEqual(Double(frame.minX), 0, accuracy: 0.5)
        XCTAssertEqual(Double(frame.minY), 430, accuracy: 0.5)
        XCTAssertEqual(Double(frame.width), 320, accuracy: 0.5)
        XCTAssertEqual(Double(frame.height), 50, accuracy: 0.5)
    }

    /// Activation must not install or swizzle anything on iOS 6+: the lazy install hook is gated by
    /// `LegacyAutoLayout.isRequired`, which is false here.
    func testActivationIsInertOnModernOS() {
        XCTAssertFalse(LegacyAutoLayout.isRequired)
        XCTAssertFalse(LegacyAutoLayout.isActive)

        let container = UIView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        let child = UIView(frame: .zero)
        container.addSubview(child)

        let constraints = [
            RRLayoutConstraint(item: child, attribute: .width, relatedBy: .equal,
                               toItem: nil, attribute: .notAnAttribute,
                               multiplier: 1, constant: 40),
            RRLayoutConstraint(item: child, attribute: .height, relatedBy: .equal,
                               toItem: nil, attribute: .notAnAttribute,
                               multiplier: 1, constant: 40),
            RRLayoutConstraint(item: child, attribute: .centerX, relatedBy: .equal,
                               toItem: container, attribute: .centerX,
                               multiplier: 1, constant: 0),
            RRLayoutConstraint(item: child, attribute: .centerY, relatedBy: .equal,
                               toItem: container, attribute: .centerY,
                               multiplier: 1, constant: 0),
        ]
        RRLayoutConstraint.legacyActivate(constraints)
        defer { RRLayoutConstraint.legacyDeactivate(constraints) }

        XCTAssertFalse(LegacyAutoLayout.isActive)
        XCTAssertTrue(container.constraints.isEmpty, "activation must not touch UIKit's constraint storage")
    }
}
