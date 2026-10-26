//
//  RRLayoutAttribute.swift
//  LegacyAutoLayout
//
//  Swift port of `RRLayoutAttribute` from RRAutoLayout.
//
//  RRAutoLayout
//  Copyright (c) 2012 Rolandas Razma <rolandas@razma.lt>
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in
//  all copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
//  SOFTWARE.
//
//  Differences from upstream:
//  * Raw values are identical to `NSLayoutConstraint.Attribute` (a.k.a.
//    `NSLayoutAttribute`), not to RRAutoLayout's `RRLayoutAttribute`. Upstream
//    stopped at `RRLayoutAttributeBaseline` (11) and had the constants in a
//    different order; UIKit's enum is:
//
//        notAnAttribute = 0, left = 1, right = 2, top = 3, bottom = 4,
//        leading = 5, trailing = 6, width = 7, height = 8,
//        centerX = 9, centerY = 10, lastBaseline = 11, firstBaseline = 12
//
//    Matching UIKit exactly is required for NIB/NSKeyedArchiver compatibility:
//    archived `NSLayoutConstraint`s store the attribute as an integer
//    (`NSFirstAttribute` / `NSSecondAttribute`), so decoding an iOS 6-era
//    archive only round-trips if the raw values match.
//  * `RRLayoutAttributeBaseline` from upstream corresponds to UIKit's
//    `lastBaseline` (11). `firstBaseline` (12) was added by UIKit later; the
//    engine supports it because the legacy item protocol exposes a first-baseline
//    offset.
//

import Foundation

/// The attribute of a layout item that a constraint refers to.
///
/// Mirrors `NSLayoutConstraint.Attribute` / `NSLayoutAttribute` one-to-one,
/// including raw values. See `RRLayoutConstraint`.
public enum RRLayoutAttribute: Int, Hashable, CaseIterable {

    /// The constraint does not refer to an attribute of the second item; used
    /// for constant constraints such as `width == 100`.
    case notAnAttribute = 0

    case left = 1
    case right = 2
    case top = 3
    case bottom = 4
    case leading = 5
    case trailing = 6
    case width = 7
    case height = 8
    case centerX = 9
    case centerY = 10
    case lastBaseline = 11
    case firstBaseline = 12

    // MARK: Classification

    /// `true` for the two size attributes (`width`, `height`).
    public var isSizeAttribute: Bool {
        return self == .width || self == .height
    }

    /// `true` for every attribute that describes a position on an item rather
    /// than its size. Baselines are positions on the vertical axis.
    public var isPositionAttribute: Bool {
        return self != .notAnAttribute && !isSizeAttribute
    }

    /// `true` for `firstBaseline` and `lastBaseline`.
    public var isBaselineAttribute: Bool {
        return self == .firstBaseline || self == .lastBaseline
    }

    /// The axis the attribute lives on, or `nil` for `notAnAttribute`.
    ///
    /// Horizontal attributes: left/right/leading/trailing/width/centerX.
    /// Vertical attributes: top/bottom/height/centerY/firstBaseline/lastBaseline.
    public var axis: RRLayoutAxis? {
        switch self {
        case .notAnAttribute:
            return nil
        case .left, .right, .leading, .trailing, .width, .centerX:
            return .horizontal
        case .top, .bottom, .height, .centerY, .firstBaseline, .lastBaseline:
            return .vertical
        }
    }
}
