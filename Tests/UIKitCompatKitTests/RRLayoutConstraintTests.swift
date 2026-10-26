//
//  RRLayoutConstraintTests.swift
//  UIKitCompatKitTests
//
//  Unit tests for the LegacyAutoLayout constraint model (docs §4):
//  attribute/relation raw values (NIB compatibility), priority constants and
//  priority -> Cassowary strength mapping, the constraint object itself
//  (weak items, isActive/activate/deactivate) and UIKit-compatible validation.
//

import XCTest
import Foundation
import CoreGraphics
import Cassowary
@testable import LegacyAutoLayout

final class RRLayoutConstraintTests: XCTestCase {

    /// An item stand-in for weak-reference tests; any class works.
    private final class DummyItem: NSObject {}

    // MARK: - Attribute raw values

    func testAttributeRawValuesMatchNSLayoutConstraintAttribute() {
        // Raw values must match NSLayoutConstraint.Attribute for nib decoding.
        XCTAssertEqual(RRLayoutAttribute.notAnAttribute.rawValue, 0)
        XCTAssertEqual(RRLayoutAttribute.left.rawValue, 1)
        XCTAssertEqual(RRLayoutAttribute.right.rawValue, 2)
        XCTAssertEqual(RRLayoutAttribute.top.rawValue, 3)
        XCTAssertEqual(RRLayoutAttribute.bottom.rawValue, 4)
        XCTAssertEqual(RRLayoutAttribute.leading.rawValue, 5)
        XCTAssertEqual(RRLayoutAttribute.trailing.rawValue, 6)
        XCTAssertEqual(RRLayoutAttribute.width.rawValue, 7)
        XCTAssertEqual(RRLayoutAttribute.height.rawValue, 8)
        XCTAssertEqual(RRLayoutAttribute.centerX.rawValue, 9)
        XCTAssertEqual(RRLayoutAttribute.centerY.rawValue, 10)
        XCTAssertEqual(RRLayoutAttribute.lastBaseline.rawValue, 11)
        XCTAssertEqual(RRLayoutAttribute.firstBaseline.rawValue, 12)
        XCTAssertEqual(RRLayoutAttribute.allCases.count, 13)
    }

    func testRelationRawValuesMatchNSLayoutConstraintRelation() {
        XCTAssertEqual(RRLayoutRelation.lessThanOrEqual.rawValue, -1)
        XCTAssertEqual(RRLayoutRelation.equal.rawValue, 0)
        XCTAssertEqual(RRLayoutRelation.greaterThanOrEqual.rawValue, 1)
    }

    func testAttributeClassification() {
        XCTAssertTrue(RRLayoutAttribute.width.isSizeAttribute)
        XCTAssertTrue(RRLayoutAttribute.height.isSizeAttribute)
        XCTAssertFalse(RRLayoutAttribute.leading.isSizeAttribute)

        XCTAssertTrue(RRLayoutAttribute.leading.isPositionAttribute)
        XCTAssertTrue(RRLayoutAttribute.centerY.isPositionAttribute)
        XCTAssertTrue(RRLayoutAttribute.lastBaseline.isPositionAttribute)
        XCTAssertFalse(RRLayoutAttribute.width.isPositionAttribute)
        XCTAssertFalse(RRLayoutAttribute.notAnAttribute.isPositionAttribute)

        XCTAssertTrue(RRLayoutAttribute.firstBaseline.isBaselineAttribute)
        XCTAssertTrue(RRLayoutAttribute.lastBaseline.isBaselineAttribute)
        XCTAssertFalse(RRLayoutAttribute.top.isBaselineAttribute)

        XCTAssertEqual(RRLayoutAttribute.leading.axis, .horizontal)
        XCTAssertEqual(RRLayoutAttribute.centerX.axis, .horizontal)
        XCTAssertEqual(RRLayoutAttribute.width.axis, .horizontal)
        XCTAssertEqual(RRLayoutAttribute.top.axis, .vertical)
        XCTAssertEqual(RRLayoutAttribute.centerY.axis, .vertical)
        XCTAssertEqual(RRLayoutAttribute.lastBaseline.axis, .vertical)
        XCTAssertNil(RRLayoutAttribute.notAnAttribute.axis)
    }

