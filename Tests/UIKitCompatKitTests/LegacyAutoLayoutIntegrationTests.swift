//
//  LegacyAutoLayoutIntegrationTests.swift
//  UIKitCompatKitTests
//
//  Integration tests for the UIKit bridge + runtime gate (docs/legacy-autolayout.md §6).
//
//  These tests run on the modern simulator, i.e. exactly where the backport must be *inert*:
//  `LegacyAutoLayout.isRequired == false`, nothing is swizzled, no system NSLayoutConstraint is
//  touched, but the explicit `legacy*` API (and the engine behind it) remains usable for tests and
//  deterministic compat shims.
//

import XCTest
import UIKit
import ObjectiveC
@testable import LegacyAutoLayout

// MARK: - Fake NSCoder

/// Minimal `NSCoder` that serves an in-memory dictionary, so the nib-decoding tests can use exactly
/// Apple's archive keys without depending on a real xib.
private final class LegacyFakeNSCoder: NSCoder {

    private let values: [String: Any]

    init(values: [String: Any]) {
        self.values = values
        super.init()
    }

    required init?(coder: NSCoder) {
        fatalError("LegacyFakeNSCoder is decode-only test scaffolding")
    }

    override func containsValue(forKey key: String) -> Bool {
        values[key] != nil
    }

    override func decodeObject(forKey key: String) -> Any? {
        values[key]
    }

    override func decodeInteger(forKey key: String) -> Int {
        (values[key] as? NSNumber)?.intValue ?? 0
    }

    override func decodeFloat(forKey key: String) -> Float {
        (values[key] as? NSNumber)?.floatValue ?? 0
    }

    override func decodeDouble(forKey key: String) -> Double {
        (values[key] as? NSNumber)?.doubleValue ?? 0
    }

    override func decodeBool(forKey key: String) -> Bool {
        (values[key] as? NSNumber)?.boolValue ?? false
    }
}

// MARK: - Tests

@MainActor
final class LegacyAutoLayoutIntegrationTests: XCTestCase {

    // MARK: Gate / inertness

    func testGateIsInertOnModernOSAndInstallIsIdempotent() {
        // Swift can only run on iOS 7+, so #available(iOS 6.0, *) is always true here and the
        // backport must never claim to be required.
        XCTAssertFalse(LegacyAutoLayout.isRequired)
        XCTAssertFalse(LegacyAutoLayout.isActive)

        // Snapshot the system layoutSubviews IMP so we can prove installIfNeeded() does not swizzle.
        let layoutSubviewsSelector = NSSelectorFromString("layoutSubviews")
        let layoutSubviewsBefore = class_getInstanceMethod(UIView.self, layoutSubviewsSelector)
        let layoutSubviewsIMPBefore = layoutSubviewsBefore.map { method_getImplementation($0) }

        XCTAssertFalse(LegacyAutoLayout.installIfNeeded())
        // Installing twice must be safe as well.
        XCTAssertFalse(LegacyAutoLayout.installIfNeeded())

        XCTAssertFalse(LegacyAutoLayout.isActive)
        let layoutSubviewsIMPAfter = class_getInstanceMethod(UIView.self, layoutSubviewsSelector)
            .map { method_getImplementation($0) }
        XCTAssertEqual(
            layoutSubviewsIMPBefore.map { UInt(bitPattern: $0) },
            layoutSubviewsIMPAfter.map { UInt(bitPattern: $0) },
            "installIfNeeded() must not swizzle UIView.layoutSubviews on iOS 6+"
        )

        // None of the bridge's hook methods may have been added to UIView on a modern OS.
        XCTAssertFalse(UIView.instancesRespond(to: NSSelectorFromString("rr_r_layoutSubviews")))
        XCTAssertFalse(UIView.instancesRespond(to: NSSelectorFromString("rr_a_constraints")))
        XCTAssertFalse(UIView.instancesRespond(to: NSSelectorFromString("rr_a_addConstraint:")))

        // Nothing was installed, so there is nothing to uninstall.
        XCTAssertFalse(LegacyAutoLayout.uninstallForTesting())
    }

    func testLegacyConstraintAPIsDoNotTouchSystemLayout() {
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        let child = UIView(frame: CGRect(x: 0, y: 0, width: 20, height: 20))
        container.addSubview(child)
        child.layoutIfNeeded()

        XCTAssertTrue(child.constraints.isEmpty)
        XCTAssertTrue(container.constraints.isEmpty)

        let constraint = RRLayoutConstraint(
            item: child,
            attribute: .width,
            relatedBy: .equal,
            toItem: nil,
            attribute: .notAnAttribute,
            multiplier: 1,
            constant: 50
        )
        XCTAssertFalse(constraint.legacyIsActive)

        child.legacyAddConstraint(constraint)
        XCTAssertEqual(child.legacyConstraints.count, 1)
        XCTAssertTrue(child.legacyConstraints[0] === constraint)
        // Stored only in the backport: neither the system array nor NSLayoutConstraint activation.
        XCTAssertTrue(child.constraints.isEmpty)
        XCTAssertTrue(container.constraints.isEmpty)
        XCTAssertFalse(constraint.legacyIsActive)

        child.legacyRemoveConstraint(constraint)
        XCTAssertTrue(child.legacyConstraints.isEmpty)
        XCTAssertTrue(child.constraints.isEmpty)
    }

