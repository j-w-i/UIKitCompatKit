//
//  LegacyLayoutEngineTests.swift
//  UIKitCompatKitTests
//
//  Behavioural tests for the Cassowary-backed LegacyLayoutEngine (docs §5) on
//  fake LegacyLayoutItem trees. Covers pinned edges, centering/alignment,
//  multipliers (including aspect ratio and proportional position), inequalities,
//  priority ordering, intrinsic hugging/compression, autoresizing masks with
//  superview resizes, RTL mirroring, broken required constraints, baselines,
//  nested superitem-relative frames, stays/idempotence and solve() vs layout().
//

import XCTest
import Foundation
import CoreGraphics
@testable import LegacyAutoLayout

// MARK: - Fake layout item

/// A plain in-memory `LegacyLayoutItem` tree used instead of real UIViews so the
/// engine can be tested without UIKit.
final class FakeLayoutItem: LegacyLayoutItem {

    weak var layoutSuperitem: LegacyLayoutItem?
    private var storedSubitems: [LegacyLayoutItem] = []
    var layoutSubitems: [LegacyLayoutItem] {
        return storedSubitems
    }

    var layoutFrame: CGRect
    private(set) var layoutSetFrameCallCount = 0

    var layoutConstraints: [RRLayoutConstraint] = []
    var layoutTranslatesAutoresizingMaskIntoConstraints: Bool = false
    var layoutAutoresizingMask: RRAutoresizingMask = .none
    var layoutAutoresizingReference: LegacyAutoresizingReference?

    var layoutIntrinsicContentSize: CGSize = CGSize(width: LegacyLayoutMetrics.noIntrinsicMetric,
                                                    height: LegacyLayoutMetrics.noIntrinsicMetric)
    var huggingPriorities: [RRLayoutAxis: RRLayoutPriority] = [:]
    var compressionPriorities: [RRLayoutAxis: RRLayoutPriority] = [:]
    var firstBaselineOffset: CGFloat?
    var lastBaselineOffset: CGFloat?

    init(frame: CGRect) {
        self.layoutFrame = frame
    }

    func layoutSetFrame(_ frame: CGRect) {
        layoutFrame = frame
        layoutSetFrameCallCount += 1
    }

    func layoutUpdateAutoresizingReference(_ reference: LegacyAutoresizingReference) {
        layoutAutoresizingReference = reference
    }

    func layoutContentHuggingPriority(for axis: RRLayoutAxis) -> RRLayoutPriority {
        return huggingPriorities[axis] ?? RRLayoutPriorityValue.defaultLow
    }

    func layoutContentCompressionResistancePriority(for axis: RRLayoutAxis) -> RRLayoutPriority {
        return compressionPriorities[axis] ?? RRLayoutPriorityValue.defaultHigh
    }

    var layoutFirstBaselineOffsetFromTop: CGFloat? {
        return firstBaselineOffset
    }

    var layoutLastBaselineOffsetFromBottom: CGFloat? {
        return lastBaselineOffset
    }

    @discardableResult
    func add(_ child: FakeLayoutItem) -> FakeLayoutItem {
        child.layoutSuperitem = self
        storedSubitems.append(child)
        return child
    }
}

// MARK: - Tests

final class LegacyLayoutEngineTests: XCTestCase {

    private let accuracy: CGFloat = 0.0001

    // MARK: Helpers

    private func makeRoot(width: CGFloat = 400, height: CGFloat = 600) -> FakeLayoutItem {
        return FakeLayoutItem(frame: CGRect(x: 0, y: 0, width: width, height: height))
    }

    @discardableResult
    private func addChild(to parent: FakeLayoutItem,
                          frame: CGRect = CGRect(x: 0, y: 0, width: 0, height: 0)) -> FakeLayoutItem {
        let child = FakeLayoutItem(frame: frame)
        parent.add(child)
        return child
    }

    @discardableResult
    private func constrain(_ item: FakeLayoutItem,
                           _ attribute: RRLayoutAttribute,
                           to other: FakeLayoutItem?,
                           _ otherAttribute: RRLayoutAttribute = .notAnAttribute,
                           relation: RRLayoutRelation = .equal,
                           multiplier: CGFloat = 1,
                           constant: CGFloat = 0,
                           priority: RRLayoutPriority = RRLayoutPriorityValue.required,
                           owner: FakeLayoutItem? = nil) -> RRLayoutConstraint {
        let constraint = RRLayoutConstraint(item: item,
                                            attribute: attribute,
                                            relatedBy: relation,
                                            toItem: other,
                                            attribute: otherAttribute,
                                            multiplier: multiplier,
                                            constant: constant)
        constraint.priority = priority
        (owner ?? item).layoutConstraints.append(constraint)
        return constraint
    }

    private func frame(of item: FakeLayoutItem, in result: LegacyLayoutResult) -> CGRect {
        guard let frame = result.frames[ObjectIdentifier(item)] else {
            XCTFail("missing frame for \(item)")
            return .zero
        }
        return frame
    }