    // MARK: - Priorities

    func testPriorityConstants() {
        XCTAssertEqual(RRLayoutPriorityValue.required, 1000)
        XCTAssertEqual(RRLayoutPriorityValue.defaultHigh, 750)
        XCTAssertEqual(RRLayoutPriorityValue.defaultLow, 250)
        XCTAssertEqual(RRLayoutPriorityValue.fittingSizeLevel, 50)
        // RRLayoutPriority is a Float typealias, like UILayoutPriority.
        let priority: RRLayoutPriority = RRLayoutPriorityValue.defaultHigh
        XCTAssertEqual(priority, 750)
    }

    func testPriorityStrengthMapping() {
        XCTAssertEqual(RRLayoutPriorityMapping.strength(for: 1000), Strength.required)
        XCTAssertEqual(RRLayoutPriorityMapping.strength(for: 2000), Strength.required)

        let weak = RRLayoutPriorityMapping.strength(for: 0)
        XCTAssertEqual(weak, Strength.create(0, 0, 1))
        XCTAssertEqual(RRLayoutPriorityMapping.strength(for: -10), Strength.create(0, 0, 1))
        XCTAssertEqual(RRLayoutPriorityMapping.strength(for: RRLayoutPriority.nan), Strength.create(0, 0, 1))

        // 0 < p < 1000 -> create(p / 1000, 0, 0): strictly monotonic and below required.
        let p50 = RRLayoutPriorityMapping.strength(for: 50)
        let p250 = RRLayoutPriorityMapping.strength(for: 250)
        let p750 = RRLayoutPriorityMapping.strength(for: 750)
        let p999 = RRLayoutPriorityMapping.strength(for: 999)
        XCTAssertEqual(p750, Strength.create(0.75, 0, 0))
        XCTAssertEqual(p250, Strength.create(0.25, 0, 0))
        XCTAssertLessThan(weak, p50)
        XCTAssertLessThan(p50, p250)
        XCTAssertLessThan(p250, p750)
        XCTAssertLessThan(p750, p999)
        XCTAssertLessThan(p999, Strength.required)
        // Adjacent integer priorities are ordered; the raw weights are 1000 apart.
        XCTAssertEqual(p750.value, 750_000)
        XCTAssertEqual(p999.value - p750.value, 249_000)
    }

    // MARK: - Constraint object

    func testConstraintStoresConfiguration() {
        let first = DummyItem()
        let second = DummyItem()
        let constraint = RRLayoutConstraint(item: first,
                                            attribute: .leading,
                                            relatedBy: .greaterThanOrEqual,
                                            toItem: second,
                                            attribute: .trailing,
                                            multiplier: 0.5,
                                            constant: 12.5)
        XCTAssertTrue(constraint.firstItem as AnyObject? === first)
        XCTAssertTrue(constraint.secondItem as AnyObject? === second)
        XCTAssertEqual(constraint.firstAttribute, .leading)
        XCTAssertEqual(constraint.secondAttribute, .trailing)
        XCTAssertEqual(constraint.relation, .greaterThanOrEqual)
        XCTAssertEqual(constraint.multiplier, 0.5)
        XCTAssertEqual(constraint.constant, 12.5)
        XCTAssertEqual(constraint.priority, RRLayoutPriorityValue.required)
        XCTAssertFalse(constraint.legacyIsActive)
        XCTAssertNil(constraint.identifier)

        // Mutable configuration.
        constraint.constant = 42
        constraint.priority = RRLayoutPriorityValue.defaultLow
        constraint.identifier = "myIdentifier"
        XCTAssertEqual(constraint.constant, 42)
        XCTAssertEqual(constraint.priority, 250)
        XCTAssertEqual(constraint.identifier, "myIdentifier")
        XCTAssertFalse(constraint.description.isEmpty)
    }