    // MARK: Storage round-trips

    func testTranslatesAutoresizingMaskDefaultsToTrueAndRoundTrips() {
        let view = UIView()
        // The whole point of the backport: old views keep their frames unless they opt out.
        XCTAssertTrue(view.legacyTranslatesAutoresizingMaskIntoConstraints)

        view.legacyTranslatesAutoresizingMaskIntoConstraints = false
        XCTAssertFalse(view.legacyTranslatesAutoresizingMaskIntoConstraints)

        view.legacyTranslatesAutoresizingMaskIntoConstraints = true
        XCTAssertTrue(view.legacyTranslatesAutoresizingMaskIntoConstraints)
    }

    func testIntrinsicContentSizeAndPrioritiesRoundTrip() {
        let view = UIView()
        XCTAssertEqual(view.legacyIntrinsicContentSize.width, UIView.noIntrinsicMetric)
        XCTAssertEqual(view.legacyIntrinsicContentSize.height, UIView.noIntrinsicMetric)

        view.legacyIntrinsicContentSize = CGSize(width: 120, height: 44)
        XCTAssertEqual(view.legacyIntrinsicContentSize, CGSize(width: 120, height: 44))

        // UIKit defaults: hugging 250, compression resistance 750, both axes.
        XCTAssertEqual(view.legacyContentHuggingPriority(for: .horizontal), 250)
        XCTAssertEqual(view.legacyContentHuggingPriority(for: .vertical), 250)
        XCTAssertEqual(view.legacyContentCompressionResistancePriority(for: .horizontal), 750)
        XCTAssertEqual(view.legacyContentCompressionResistancePriority(for: .vertical), 750)

        view.legacySetContentHuggingPriority(100, for: .horizontal)
        view.legacySetContentHuggingPriority(900, for: .vertical)
        XCTAssertEqual(view.legacyContentHuggingPriority(for: .horizontal), 100)
        XCTAssertEqual(view.legacyContentHuggingPriority(for: .vertical), 900)

        view.legacySetContentCompressionResistancePriority(600, for: .horizontal)
        view.legacySetContentCompressionResistancePriority(1000, for: .vertical)
        XCTAssertEqual(view.legacyContentCompressionResistancePriority(for: .horizontal), 600)
        XCTAssertEqual(view.legacyContentCompressionResistancePriority(for: .vertical), 1000)

        // Baselines default to 0 and round-trip through associated storage.
        XCTAssertEqual(view.legacyFirstBaselineOffsetFromTop, 0)
        XCTAssertEqual(view.legacyLastBaselineOffsetFromBottom, 0)
        view.legacyFirstBaselineOffsetFromTop = 12.5
        view.legacyLastBaselineOffsetFromBottom = 4.5
        XCTAssertEqual(view.legacyFirstBaselineOffsetFromTop, 12.5)
        XCTAssertEqual(view.legacyLastBaselineOffsetFromBottom, 4.5)
    }