    private func assertFrame(_ actual: CGRect,
                             _ expected: CGRect,
                             file: StaticString = #filePath,
                             line: UInt = #line) {
        XCTAssertEqual(Double(actual.origin.x), Double(expected.origin.x), accuracy: Double(accuracy),
                       "x", file: file, line: line)
        XCTAssertEqual(Double(actual.origin.y), Double(expected.origin.y), accuracy: Double(accuracy),
                       "y", file: file, line: line)
        XCTAssertEqual(Double(actual.size.width), Double(expected.size.width), accuracy: Double(accuracy),
                       "width", file: file, line: line)
        XCTAssertEqual(Double(actual.size.height), Double(expected.size.height), accuracy: Double(accuracy),
                       "height", file: file, line: line)
    }

    // MARK: Pinned edges / implicit equations

    func testPinnedEdgesProduceFrame() {
        let root = makeRoot()
        let child = addChild(to: root)
        constrain(child, .leading, to: root, .leading, constant: 10)
        constrain(child, .trailing, to: root, .trailing, constant: -30)
        constrain(child, .top, to: root, .top, constant: 20)
        constrain(child, .bottom, to: root, .bottom, constant: -40)

        let result = LegacyLayoutEngine().layout(root)
        assertFrame(frame(of: child, in: result), CGRect(x: 10, y: 20, width: 360, height: 540))

        // The root is the container: unchanged and included in the result.
        let rootFrame = CGRect(x: 0, y: 0, width: 400, height: 600)
        XCTAssertEqual(result.frames[ObjectIdentifier(root)], rootFrame)
        XCTAssertEqual(root.layoutFrame, rootFrame)

        // resolvedAttributes agrees with the written frame.
        let resolved = result.resolvedAttributes[ObjectIdentifier(child)]
        XCTAssertNotNil(resolved)
        XCTAssertEqual(Double(resolved!.leading), 10, accuracy: Double(accuracy))
        XCTAssertEqual(Double(resolved!.trailing), 370, accuracy: Double(accuracy))
        XCTAssertEqual(Double(resolved!.top), 20, accuracy: Double(accuracy))
        XCTAssertEqual(Double(resolved!.bottom), 560, accuracy: Double(accuracy))
        XCTAssertEqual(Double(resolved!.width), 360, accuracy: Double(accuracy))
        XCTAssertEqual(Double(resolved!.height), 540, accuracy: Double(accuracy))
        XCTAssertEqual(Double(resolved!.centerX), 190, accuracy: Double(accuracy))
        XCTAssertEqual(Double(resolved!.centerY), 290, accuracy: Double(accuracy))
        XCTAssertTrue(result.brokenConstraints.isEmpty)
    }

    func testCenteringAlignment() {
        let root = makeRoot()
        let child = addChild(to: root)
        constrain(child, .centerX, to: root, .centerX)
        constrain(child, .centerY, to: root, .centerY)
        constrain(child, .width, to: nil, constant: 100)
        constrain(child, .height, to: nil, constant: 50)

        let result = LegacyLayoutEngine().layout(root)
        assertFrame(frame(of: child, in: result), CGRect(x: 150, y: 275, width: 100, height: 50))
    }

    // MARK: Multipliers (algebraic attribute expansion, no centering rule)

    func testAspectRatioMultiplier() {
        let root = makeRoot()
        let child = addChild(to: root)
        constrain(child, .width, to: root, .width, multiplier: 0.5)
        constrain(child, .height, to: child, .width, multiplier: 0.5)
        constrain(child, .leading, to: root, .leading)
        constrain(child, .top, to: root, .top)

        let result = LegacyLayoutEngine().layout(root)
        assertFrame(frame(of: child, in: result), CGRect(x: 0, y: 0, width: 200, height: 100))
    }

    func testProportionalPositionMultiplier() {
        let root = makeRoot()
        let child = addChild(to: root)
        // centerX == 0.5 * root.trailing => centered horizontally (LTR)
        constrain(child, .centerX, to: root, .trailing, multiplier: 0.5)
        // centerY == 0.5 * root.bottom => centered vertically
        constrain(child, .centerY, to: root, .bottom, multiplier: 0.5)
        constrain(child, .width, to: nil, constant: 100)
        constrain(child, .height, to: nil, constant: 50)

        let result = LegacyLayoutEngine().layout(root)
        assertFrame(frame(of: child, in: result), CGRect(x: 150, y: 275, width: 100, height: 50))
    }

    // MARK: Inequalities