    func testConstraintClassFactory() {
        let first = DummyItem()
        let second = DummyItem()
        let constraint = RRLayoutConstraint.constraint(item: first,
                                                       attribute: .width,
                                                       relatedBy: .equal,
                                                       toItem: second,
                                                       attribute: .height,
                                                       multiplier: 2,
                                                       constant: -3)
        XCTAssertEqual(constraint.multiplier, 2)
        XCTAssertEqual(constraint.constant, -3)
        XCTAssertEqual(constraint.firstAttribute, .width)
        XCTAssertEqual(constraint.secondAttribute, .height)
    }

    func testConstraintDoesNotRetainItems() {
        var constraint: RRLayoutConstraint?
        autoreleasepool {
            let item = DummyItem()
            let created = RRLayoutConstraint(item: item, attribute: .width,
                                             relatedBy: .equal, toItem: nil,
                                             attribute: .notAnAttribute,
                                             multiplier: 1, constant: 10)
            XCTAssertTrue(created.firstItem as AnyObject? === item)
            constraint = created
        }
        // The item was deallocated: Apple-compatible unowned semantics.
        XCTAssertNotNil(constraint)
        XCTAssertNil(constraint?.firstItem)
        XCTAssertNil(constraint?.secondItem)
    }

    func testActivationRegistryAndClassHelpers() {
        let item = DummyItem()
        let first = RRLayoutConstraint(item: item, attribute: .width,
                                       relatedBy: .equal, toItem: nil,
                                       attribute: .notAnAttribute, multiplier: 1, constant: 10)
        let second = RRLayoutConstraint(item: item, attribute: .height,
                                        relatedBy: .equal, toItem: nil,
                                        attribute: .notAnAttribute, multiplier: 1, constant: 20)

        XCTAssertFalse(first.legacyIsActive)
        first.legacyIsActive = true
        XCTAssertTrue(first.legacyIsActive)
        XCTAssertEqual(LegacyActiveConstraintRegistry.shared.activeConstraints().count, 1)

        RRLayoutConstraint.legacyActivate([first, second])
        XCTAssertTrue(first.legacyIsActive)
        XCTAssertTrue(second.legacyIsActive)
        // Registering twice does not duplicate.
        XCTAssertEqual(LegacyActiveConstraintRegistry.shared.activeConstraints().count, 2)

        RRLayoutConstraint.legacyDeactivate([first, second])
        XCTAssertFalse(first.legacyIsActive)
        XCTAssertFalse(second.legacyIsActive)
        XCTAssertTrue(LegacyActiveConstraintRegistry.shared.activeConstraints().isEmpty)

        first.legacyIsActive = false
        XCTAssertFalse(first.legacyIsActive)
        XCTAssertTrue(LegacyActiveConstraintRegistry.shared.activeConstraints().isEmpty)
    }

    // MARK: - Validation (UIKit-compatible legal pairings)

    func testValidationAcceptsLegalSizePairings() {
        // Constant size constraints.
        XCTAssertNil(RRLayoutConstraint.validationError(item: nil, attribute: .width,
                                                        toItem: nil, attribute: .notAnAttribute))
        XCTAssertNil(RRLayoutConstraint.validationError(item: nil, attribute: .height,
                                                        toItem: nil, attribute: .notAnAttribute))
        // Size x size, including aspect ratio (width <-> height) in any order.
        XCTAssertTrue(RRLayoutConstraint.isLegalPairing(first: .width, second: .width))
        XCTAssertTrue(RRLayoutConstraint.isLegalPairing(first: .height, second: .height))
        XCTAssertTrue(RRLayoutConstraint.isLegalPairing(first: .width, second: .height))
        XCTAssertTrue(RRLayoutConstraint.isLegalPairing(first: .height, second: .width))
    }