    func testAddAndRemoveConstraintRoundTripSortsByPriorityAndPropagates() {
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        let child = UIView(frame: CGRect(x: 10, y: 10, width: 100, height: 50))
        container.addSubview(child)
        container.layoutIfNeeded()

        let lowPriority = RRLayoutConstraint(
            item: child,
            attribute: .width,
            relatedBy: .equal,
            toItem: nil,
            attribute: .notAnAttribute,
            multiplier: 1,
            constant: 100
        )
        lowPriority.priority = 500
        let requiredPriority = RRLayoutConstraint(
            item: child,
            attribute: .height,
            relatedBy: .equal,
            toItem: nil,
            attribute: .notAnAttribute,
            multiplier: 1,
            constant: 50
        )
        requiredPriority.priority = RRLayoutPriorityValue.required

        child.legacyAddConstraint(requiredPriority)
        child.legacyAddConstraints([lowPriority])

        // RRAutoLayout keeps constraints sorted by ascending priority.
        XCTAssertEqual(child.legacyConstraints.count, 2)
        XCTAssertTrue(child.legacyConstraints[0] === lowPriority)
        XCTAssertTrue(child.legacyConstraints[1] === requiredPriority)

        // Adding the same constraint again is a no-op instead of duplicating it.
        child.legacyAddConstraint(lowPriority)
        XCTAssertEqual(child.legacyConstraints.count, 2)

        // Adding a constraint dirties the view and schedules its container (`UIView` has no public
        // `needsLayout` getter, so the bridge counts the propagation for tests).
        let invalidationCountBefore = LegacyAutoLayoutRuntime.containerLayoutInvalidationCount
        child.legacySetNeedsUpdateConstraints()
        XCTAssertTrue(child.legacyConstraintsAreDirty)
        XCTAssertGreaterThan(
            LegacyAutoLayoutRuntime.containerLayoutInvalidationCount,
            invalidationCountBefore,
            "constraint changes must schedule the container's layout"
        )

        // A view without a superview has nothing to propagate to.
        let orphan = UIView()
        let orphanCountBefore = LegacyAutoLayoutRuntime.containerLayoutInvalidationCount
        orphan.legacySetNeedsUpdateConstraints()
        XCTAssertEqual(LegacyAutoLayoutRuntime.containerLayoutInvalidationCount, orphanCountBefore)

        child.legacyUpdateConstraintsIfNeeded()
        XCTAssertFalse(child.legacyConstraintsAreDirty)

        child.legacyRemoveConstraint(lowPriority)
        XCTAssertEqual(child.legacyConstraints.count, 1)
        XCTAssertTrue(child.legacyConstraints[0] === requiredPriority)
        XCTAssertTrue(child.legacyConstraintsAreDirty)

        child.legacyRemoveConstraints([requiredPriority])
        XCTAssertTrue(child.legacyConstraints.isEmpty)
        // Removing something that is not stored must not crash or change anything.
        child.legacyRemoveConstraint(lowPriority)
        XCTAssertTrue(child.legacyConstraints.isEmpty)
    }

    func testConstraintsReferencingNonViewItemsAreTolerated() {
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        let child = UIView(frame: CGRect(x: 0, y: 0, width: 10, height: 10))
        child.legacyTranslatesAutoresizingMaskIntoConstraints = false
        container.addSubview(child)

        let foreignItem = NSObject()
        let constraint = RRLayoutConstraint(
            item: child,
            attribute: .leading,
            relatedBy: .equal,
            toItem: foreignItem,
            attribute: .leading,
            multiplier: 1,
            constant: 5
        )
        child.legacyAddConstraint(constraint)

        // Must not crash; unsupported items are simply ignored by the engine.
        container.legacyLayoutIfNeeded()
        XCTAssertTrue(foreignItem.isEqual(foreignItem))
    }

    // MARK: Nib decoding

    func testNibConstraintDecodingWithAppleKeys() {
        let firstView = UIView()
        let secondView = UIView()

        let decoder = LegacyFakeNSCoder(values: [
            LegacyAutoLayoutNibKey.firstItem: firstView,
            LegacyAutoLayoutNibKey.firstAttribute: NSNumber(value: RRLayoutAttribute.width.rawValue),
            LegacyAutoLayoutNibKey.secondItem: secondView,
            LegacyAutoLayoutNibKey.secondAttribute: NSNumber(value: RRLayoutAttribute.width.rawValue),
            LegacyAutoLayoutNibKey.priority: NSNumber(value: 750),
            LegacyAutoLayoutNibKey.constant: NSNumber(value: 12.5),
            LegacyAutoLayoutNibKey.relation: NSNumber(value: RRLayoutRelation.greaterThanOrEqual.rawValue),
            LegacyAutoLayoutNibKey.multiplier: NSNumber(value: 2.0),
            LegacyAutoLayoutNibKey.identifier: "legacyTestConstraint",
            LegacyAutoLayoutNibKey.shouldBeArchived: NSNumber(value: true)
        ])

        guard let constraint = RRLayoutConstraint.from(decoder: decoder) else {
            return XCTFail("expected the archived constraint to decode")
        }
        XCTAssertTrue(constraint.firstItem as AnyObject? === firstView)
        XCTAssertTrue(constraint.secondItem as AnyObject? === secondView)
        XCTAssertEqual(constraint.firstAttribute, .width)
        XCTAssertEqual(constraint.secondAttribute, .width)
        XCTAssertEqual(constraint.relation, .greaterThanOrEqual)
        XCTAssertEqual(constraint.priority, 750)
        XCTAssertEqual(constraint.constant, 12.5)
        XCTAssertEqual(constraint.multiplier, 2.0)
        XCTAssertEqual(constraint.identifier, "legacyTestConstraint")
        XCTAssertTrue(constraint.legacyShouldBeArchived)
    }