    func testInequalitiesAreSatisfiedByPriority() {
        let root = makeRoot()
        let child = addChild(to: root)
        constrain(child, .leading, to: root, .leading)
        constrain(child, .top, to: root, .top)
        constrain(child, .height, to: nil, constant: 50)
        // width >= 150 @ 750 beats width <= 100 @ 250.
        constrain(child, .width, to: nil, relation: .greaterThanOrEqual, constant: 150,
                  priority: RRLayoutPriorityValue.defaultHigh)
        constrain(child, .width, to: nil, relation: .lessThanOrEqual, constant: 100,
                  priority: RRLayoutPriorityValue.defaultLow)

        let result = LegacyLayoutEngine().layout(root)
        let childFrame = frame(of: child, in: result)
        XCTAssertEqual(Double(childFrame.width), 150, accuracy: Double(accuracy))
        XCTAssertTrue(result.brokenConstraints.isEmpty)
    }

    // MARK: Priorities

    func testHighPriorityWinsOverLowPriority() {
        let root = makeRoot()
        let child = addChild(to: root)
        constrain(child, .leading, to: root, .leading)
        constrain(child, .top, to: root, .top)
        constrain(child, .height, to: nil, constant: 50)
        constrain(child, .width, to: nil, constant: 100, priority: RRLayoutPriorityValue.defaultHigh)
        constrain(child, .width, to: nil, constant: 200, priority: RRLayoutPriorityValue.defaultLow)

        let result = LegacyLayoutEngine().layout(root)
        XCTAssertEqual(Double(frame(of: child, in: result).width), 100, accuracy: Double(accuracy))
        XCTAssertTrue(result.brokenConstraints.isEmpty)
    }

    func testPriorityOrderDoesNotChangeWinner() {
        let root = makeRoot()
        let child = addChild(to: root)
        constrain(child, .leading, to: root, .leading)
        constrain(child, .top, to: root, .top)
        constrain(child, .height, to: nil, constant: 50)
        // Low priority added first: the higher priority must still win.
        constrain(child, .width, to: nil, constant: 200, priority: RRLayoutPriorityValue.defaultLow)
        constrain(child, .width, to: nil, constant: 100, priority: RRLayoutPriorityValue.defaultHigh)

        let result = LegacyLayoutEngine().layout(root)
        XCTAssertEqual(Double(frame(of: child, in: result).width), 100, accuracy: Double(accuracy))
    }

    func testRequiredBeatsOptional() {
        let root = makeRoot()
        let child = addChild(to: root)
        constrain(child, .leading, to: root, .leading)
        constrain(child, .top, to: root, .top)
        constrain(child, .height, to: nil, constant: 50)
        constrain(child, .width, to: nil, constant: 300)
        constrain(child, .width, to: nil, constant: 100, priority: RRLayoutPriorityValue.defaultHigh)

        let result = LegacyLayoutEngine().layout(root)
        XCTAssertEqual(Double(frame(of: child, in: result).width), 300, accuracy: Double(accuracy))
        XCTAssertTrue(result.brokenConstraints.isEmpty)
    }

    func testZeroPriorityIsWeakest() {
        let root = makeRoot()
        let child = addChild(to: root)
        constrain(child, .leading, to: root, .leading)
        constrain(child, .top, to: root, .top)
        constrain(child, .height, to: nil, constant: 50)
        constrain(child, .width, to: nil, constant: 100, priority: RRLayoutPriorityValue.defaultLow)
        constrain(child, .width, to: nil, constant: 10, priority: 0)

        let result = LegacyLayoutEngine().layout(root)
        XCTAssertEqual(Double(frame(of: child, in: result).width), 100, accuracy: Double(accuracy))
    }

    // MARK: Intrinsic content size (hugging / compression resistance)

    func testIntrinsicSizeHugsContent() {
        let root = makeRoot()
        let child = addChild(to: root)
        child.layoutIntrinsicContentSize = CGSize(width: 80, height: 40)
        constrain(child, .leading, to: root, .leading, constant: 10)
        constrain(child, .top, to: root, .top, constant: 10)

        let result = LegacyLayoutEngine().layout(root)
        assertFrame(frame(of: child, in: result), CGRect(x: 10, y: 10, width: 80, height: 40))
    }

    func testCompressionResistanceLosesToRequiredSize() {
        let root = makeRoot()
        let child = addChild(to: root)
        child.layoutIntrinsicContentSize = CGSize(width: 80, height: 40)
        // Required container edges force a size larger than the intrinsic one.
        constrain(child, .leading, to: root, .leading, constant: 10)
        constrain(child, .trailing, to: root, .trailing, constant: -10)
        constrain(child, .top, to: root, .top, constant: 10)
        constrain(child, .bottom, to: root, .bottom, constant: -10)

        let result = LegacyLayoutEngine().layout(root)
        assertFrame(frame(of: child, in: result), CGRect(x: 10, y: 10, width: 380, height: 580))
    }

    func testCustomHuggingPriorityWinsOverUserOptionalWidth() {
        let root = makeRoot()
        let child = addChild(to: root)
        child.layoutIntrinsicContentSize = CGSize(width: 80, height: 40)
        child.huggingPriorities[.horizontal] = 900
        constrain(child, .leading, to: root, .leading)
        constrain(child, .top, to: root, .top)
        constrain(child, .height, to: nil, constant: 40)
        constrain(child, .width, to: nil, constant: 100, priority: 500)

        let result = LegacyLayoutEngine().layout(root)
        XCTAssertEqual(Double(frame(of: child, in: result).width), 80, accuracy: Double(accuracy))
    }