    func testValidationAcceptsLegalLocationPairings() {
        let legalPairs: [(RRLayoutAttribute, RRLayoutAttribute)] = [
            (.leading, .trailing), (.trailing, .leading),
            (.leading, .leading), (.trailing, .trailing),
            (.leading, .centerX), (.centerX, .leading),
            (.trailing, .centerX), (.centerX, .trailing),
            (.centerX, .centerX),
            (.left, .right), (.right, .left),
            (.left, .left), (.right, .right),
            (.left, .centerX), (.centerX, .right),
            (.top, .bottom), (.top, .top), (.bottom, .bottom),
            (.top, .centerY), (.centerY, .bottom), (.centerY, .centerY),
            (.lastBaseline, .top), (.lastBaseline, .bottom),
            (.lastBaseline, .centerY), (.lastBaseline, .lastBaseline),
            (.firstBaseline, .firstBaseline),
        ]
        let item = DummyItem()
        for pair in legalPairs {
            XCTAssertTrue(RRLayoutConstraint.isLegalPairing(first: pair.0, second: pair.1),
                          "expected \(pair.0) <-> \(pair.1) to be legal")
            XCTAssertNil(RRLayoutConstraint.validationError(item: item,
                                                            attribute: pair.0,
                                                            toItem: item,
                                                            attribute: pair.1),
                         "expected \(pair.0) <-> \(pair.1) to validate")
        }
    }

    func testValidationRejectsIllegalPairings() {
        let illegalPairs: [(RRLayoutAttribute, RRLayoutAttribute)] = [
            // Size x location is illegal (this is why there is no centering rule).
            (.leading, .width), (.width, .leading),
            (.trailing, .height), (.height, .trailing),
            (.centerX, .width), (.top, .height),
            // Different axes.
            (.top, .leading), (.left, .bottom), (.centerX, .centerY),
            // leading/trailing cannot pair with left/right.
            (.leading, .left), (.left, .trailing),
            // firstBaseline only pairs with firstBaseline.
            (.firstBaseline, .top), (.firstBaseline, .lastBaseline),
            // notAnAttribute is never a real pairing.
            (.notAnAttribute, .notAnAttribute),
            (.width, .notAnAttribute),
        ]
        let item = DummyItem()
        for pair in illegalPairs {
            XCTAssertFalse(RRLayoutConstraint.isLegalPairing(first: pair.0, second: pair.1),
                           "expected \(pair.0) <-> \(pair.1) to be illegal")
            XCTAssertNotNil(RRLayoutConstraint.validationError(item: item,
                                                               attribute: pair.0,
                                                               toItem: item,
                                                               attribute: pair.1),
                            "expected \(pair.0) <-> \(pair.1) to be rejected")
        }
    }

    func testValidationRejectsLocationEqualToConstant() {
        let error = RRLayoutConstraint.validationError(item: DummyItem(), attribute: .leading,
                                                       toItem: nil, attribute: .notAnAttribute)
        XCTAssertEqual(error, .locationEqualToConstant(attribute: .leading))
        XCTAssertFalse(error!.failureReason.isEmpty)

        let centerError = RRLayoutConstraint.validationError(item: DummyItem(), attribute: .centerX,
                                                             toItem: nil, attribute: .notAnAttribute)
        XCTAssertEqual(centerError, .locationEqualToConstant(attribute: .centerX))
    }

    func testValidationRejectsMalformedSecondSide() {
        let item = DummyItem()
        // secondItem present but notAnAttribute.
        let missingAttribute = RRLayoutConstraint.validationError(item: item, attribute: .leading,
                                                                  toItem: item, attribute: .notAnAttribute)
        XCTAssertEqual(missingAttribute, .invalidSecondAttribute(first: .leading, second: .notAnAttribute))
        // secondItem nil but a real second attribute.
        let missingItem = RRLayoutConstraint.validationError(item: item, attribute: .width,
                                                             toItem: nil, attribute: .width)
        XCTAssertEqual(missingItem, .invalidSecondAttribute(first: .width, second: .width))
    }

    func testValidationRejectsNotAnAttributeFirst() {
        let error = RRLayoutConstraint.validationError(item: DummyItem(), attribute: .notAnAttribute,
                                                       toItem: nil, attribute: .notAnAttribute)
        XCTAssertEqual(error, .firstAttributeNotAnAttribute)
    }

    func testValidationErrorMessageIsDescriptive() {
        let error = LegacyLayoutConstraintError.invalidPairing(first: .leading, second: .width)
        XCTAssertTrue(error.failureReason.contains("Invalid pairing of layout attributes"))
        XCTAssertTrue(error.description.contains("LegacyLayoutConstraintError"))
    }
}