    func testNibConstraintDecodingToleratesMissingKeysAndNullItems() {
        // An archive with no usable attribute is illegal for UIKit and is skipped, never a crash.
        let emptyDecoder = LegacyFakeNSCoder(values: [:])
        XCTAssertNil(RRLayoutConstraint.from(decoder: emptyDecoder))
        XCTAssertNotNil(LegacyAutoLayoutNibCoding.validationError(from: emptyDecoder))

        // Minimal constant constraint: only item + attribute archived; Apple defaults fill the rest.
        let firstView = UIView()
        let minimalDecoder = LegacyFakeNSCoder(values: [
            LegacyAutoLayoutNibKey.firstItem: firstView,
            LegacyAutoLayoutNibKey.firstAttribute: NSNumber(value: RRLayoutAttribute.height.rawValue)
        ])
        guard let constraint = RRLayoutConstraint.from(decoder: minimalDecoder) else {
            return XCTFail("expected the minimal constant constraint to decode")
        }
        XCTAssertTrue(constraint.firstItem as AnyObject? === firstView)
        XCTAssertNil(constraint.secondItem)
        XCTAssertEqual(constraint.firstAttribute, .height)
        XCTAssertEqual(constraint.secondAttribute, .notAnAttribute)
        XCTAssertEqual(constraint.relation, .equal)
        XCTAssertEqual(constraint.priority, RRLayoutPriorityValue.required)
        XCTAssertEqual(constraint.constant, 0)
        XCTAssertEqual(constraint.multiplier, 1)
        XCTAssertNil(constraint.identifier)
        XCTAssertFalse(constraint.legacyShouldBeArchived)

        // NSNull for the second item behaves like an absent second item.
        let nullSecondItemDecoder = LegacyFakeNSCoder(values: [
            LegacyAutoLayoutNibKey.firstItem: firstView,
            LegacyAutoLayoutNibKey.firstAttribute: NSNumber(value: RRLayoutAttribute.height.rawValue),
            LegacyAutoLayoutNibKey.secondItem: NSNull()
        ])
        guard let secondConstraint = RRLayoutConstraint.from(decoder: nullSecondItemDecoder) else {
            return XCTFail("expected the NSNull-second-item constraint to decode")
        }
        XCTAssertTrue(secondConstraint.firstItem as AnyObject? === firstView)
        XCTAssertNil(secondConstraint.secondItem)
        XCTAssertEqual(secondConstraint.firstAttribute, .height)

        // No UIViewAutolayoutConstraints key at all -> nothing to decode.
        XCTAssertNil(LegacyAutoLayoutNibCoding.constraints(from: emptyDecoder))
    }

    func testNibConstraintDecodingSkipsIllegalPairings() {
        let firstView = UIView()
        let secondView = UIView()
        // A position attribute paired with a size attribute is illegal (position x size).
        let decoder = LegacyFakeNSCoder(values: [
            LegacyAutoLayoutNibKey.firstItem: firstView,
            LegacyAutoLayoutNibKey.firstAttribute: NSNumber(value: RRLayoutAttribute.leading.rawValue),
            LegacyAutoLayoutNibKey.secondItem: secondView,
            LegacyAutoLayoutNibKey.secondAttribute: NSNumber(value: RRLayoutAttribute.width.rawValue)
        ])

        XCTAssertNil(RRLayoutConstraint.from(decoder: decoder), "illegal archives must be skipped, not raised")
        XCTAssertEqual(
            LegacyAutoLayoutNibCoding.validationError(from: decoder),
            .invalidPairing(first: .leading, second: .width)
        )

        // A location attribute with no second item is equally illegal (location == constant).
        let locationConstantDecoder = LegacyFakeNSCoder(values: [
            LegacyAutoLayoutNibKey.firstItem: firstView,
            LegacyAutoLayoutNibKey.firstAttribute: NSNumber(value: RRLayoutAttribute.left.rawValue)
        ])
        XCTAssertNil(RRLayoutConstraint.from(decoder: locationConstantDecoder))
        XCTAssertEqual(
            LegacyAutoLayoutNibCoding.validationError(from: locationConstantDecoder),
            .locationEqualToConstant(attribute: .left)
        )
    }

    func testViewAutolayoutConstraintsDecoding() {
        let firstView = UIView()
        let secondView = UIView()
        let constraint = RRLayoutConstraint(
            item: firstView,
            attribute: .leading,
            relatedBy: .equal,
            toItem: secondView,
            attribute: .trailing,
            multiplier: 1,
            constant: 8
        )
        let decoder = LegacyFakeNSCoder(values: [
            LegacyAutoLayoutNibKey.viewAutolayoutConstraints: [constraint]
        ])

        let host = UIView()
        XCTAssertEqual(host.legacyDecodeAutolayoutConstraints(from: decoder), 1)
        XCTAssertEqual(host.legacyConstraints.count, 1)
        XCTAssertTrue(host.legacyConstraints[0] === constraint)
        XCTAssertTrue(host.constraints.isEmpty, "nib decoding must only populate the legacy storage")
    }