    // MARK: Autoresizing masks (spec §3.1)

    func testAutoresizingNonePinsCurrentFrameAndUpdatesReference() {
        let root = makeRoot()
        let child = addChild(to: root, frame: CGRect(x: 10, y: 20, width: 100, height: 50))
        child.layoutTranslatesAutoresizingMaskIntoConstraints = true
        child.layoutAutoresizingMask = .none

        let result = LegacyLayoutEngine().layout(root)
        assertFrame(frame(of: child, in: result), CGRect(x: 10, y: 20, width: 100, height: 50))
        XCTAssertEqual(child.layoutSetFrameCallCount, 1)
        let reference = child.layoutAutoresizingReference
        XCTAssertNotNil(reference)
        assertFrame(reference!.frame, CGRect(x: 10, y: 20, width: 100, height: 50))
        XCTAssertEqual(Double(reference!.superviewSize.width), 400, accuracy: Double(accuracy))
        XCTAssertEqual(Double(reference!.superviewSize.height), 600, accuracy: Double(accuracy))
    }

    func testAutoresizingFlexibleWidthOnSuperviewResize() {
        let root = makeRoot()
        let child = addChild(to: root, frame: CGRect(x: 10, y: 20, width: 100, height: 50))
        child.layoutTranslatesAutoresizingMaskIntoConstraints = true
        child.layoutAutoresizingMask = .flexibleWidth

        let engine = LegacyLayoutEngine()
        engine.layout(root)
        assertFrame(child.layoutFrame, CGRect(x: 10, y: 20, width: 100, height: 50))

        // Grow the container: the trailing gap (290) stays fixed, width grows.
        root.layoutFrame = CGRect(x: 0, y: 0, width: 500, height: 600)
        engine.layout(root)
        assertFrame(child.layoutFrame, CGRect(x: 10, y: 20, width: 200, height: 50))
        XCTAssertEqual(Double(child.layoutAutoresizingReference!.superviewSize.width), 500,
                       accuracy: Double(accuracy))
    }

    func testAutoresizingFlexibleLeftMarginOnSuperviewResize() {
        let root = makeRoot()
        let child = addChild(to: root, frame: CGRect(x: 10, y: 20, width: 100, height: 50))
        child.layoutTranslatesAutoresizingMaskIntoConstraints = true
        child.layoutAutoresizingMask = .flexibleLeftMargin

        let engine = LegacyLayoutEngine()
        engine.layout(root)
        assertFrame(child.layoutFrame, CGRect(x: 10, y: 20, width: 100, height: 50))

        root.layoutFrame = CGRect(x: 0, y: 0, width: 500, height: 600)
        engine.layout(root)
        // Width and the right gap stay fixed; the item slides right.
        assertFrame(child.layoutFrame, CGRect(x: 110, y: 20, width: 100, height: 50))
    }

    func testAutoresizingProportionalMarginsOnSuperviewResize() {
        let root = makeRoot()
        let child = addChild(to: root, frame: CGRect(x: 10, y: 20, width: 100, height: 50))
        child.layoutTranslatesAutoresizingMaskIntoConstraints = true
        child.layoutAutoresizingMask = [.flexibleLeftMargin, .flexibleRightMargin]

        let engine = LegacyLayoutEngine()
        engine.layout(root)
        assertFrame(child.layoutFrame, CGRect(x: 10, y: 20, width: 100, height: 50))

        root.layoutFrame = CGRect(x: 0, y: 0, width: 500, height: 600)
        engine.layout(root)
        // x = r * W - r * w with r = x0 / (W0 - w0) = 10 / 300.
        let expectedX = (10.0 / 300.0) * 500.0 - (10.0 / 300.0) * 100.0
        assertFrame(child.layoutFrame, CGRect(x: expectedX, y: 20, width: 100, height: 50))
    }

    func testAutoresizingFlexibleHeightOnSuperviewResize() {
        let root = makeRoot()
        let child = addChild(to: root, frame: CGRect(x: 10, y: 20, width: 100, height: 50))
        child.layoutTranslatesAutoresizingMaskIntoConstraints = true
        child.layoutAutoresizingMask = .flexibleHeight

        let engine = LegacyLayoutEngine()
        engine.layout(root)
        assertFrame(child.layoutFrame, CGRect(x: 10, y: 20, width: 100, height: 50))

        root.layoutFrame = CGRect(x: 0, y: 0, width: 400, height: 700)
        engine.layout(root)
        // Bottom gap stays at 600 - 70 = 530 -> height = 700 - 20 - 530 = 150.
        assertFrame(child.layoutFrame, CGRect(x: 10, y: 20, width: 100, height: 150))
    }

