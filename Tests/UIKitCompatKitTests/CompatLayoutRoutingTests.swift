import XCTest
import UIKit
import LegacyAutoLayout

@MainActor
final class CompatLayoutRoutingTests: XCTestCase {
    func testModernRuntimeUsesNativeConstraintWithoutInstallingLegacyBridge() {
        guard #available(iOS 6.0, *) else { return }
        let parent = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        let child = UIView()
        parent.addSubview(child)
        CompatLayout.setTranslatesAutoresizingMaskIntoConstraints(false, on: child)
        XCTAssertFalse(child.translatesAutoresizingMaskIntoConstraints)
        let constraint = CompatLayout.anchor(child, .height).constraint(equalToConstant: 50)
        XCTAssertTrue(constraint.usesNativeBackend)
        CompatLayout.activate([constraint])
        XCTAssertTrue(constraint.isActive)
        XCTAssertEqual(child.constraints.count, 1)
        XCTAssertFalse(LegacyAutoLayout.isActive)
        XCTAssertFalse(LegacyAutoLayout.installIfNeeded())
        constraint.constant = 60
        XCTAssertEqual(child.constraints.first?.constant, 60)
        CompatLayout.deactivate([constraint])
        XCTAssertTrue(child.constraints.isEmpty)
    }

    func testLegacyRuntimeUsesLegacyConstraint() {
        if #available(iOS 6.0, *) { return }
        let parent = UIView()
        let child = UIView()
        parent.addSubview(child)
        CompatLayout.setTranslatesAutoresizingMaskIntoConstraints(false, on: child)
        let constraint = CompatLayout.anchor(child, .height).constraint(equalToConstant: 50)
        XCTAssertFalse(constraint.usesNativeBackend)
        CompatLayout.activate([constraint])
        XCTAssertTrue(LegacyAutoLayout.isActive)
        XCTAssertEqual(child.legacyConstraints.count, 1)
        CompatLayout.deactivate([constraint])
        XCTAssertTrue(child.legacyConstraints.isEmpty)
    }
}