    // MARK: LegacyLayoutItem conformance

    func testViewConformsToLegacyLayoutItem() {
        let container = UIView(frame: CGRect(x: 10, y: 20, width: 300, height: 400))
        let child = UIView(frame: CGRect(x: 5, y: 6, width: 70, height: 80))
        container.addSubview(child)

        let containerItem: LegacyLayoutItem = container
        let childItem: LegacyLayoutItem = child

        XCTAssertNil(containerItem.layoutSuperitem)
        XCTAssertTrue(childItem.layoutSuperitem === container)
        XCTAssertEqual(containerItem.layoutSubitems.count, 1)
        XCTAssertTrue(containerItem.layoutSubitems[0] === child)
        XCTAssertEqual(childItem.layoutFrame, CGRect(x: 5, y: 6, width: 70, height: 80))

        // Defaults come from the UIView bridge: translating autoresizing mask, no intrinsic size,
        // UIKit hub priorities, and "no baseline" until explicitly opted in.
        XCTAssertTrue(childItem.layoutTranslatesAutoresizingMaskIntoConstraints)
        XCTAssertEqual(childItem.layoutIntrinsicContentSize.width, UIView.noIntrinsicMetric)
        XCTAssertEqual(childItem.layoutIntrinsicContentSize.height, UIView.noIntrinsicMetric)
        XCTAssertEqual(childItem.layoutContentHuggingPriority(for: .horizontal), 250)
        XCTAssertEqual(childItem.layoutContentCompressionResistancePriority(for: .vertical), 750)
        XCTAssertNil(childItem.layoutFirstBaselineOffsetFromTop)
        XCTAssertNil(childItem.layoutLastBaselineOffsetFromBottom)

        let constraint = RRLayoutConstraint(
            item: child,
            attribute: .width,
            relatedBy: .equal,
            toItem: nil,
            attribute: .notAnAttribute,
            multiplier: 1,
            constant: 70
        )
        child.legacyAddConstraint(constraint)
        XCTAssertEqual(childItem.layoutConstraints.count, 1)
        XCTAssertTrue(childItem.layoutConstraints[0] === constraint)

        // layoutSetFrame writes bounds + center (never frame), which is what keeps the swizzled
        // setBounds:/setCenter: hooks from re-entering `setFrame:`.
        childItem.layoutSetFrame(CGRect(x: 40, y: 50, width: 90, height: 60))
        XCTAssertEqual(child.frame, CGRect(x: 40, y: 50, width: 90, height: 60))
        XCTAssertEqual(child.bounds.size, CGSize(width: 90, height: 60))
        XCTAssertEqual(child.center, CGPoint(x: 85, y: 80))

        // Baseline opt-in is visible through the protocol.
        child.legacyFirstBaselineOffsetFromTop = 3
        child.legacyLastBaselineOffsetFromBottom = 7
        XCTAssertEqual(childItem.layoutFirstBaselineOffsetFromTop, 3)
        XCTAssertEqual(childItem.layoutLastBaselineOffsetFromBottom, 7)

        child.legacyIntrinsicContentSize = CGSize(width: 12, height: 34)
        XCTAssertEqual(childItem.layoutIntrinsicContentSize, CGSize(width: 12, height: 34))
    }

    // MARK: Engine pass through the bridge

    func testLegacyLayoutIfNeededRunsEngineOnPinnedSubtree() {
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        let child = UIView(frame: CGRect(x: 0, y: 0, width: 10, height: 10))
        child.legacyTranslatesAutoresizingMaskIntoConstraints = false
        container.addSubview(child)

        child.legacyAddConstraints([
            RRLayoutConstraint(
                item: child,
                attribute: .leading,
                relatedBy: .equal,
                toItem: container,
                attribute: .leading,
                multiplier: 1,
                constant: 20
            ),
            RRLayoutConstraint(
                item: child,
                attribute: .top,
                relatedBy: .equal,
                toItem: container,
                attribute: .top,
                multiplier: 1,
                constant: 30
            ),
            RRLayoutConstraint(
                item: child,
                attribute: .width,
                relatedBy: .equal,
                toItem: nil,
                attribute: .notAnAttribute,
                multiplier: 1,
                constant: 100
            ),
            RRLayoutConstraint(
                item: child,
                attribute: .height,
                relatedBy: .equal,
                toItem: nil,
                attribute: .notAnAttribute,
                multiplier: 1,
                constant: 50
            )
        ])

        container.legacyLayoutIfNeeded()

        XCTAssertEqual(child.frame.origin.x, 20, accuracy: 0.5)
        XCTAssertEqual(child.frame.origin.y, 30, accuracy: 0.5)
        XCTAssertEqual(child.frame.size.width, 100, accuracy: 0.5)
        XCTAssertEqual(child.frame.size.height, 50, accuracy: 0.5)
        // The root is the container and must not be resized by the pass.
        XCTAssertEqual(container.frame, CGRect(x: 0, y: 0, width: 320, height: 480))
        // The engine must not have installed anything into the system machinery.
        XCTAssertTrue(container.constraints.isEmpty)
        XCTAssertTrue(child.constraints.isEmpty)
    }