    func testAutoresizingConstraintBeatsExplicitRequiredWidth() {
        let root = makeRoot()
        let child = addChild(to: root, frame: CGRect(x: 10, y: 20, width: 100, height: 50))
        child.layoutTranslatesAutoresizingMaskIntoConstraints = true
        child.layoutAutoresizingMask = .none
        // The autoresizing width (100) wins; the explicit required width is broken.
        let explicit = constrain(child, .width, to: nil, constant: 300)

        let result = LegacyLayoutEngine().layout(root)
        XCTAssertEqual(Double(frame(of: child, in: result).width), 100, accuracy: Double(accuracy))
        XCTAssertEqual(result.brokenConstraints.count, 1)
        XCTAssertTrue(result.brokenConstraints.first === explicit)
    }

    // MARK: RTL

    func testRTLDirectionMirrorsLeadingAndTrailingConstants() {
        func frames(direction: RRLayoutDirection) -> (ltr: CGRect, rtl: CGRect) {
            let root = makeRoot()
            let child = addChild(to: root)
            constrain(child, .leading, to: root, .leading, constant: 10)
            constrain(child, .trailing, to: root, .trailing, constant: -20)
            constrain(child, .top, to: root, .top, constant: 10)
            constrain(child, .height, to: nil, constant: 50)
            let engine = LegacyLayoutEngine(direction: direction)
            let result = engine.layout(root)
            return (frame(of: child, in: result), frame(of: child, in: result))
        }

        // LTR: leading edge inset 10, trailing edge inset 20.
        let ltrResult = frames(direction: .leftToRight).ltr
        assertFrame(ltrResult, CGRect(x: 10, y: 10, width: 370, height: 50))

        // RTL (verified against UIKit): right inset 10, left inset 20.
        let rtlResult = frames(direction: .rightToLeft).rtl
        assertFrame(rtlResult, CGRect(x: 20, y: 10, width: 370, height: 50))
    }

    func testRTLMixedLeadingCenterXPairing() {
        func childFrame(direction: RRLayoutDirection) -> CGRect {
            let root = makeRoot()
            let child = addChild(to: root)
            constrain(child, .leading, to: root, .centerX, constant: 10)
            constrain(child, .width, to: nil, constant: 100)
            constrain(child, .top, to: root, .top)
            constrain(child, .height, to: nil, constant: 10)
            let engine = LegacyLayoutEngine(direction: direction)
            let result = engine.layout(root)
            return frame(of: child, in: result)
        }

        // LTR: minX = root.centerX + 10 = 210.
        assertFrame(childFrame(direction: .leftToRight),
                    CGRect(x: 210, y: 0, width: 100, height: 10))
        // RTL (verified against UIKit): maxX = root.centerX - 10 = 190 -> x = 90.
        assertFrame(childFrame(direction: .rightToLeft),
                    CGRect(x: 90, y: 0, width: 100, height: 10))
    }

    func testRTLLeadingTrailingPairing() {
        let root = makeRoot()
        let child = addChild(to: root)
        constrain(child, .leading, to: root, .trailing, constant: 10)
        constrain(child, .width, to: nil, constant: 100)
        constrain(child, .top, to: root, .top)
        constrain(child, .height, to: nil, constant: 10)
        let engine = LegacyLayoutEngine(direction: .rightToLeft)
        let result = engine.layout(root)
        // RTL: maxX = root.minX - 10 = -10 -> x = -110.
        assertFrame(frame(of: child, in: result), CGRect(x: -110, y: 0, width: 100, height: 10))
    }

    func testRTLRequiredInequalityReversesAndWins() {
        // Requires a.leading >= container.leading + 40 under RTL, i.e.
        // a.maxX <= container.maxX - 40; the optional @750 equality wants
        // a.maxX == container.maxX, so the required inequality must win.
        let root = makeRoot(width: 320, height: 480)
        let child = addChild(to: root)
        constrain(child, .width, to: nil, constant: 100)
        constrain(child, .height, to: nil, constant: 50)
        constrain(child, .top, to: root, .top, constant: 10)
        constrain(child, .leading, to: root, .leading,
                  relation: .greaterThanOrEqual, constant: 40)
        constrain(child, .leading, to: root, .leading, constant: 0,
                  priority: RRLayoutPriorityValue.defaultHigh)

        let engine = LegacyLayoutEngine(direction: .rightToLeft)
        let result = engine.layout(root)
        // right edge = 280 = 320 - 40.
        assertFrame(frame(of: child, in: result), CGRect(x: 180, y: 10, width: 100, height: 50))
    }

    func testLTRRequiredInequalityCounterpart() {
        let root = makeRoot(width: 320, height: 480)
        let child = addChild(to: root)
        constrain(child, .width, to: nil, constant: 100)
        constrain(child, .height, to: nil, constant: 50)
        constrain(child, .top, to: root, .top, constant: 10)
        constrain(child, .leading, to: root, .leading,
                  relation: .greaterThanOrEqual, constant: 40)
        constrain(child, .leading, to: root, .leading, constant: 0,
                  priority: RRLayoutPriorityValue.defaultHigh)

        let result = LegacyLayoutEngine(direction: .leftToRight).layout(root)
        assertFrame(frame(of: child, in: result), CGRect(x: 40, y: 10, width: 100, height: 50))
    }

