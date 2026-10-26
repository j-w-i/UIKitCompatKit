//
//  RRLayoutRelation.swift
//  LegacyAutoLayout
//
//  Swift port of `RRLayoutRelation` from RRAutoLayout.
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
//  The raw values are identical to `NSLayoutRelation` / `NSLayoutConstraint.Relation`
//  (`lessThanOrEqual = -1`, `equal = 0`, `greaterThanOrEqual = 1`) so those values
//  round-trip through NSCoder and through `NSRelation` in Interface Builder
//  archives.
//

import Foundation

/// The relational operator of a layout constraint.
///
/// Mirrors `NSLayoutConstraint.Relation` / `NSLayoutRelation` exactly, including
/// raw values, for NIB/archive compatibility.
public enum RRLayoutRelation: Int, Hashable, CaseIterable {
    /// `firstAttribute <= multiplier * secondAttribute + constant`
    case lessThanOrEqual = -1
    /// `firstAttribute == multiplier * secondAttribute + constant`
    case equal = 0
    /// `firstAttribute >= multiplier * secondAttribute + constant`
    case greaterThanOrEqual = 1
}