    // MARK: Autoresizing translation helper

    func testAutoresizingMaskTranslationProducesFourFramePinningConstraints() {
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 200, height: 100))
        let child = UIView(frame: CGRect(x: 12, y: 8, width: 40, height: 24))
        container.addSubview(child)

        let constraints = LegacyAutoLayoutAutoresizing.framePinningConstraints(for: child)
        XCTAssertEqual(constraints.count, 4)

        let byAttribute = Dictionary(
            uniqueKeysWithValues: constraints.map { ($0.firstAttribute, $0) }
        )
        XCTAssertEqual(byAttribute[.left]?.constant, 12)
        XCTAssertEqual(byAttribute[.top]?.constant, 8)
        XCTAssertEqual(byAttribute[.width]?.constant, 40)
        XCTAssertEqual(byAttribute[.height]?.constant, 24)

        for constraint in constraints {
            XCTAssertEqual(constraint.priority, RRLayoutPriorityValue.required)
            XCTAssertEqual(constraint.relation, .equal)
            XCTAssertEqual(constraint.multiplier, 1)
            XCTAssertTrue(constraint.firstItem as AnyObject? === child)
        }
        XCTAssertTrue(byAttribute[.left]?.secondItem as AnyObject? === container)
        XCTAssertTrue(byAttribute[.top]?.secondItem as AnyObject? === container)
        XCTAssertNil(byAttribute[.width]?.secondItem)
        XCTAssertNil(byAttribute[.height]?.secondItem)

        // The mask is recorded on the constraints (the frame stays the numeric authority).
        XCTAssertEqual(
            byAttribute[.width]?.identifier,
            "RRAutoLayoutAutoresizing:\(LegacyAutoLayoutAutoresizing.legacyAutoresizingMaskDescription(child.autoresizingMask))"
        )
    }

    func testNibConstraintDecodingPrefersV2Keys() {
        let plainSecondView = UIView()
        let v2SecondView = UIView()
        let decoder = LegacyFakeNSCoder(values: [
            // Historical keys carry different values on purpose; every V2 must win.
            LegacyAutoLayoutNibKey.firstAttribute: NSNumber(value: RRLayoutAttribute.width.rawValue),
            LegacyAutoLayoutNibKey.firstAttributeV2: NSNumber(value: RRLayoutAttribute.height.rawValue),
            LegacyAutoLayoutNibKey.secondItem: plainSecondView,
            LegacyAutoLayoutNibKey.secondItemV2: v2SecondView,
            LegacyAutoLayoutNibKey.secondAttribute: NSNumber(value: RRLayoutAttribute.width.rawValue),
            LegacyAutoLayoutNibKey.secondAttributeV2: NSNumber(value: RRLayoutAttribute.height.rawValue),
            LegacyAutoLayoutNibKey.constant: NSNumber(value: 1.0),
            LegacyAutoLayoutNibKey.constantV2: NSNumber(value: 2.0),
            LegacyAutoLayoutNibKey.multiplier: NSNumber(value: 3.0),
            LegacyAutoLayoutNibKey.multiplierV2: NSNumber(value: 4.0),
            LegacyAutoLayoutNibKey.priority: NSNumber(value: 750),
            LegacyAutoLayoutNibKey.priorityV2: NSNumber(value: 500),
            LegacyAutoLayoutNibKey.identifier: "v1",
            LegacyAutoLayoutNibKey.identifierV2: "v2"
        ])

        guard let constraint = RRLayoutConstraint.from(decoder: decoder) else {
            return XCTFail("expected the V2-keyed constraint to decode")
        }
        XCTAssertEqual(constraint.firstAttribute, .height)
        XCTAssertEqual(constraint.secondAttribute, .height)
        XCTAssertTrue(constraint.secondItem as AnyObject? === v2SecondView)
        XCTAssertEqual(constraint.constant, 2)
        XCTAssertEqual(constraint.multiplier, 4)
        XCTAssertEqual(constraint.priority, 500)
        XCTAssertEqual(constraint.identifier, "v2")
    }

    func testNibConstraintDecodingAcceptsHistoricalNSIdentifierFallback() {
        let view = UIView()
        let decoder = LegacyFakeNSCoder(values: [
            LegacyAutoLayoutNibKey.firstItem: view,
            LegacyAutoLayoutNibKey.firstAttribute: NSNumber(value: RRLayoutAttribute.width.rawValue),
            LegacyAutoLayoutNibKey.legacyIdentifier: "historical"
        ])
        guard let constraint = RRLayoutConstraint.from(decoder: decoder) else {
            return XCTFail("expected the historical-identifier constraint to decode")
        }
        XCTAssertEqual(constraint.identifier, "historical")
    }

    func testViewArchiveFlagsDecoding() {
        let decoder = LegacyFakeNSCoder(values: [
            LegacyAutoLayoutNibKey.viewDoesNotTranslateAutoresizingMaskIntoConstraints: NSNumber(value: true),
            LegacyAutoLayoutNibKey.viewAutoresizingMask: NSNumber(
                value: UIView.AutoresizingMask.flexibleWidth.rawValue
                    | UIView.AutoresizingMask.flexibleHeight.rawValue
            )
        ])

        let flags = LegacyAutoLayoutNibCoding.viewFlags(from: decoder)
        XCTAssertEqual(flags.translatesAutoresizingMaskIntoConstraints, false)
        XCTAssertEqual(
            flags.autoresizingMask,
            UIView.AutoresizingMask.flexibleWidth.rawValue
                | UIView.AutoresizingMask.flexibleHeight.rawValue
        )

        let view = UIView()
        XCTAssertTrue(view.legacyTranslatesAutoresizingMaskIntoConstraints)
        XCTAssertTrue(view.legacyDecodeAutoresizingArchiveFlags(from: decoder))
        XCTAssertFalse(view.legacyTranslatesAutoresizingMaskIntoConstraints)
        XCTAssertTrue(view.autoresizingMask.contains(.flexibleWidth))
        XCTAssertTrue(view.autoresizingMask.contains(.flexibleHeight))

        // An archive without the view-level keys decodes nothing and leaves the view untouched.
        let emptyDecoder = LegacyFakeNSCoder(values: [:])
        let untouchedView = UIView()
        XCTAssertFalse(untouchedView.legacyDecodeAutoresizingArchiveFlags(from: emptyDecoder))
        XCTAssertTrue(untouchedView.legacyTranslatesAutoresizingMaskIntoConstraints)
    }

    func testFullViewArchiveDecodeAppliesFlagsAndConstraints() {
        let firstView = UIView()
        let secondView = UIView()
        let constraint = RRLayoutConstraint(
            item: firstView,
            attribute: .leading,
            relatedBy: .equal,
            toItem: secondView,
            attribute: .trailing,
            multiplier: 1,
            constant: 8
        )
        let decoder = LegacyFakeNSCoder(values: [
            LegacyAutoLayoutNibKey.viewDoesNotTranslateAutoresizingMaskIntoConstraints: NSNumber(value: true),
            LegacyAutoLayoutNibKey.viewAutoresizingMask: NSNumber(
                value: UIView.AutoresizingMask.flexibleLeftMargin.rawValue
            ),
            LegacyAutoLayoutNibKey.viewAutolayoutConstraints: [constraint]
        ])

        let host = UIView()
        XCTAssertEqual(host.legacyDecodeAutolayoutArchive(from: decoder), 1)
        XCTAssertEqual(host.legacyConstraints.count, 1)
        XCTAssertTrue(host.legacyConstraints[0] === constraint)
        XCTAssertTrue(host.constraints.isEmpty, "archive decoding must only populate the legacy storage")
        XCTAssertFalse(host.legacyTranslatesAutoresizingMaskIntoConstraints)
        XCTAssertTrue(host.autoresizingMask.contains(.flexibleLeftMargin))
    }

    func testAutoresizingReferenceStorageAndMaskMapping() {
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        let child = UIView(frame: CGRect(x: 10, y: 20, width: 100, height: 50))
        container.addSubview(child)
        let childItem: LegacyLayoutItem = child

        // UIKit's default mask is .none and no reference is captured until a layout pass runs.
        XCTAssertEqual(childItem.layoutAutoresizingMask, .none)
        XCTAssertNil(childItem.layoutAutoresizingReference)

        child.autoresizingMask = [.flexibleWidth, .flexibleTopMargin]
        XCTAssertEqual(childItem.layoutAutoresizingMask.rawValue, child.autoresizingMask.rawValue)
        XCTAssertTrue(childItem.layoutAutoresizingMask.contains(.flexibleWidth))
        XCTAssertTrue(childItem.layoutAutoresizingMask.contains(.flexibleTopMargin))
        XCTAssertFalse(childItem.layoutAutoresizingMask.contains(.flexibleHeight))

        // The bridge stores whatever geometry the engine records and it survives layout passes.
        let reference = LegacyAutoresizingReference(
            frame: child.frame,
            superviewSize: container.bounds.size
        )
        childItem.layoutUpdateAutoresizingReference(reference)
        let stored = childItem.layoutAutoresizingReference
        XCTAssertEqual(stored?.frame, reference.frame)
        XCTAssertEqual(stored?.superviewSize, reference.superviewSize)

        container.legacyLayoutIfNeeded()
        // The engine refreshes the reference after a successful write-back (storage semantics must
        // keep it non-nil either way; values may advance to the solved geometry).
        XCTAssertNotNil(childItem.layoutAutoresizingReference)
    }

    func testAutoresizingReferenceInvalidatedByFlagAndConstraintChanges() {
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        let child = UIView(frame: CGRect(x: 10, y: 20, width: 100, height: 50))
        container.addSubview(child)

        let reference = LegacyAutoresizingReference(
            frame: child.frame,
            superviewSize: container.bounds.size
        )
        let constraint = RRLayoutConstraint(
            item: child,
            attribute: .width,
            relatedBy: .equal,
            toItem: nil,
            attribute: .notAnAttribute,
            multiplier: 1,
            constant: 100
        )

        // Flipping the translates flag invalidates the captured geometry.
        child.layoutUpdateAutoresizingReference(reference)
        child.legacyTranslatesAutoresizingMaskIntoConstraints = false
        XCTAssertNil(child.layoutAutoresizingReference)

        // Adding/removing constraints can change the solved geometry, so both invalidate it too.
        child.legacyTranslatesAutoresizingMaskIntoConstraints = true
        child.layoutUpdateAutoresizingReference(reference)
        child.legacyAddConstraint(constraint)
        XCTAssertNil(child.layoutAutoresizingReference)

        child.layoutUpdateAutoresizingReference(reference)
        child.legacyRemoveConstraint(constraint)
        XCTAssertNil(child.layoutAutoresizingReference)
    }

    func testAutoresizingMaskTranslationThroughBridgeScalesOnSuperviewResize() {
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        let child = UIView(frame: CGRect(x: 10, y: 20, width: 100, height: 50))
        child.autoresizingMask = [.flexibleWidth]
        container.addSubview(child)

        // First pass: reference is captured from the current geometry, so nothing moves.
        container.legacyLayoutIfNeeded()
        XCTAssertEqual(child.frame.origin.x, 10, accuracy: 0.5)
        XCTAssertEqual(child.frame.origin.y, 20, accuracy: 0.5)
        XCTAssertEqual(child.frame.size.width, 100, accuracy: 0.5)
        XCTAssertEqual(child.frame.size.height, 50, accuracy: 0.5)
        XCTAssertEqual(child.layoutAutoresizingReference?.superviewSize, container.bounds.size)

        // Superview resize. With .flexibleWidth the left edge (10) and the right gap (210) stay fixed,
        // so the width must absorb the 80 pt delta (UIKit's NSAutoresizingMaskLayoutConstraint
        // behaviour, semantics §3.1).
        container.frame = CGRect(x: 0, y: 0, width: 400, height: 480)
        container.legacyLayoutIfNeeded()

        XCTAssertEqual(child.frame.origin.x, 10, accuracy: 0.5)
        XCTAssertEqual(child.frame.size.width, 180, accuracy: 0.5)
        XCTAssertEqual(child.frame.size.height, 50, accuracy: 0.5)
        XCTAssertEqual(
            child.layoutAutoresizingReference?.superviewSize,
            CGSize(width: 400, height: 480),
            "the engine must refresh the captured reference after write-back"
        )

        // A further pass at the same superview size must be stable (no drift from the new reference).
        container.legacyLayoutIfNeeded()
        XCTAssertEqual(child.frame.origin.x, 10, accuracy: 0.5)
        XCTAssertEqual(child.frame.size.width, 180, accuracy: 0.5)
    }

    func testLegacyLayoutUsesSemanticLayoutDirection() {
        // The simulator runs left-to-right; the bridge must query the app's semantic direction and
        // pass it to the engine rather than always defaulting without a source.
        XCTAssertEqual(LegacyAutoLayoutSemanticDirection.current, .leftToRight)
    }

    func testAutoresizingTranslationWithoutSuperviewProducesSizeOnlyConstraints() {
        // UIKit rejects "location equal to a constant", so a root view only gets the size form.
        let view = UIView(frame: CGRect(x: 0, y: 0, width: 30, height: 40))
        let constraints = LegacyAutoLayoutAutoresizing.framePinningConstraints(for: view)
        XCTAssertEqual(constraints.count, 2)
        XCTAssertEqual(Set(constraints.map { $0.firstAttribute }), [.width, .height])
        for constraint in constraints {
            XCTAssertNil(constraint.secondItem)
            XCTAssertEqual(constraint.secondAttribute, .notAnAttribute)
            XCTAssertEqual(constraint.priority, RRLayoutPriorityValue.required)
        }
    }
}