    func testRTLMixedDirectionalInequalityReverses() {
        // required a.leading >= root.centerX + 10 -> RTL a.maxX <= 200 - 10 = 190;
        // the optional equality wants a.maxX == 200 + 200 = 400, so the required
        // bound wins and the item sits at x = 90.
        let root = makeRoot()
        let child = addChild(to: root)
        constrain(child, .width, to: nil, constant: 100)
        constrain(child, .height, to: nil, constant: 50)
        constrain(child, .top, to: root, .top)
        constrain(child, .leading, to: root, .centerX,
                  relation: .greaterThanOrEqual, constant: 10)
        constrain(child, .leading, to: root, .centerX, constant: -200,
                  priority: RRLayoutPriorityValue.defaultHigh)

        let engine = LegacyLayoutEngine(direction: .rightToLeft)
        let result = engine.layout(root)
        assertFrame(frame(of: child, in: result), CGRect(x: 90, y: 0, width: 100, height: 50))
    }

    func testRTLOptionalDirectionalInequalityDoesNotOverrideRequiredEquality() {
        let root = makeRoot()
        let child = addChild(to: root)
        constrain(child, .width, to: nil, constant: 100)
        constrain(child, .height, to: nil, constant: 50)
        constrain(child, .top, to: root, .top)
        // required: RTL a.leading == root.leading + 10 -> a.maxX == 400 - 10 = 390.
        constrain(child, .leading, to: root, .leading, constant: 10)
        // optional inequality would move maxX to >= 420; it cannot beat required.
        constrain(child, .leading, to: root, .leading,
                  relation: .lessThanOrEqual, constant: -20,
                  priority: RRLayoutPriorityValue.defaultHigh)

        let engine = LegacyLayoutEngine(direction: .rightToLeft)
        let result = engine.layout(root)
        // required equality keeps maxX = 400 - 10 = 390 -> x = 290.
        assertFrame(frame(of: child, in: result), CGRect(x: 290, y: 0, width: 100, height: 50))
    }

    func testLTRDirectionPropertyCanBeChanged() {
        let root = makeRoot()
        let child = addChild(to: root)
        constrain(child, .leading, to: root, .leading)
        constrain(child, .width, to: nil, constant: 100)
        constrain(child, .top, to: root, .top)
        constrain(child, .height, to: nil, constant: 10)

        let engine = LegacyLayoutEngine()
        XCTAssertEqual(engine.direction, .leftToRight)
        var result = engine.layout(root)
        XCTAssertEqual(Double(frame(of: child, in: result).minX), 0, accuracy: Double(accuracy))

        engine.direction = .rightToLeft
        result = engine.layout(root)
        XCTAssertEqual(Double(frame(of: child, in: result).maxX), 400, accuracy: Double(accuracy))
    }

    // MARK: Broken constraints

    func testBrokenRequiredConstraintIsRecordedAndLayoutContinues() {
        let root = makeRoot()
        let child = addChild(to: root)
        constrain(child, .leading, to: root, .leading)
        constrain(child, .top, to: root, .top)
        constrain(child, .height, to: nil, constant: 50)
        constrain(child, .width, to: nil, constant: 100)
        let conflicting = constrain(child, .width, to: nil, constant: 200)

        let result = LegacyLayoutEngine().layout(root)
        // The first required width wins; the second is recorded as broken.
        XCTAssertEqual(Double(frame(of: child, in: result).width), 100, accuracy: Double(accuracy))
        XCTAssertEqual(result.brokenConstraints.count, 1)
        XCTAssertTrue(result.brokenConstraints.first === conflicting)
    }

    // MARK: Baselines

    func testSupportedBaselineConstraintIsSolved() {
        let root = makeRoot()
        let child = addChild(to: root)
        child.lastBaselineOffset = 5
        constrain(child, .height, to: nil, constant: 40)
        constrain(child, .leading, to: root, .leading)
        // lastBaseline = minY + height - offset = minY + 35.
        constrain(child, .lastBaseline, to: root, .top, constant: 100)

        let result = LegacyLayoutEngine().layout(root)
        XCTAssertEqual(Double(frame(of: child, in: result).minY), 65, accuracy: Double(accuracy))
        let resolved = result.resolvedAttributes[ObjectIdentifier(child)]
        XCTAssertEqual(Double(resolved!.lastBaseline), 100, accuracy: Double(accuracy))
    }

    func testFirstBaselineConstraintIsSolved() {
        let root = makeRoot()
        root.firstBaselineOffset = 10
        let child = addChild(to: root)
        child.firstBaselineOffset = 2
        constrain(child, .height, to: nil, constant: 40)
        constrain(child, .leading, to: root, .leading)
        // firstBaseline only pairs with firstBaseline; root's is pinned at 10.
        constrain(child, .firstBaseline, to: root, .firstBaseline)
        constrain(child, .top, to: root, .top)

        let result = LegacyLayoutEngine().layout(root)
        XCTAssertEqual(Double(frame(of: child, in: result).minY), 8, accuracy: Double(accuracy))
        let resolved = result.resolvedAttributes[ObjectIdentifier(child)]
        XCTAssertEqual(Double(resolved!.firstBaseline), 10, accuracy: Double(accuracy))
    }

    func testUnsupportedBaselineIsRecordedAsBroken() {
        let root = makeRoot()
        let child = addChild(to: root)
        // No baseline provider on this item: plain UIView has no baseline.
        let baselineConstraint = constrain(child, .lastBaseline, to: root, .top, constant: 100)
        constrain(child, .leading, to: root, .leading)
        constrain(child, .top, to: root, .top)
        constrain(child, .width, to: nil, constant: 10)
        constrain(child, .height, to: nil, constant: 10)

        let result = LegacyLayoutEngine().layout(root)
        XCTAssertEqual(result.brokenConstraints.count, 1)
        XCTAssertTrue(result.brokenConstraints.first === baselineConstraint)
        // Layout still proceeds.
        assertFrame(frame(of: child, in: result), CGRect(x: 0, y: 0, width: 10, height: 10))
    }

    // MARK: Coordinate space / nested trees

    func testNestedFramesAreWrittenInSuperitemCoordinates() {
        let root = makeRoot(width: 320, height: 480)
        let outer = addChild(to: root)
        constrain(outer, .leading, to: root, .leading, constant: 10)
        constrain(outer, .trailing, to: root, .trailing, constant: -10)
        constrain(outer, .top, to: root, .top, constant: 20)
        constrain(outer, .bottom, to: root, .bottom, constant: -20)

        let inner = addChild(to: outer)
        constrain(inner, .leading, to: outer, .leading, constant: 5)
        constrain(inner, .trailing, to: outer, .trailing, constant: -5)
        constrain(inner, .top, to: outer, .top, constant: 5)
        constrain(inner, .bottom, to: outer, .bottom, constant: -5)

        let grandchild = addChild(to: inner)
        constrain(grandchild, .centerX, to: inner, .centerX)
        constrain(grandchild, .centerY, to: inner, .centerY)
        constrain(grandchild, .width, to: nil, constant: 50)
        constrain(grandchild, .height, to: nil, constant: 30)

        let result = LegacyLayoutEngine().layout(root)
        assertFrame(frame(of: outer, in: result), CGRect(x: 10, y: 20, width: 300, height: 440))
        // inner's frame is relative to outer, not the window: (5, 5), not (15, 25).
        assertFrame(frame(of: inner, in: result), CGRect(x: 5, y: 5, width: 290, height: 430))
        // grandchild is centered in inner's own coordinate space.
        assertFrame(frame(of: grandchild, in: result),
                    CGRect(x: 120, y: 200, width: 50, height: 30))
    }

    // MARK: Stays (stability across per-view passes)

    func testStaysPreserveAncestorDerivedGeometryAcrossSubtreePasses() {
        let root = makeRoot(width: 400, height: 600)
        let outer = addChild(to: root)
        constrain(outer, .leading, to: root, .leading, constant: 20)
        constrain(outer, .trailing, to: root, .trailing, constant: -20)
        constrain(outer, .top, to: root, .top, constant: 20)
        constrain(outer, .bottom, to: root, .bottom, constant: -20)

        let grandchild = addChild(to: outer)
        constrain(grandchild, .centerX, to: outer, .centerX)
        constrain(grandchild, .centerY, to: outer, .centerY)
        constrain(grandchild, .height, to: nil, constant: 50)
        // Ancestor-owned constraint: only available when the pass is rooted at root.
        constrain(grandchild, .width, to: root, .width, multiplier: 0.5, owner: root)

        let engine = LegacyLayoutEngine()
        let fullPass = engine.layout(root)
        let expected = frame(of: grandchild, in: fullPass)
        XCTAssertEqual(Double(expected.width), 200, accuracy: Double(accuracy))

        // Now run the per-view pass rooted at the intermediate view. The width
        // constraint is not part of this subtree; the stay keeps the solved width
        // instead of collapsing the item to zero.
        let intermediatePass = engine.layout(outer)
        let preserved = frame(of: grandchild, in: intermediatePass)
        assertFrame(preserved, expected)

        // And the pass is idempotent.
        let repeated = engine.layout(outer)
        assertFrame(frame(of: grandchild, in: repeated), expected)
        assertFrame(grandchild.layoutFrame, expected)
    }

    // MARK: solve() vs layout()

    func testSolveDoesNotWriteFramesAndMatchesLayout() {
        let root = makeRoot()
        let child = addChild(to: root)
        constrain(child, .leading, to: root, .leading, constant: 10)
        constrain(child, .trailing, to: root, .trailing, constant: -30)
        constrain(child, .top, to: root, .top, constant: 20)
        constrain(child, .bottom, to: root, .bottom, constant: -40)

        let engine = LegacyLayoutEngine()
        let solved = engine.solve(root)
        XCTAssertEqual(child.layoutSetFrameCallCount, 0)
        XCTAssertEqual(child.layoutFrame, CGRect(x: 0, y: 0, width: 0, height: 0))
        let solvedFrame = frame(of: child, in: solved)
        assertFrame(solvedFrame, CGRect(x: 10, y: 20, width: 360, height: 540))

        let applied = engine.layout(root)
        XCTAssertEqual(child.layoutSetFrameCallCount, 1)
        assertFrame(child.layoutFrame, solvedFrame)
        assertFrame(frame(of: child, in: applied), solvedFrame)
    }

    // MARK: Constraint storage: ancestor-owned, outside-subtree, activation

    func testAncestorOwnedConstraintIsCollected() {
        let root = makeRoot()
        let child = addChild(to: root)
        // Constraint stored on the root, not on the child (closest common ancestor).
        constrain(child, .leading, to: root, .leading, constant: 10, owner: root)
        constrain(child, .top, to: root, .top, constant: 10, owner: root)
        constrain(child, .width, to: nil, constant: 100, owner: root)
        constrain(child, .height, to: nil, constant: 50, owner: root)

        let result = LegacyLayoutEngine().layout(root)
        assertFrame(frame(of: child, in: result), CGRect(x: 10, y: 10, width: 100, height: 50))
    }

    func testConstraintReferencingOutsideSubtreeIsSkipped() {
        let root = makeRoot()
        let child = addChild(to: root)
        child.layoutFrame = CGRect(x: 7, y: 9, width: 11, height: 13)
        let outside = FakeLayoutItem(frame: CGRect(x: 100, y: 100, width: 20, height: 20))
        constrain(child, .leading, to: outside, .leading)
        constrain(child, .top, to: outside, .top)

        let result = LegacyLayoutEngine().layout(root)
        // Skipped silently (it belongs to an ancestor's pass) and the weak stays
        // keep the incumbent geometry.
        XCTAssertTrue(result.brokenConstraints.isEmpty)
        assertFrame(frame(of: child, in: result), CGRect(x: 7, y: 9, width: 11, height: 13))
    }

    func testActivatedConstraintIsVisibleToTheEngine() {
        let root = makeRoot()
        let child = addChild(to: root)
        let leading = RRLayoutConstraint(item: child, attribute: .leading,
                                         relatedBy: .equal, toItem: root,
                                         attribute: .leading, multiplier: 1, constant: 10)
        let width = RRLayoutConstraint(item: child, attribute: .width,
                                       relatedBy: .equal, toItem: nil,
                                       attribute: .notAnAttribute, multiplier: 1, constant: 100)
        let height = RRLayoutConstraint(item: child, attribute: .height,
                                        relatedBy: .equal, toItem: nil,
                                        attribute: .notAnAttribute, multiplier: 1, constant: 50)
        RRLayoutConstraint.legacyActivate([leading, width, height])
        defer { RRLayoutConstraint.legacyDeactivate([leading, width, height]) }

        let engine = LegacyLayoutEngine()
        var result = engine.layout(root)
        assertFrame(frame(of: child, in: result), CGRect(x: 10, y: 0, width: 100, height: 50))

        // Deactivating removes them from the engine's world; the stays keep the
        // previously solved geometry (no collapse).
        RRLayoutConstraint.legacyDeactivate([leading, width, height])
        let previous = child.layoutFrame
        result = engine.layout(root)
        assertFrame(frame(of: child, in: result), previous)
    }

    // MARK: Degenerate inputs

    func testEmptySubtreeReturnsRootOnly() {
        let root = makeRoot()
        let result = LegacyLayoutEngine().layout(root)
        XCTAssertEqual(result.frames.count, 1)
        XCTAssertEqual(result.frames[ObjectIdentifier(root)], root.layoutFrame)
        XCTAssertTrue(result.brokenConstraints.isEmpty)
        XCTAssertEqual(root.layoutSetFrameCallCount, 0)
    }

    func testRepeatedLayoutIsIdempotent() {
        let root = makeRoot()
        let child = addChild(to: root)
        constrain(child, .leading, to: root, .leading, constant: 10)
        constrain(child, .trailing, to: root, .trailing, constant: -10)
        constrain(child, .top, to: root, .top, constant: 10)
        constrain(child, .bottom, to: root, .bottom, constant: -10)

        let engine = LegacyLayoutEngine()
        let first = engine.layout(root)
        let firstFrame = frame(of: child, in: first)
        let second = engine.layout(root)
        let secondFrame = frame(of: child, in: second)

        assertFrame(firstFrame, CGRect(x: 10, y: 10, width: 380, height: 580))
        assertFrame(secondFrame, firstFrame)
        XCTAssertEqual(child.layoutSetFrameCallCount, 2)
    }
}
