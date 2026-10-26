import UIKit

// MARK: - UIFont.Weight Shim for iOS <8.2
@available(iOS, introduced: 6.0, deprecated: 8.2)
public enum Weight: Equatable {
    case ultraLight, thin, light, regular, medium, semibold, bold, heavy, black
}


// MARK: - UIFontWeight Alias
@available(iOS, introduced: 6.0, deprecated: 8.2)
public typealias UIFontWeight = Weight

// MARK: - UIFont Extensions
extension UIFont {

    @available(iOS, introduced: 6.0, deprecated: 8.2)
    @_disfavoredOverload
    public static func systemFont(ofSize size: CGFloat, weight: UIFontWeight) -> UIFont {
        switch weight {
        case .ultraLight:
            return UIFont(name: "HelveticaNeue-UltraLight", size: size) ?? UIFont.systemFont(ofSize: size)
        case .thin:
            return UIFont(name: "HelveticaNeue-Thin", size: size) ?? UIFont.systemFont(ofSize: size)
        case .light:
            return UIFont(name: "HelveticaNeue-Light", size: size) ?? UIFont.systemFont(ofSize: size)
        case .regular:
            return UIFont.systemFont(ofSize: size)
        case .medium:
            return UIFont(name: "HelveticaNeue-Medium", size: size) ?? UIFont.boldSystemFont(ofSize: size)
        case .semibold:
            return UIFont(name: "HelveticaNeue-Bold", size: size) ?? UIFont.boldSystemFont(ofSize: size)
        case .bold, .heavy, .black:
            return UIFont.boldSystemFont(ofSize: size)
        }
    }

    @available(iOS, introduced: 6.0, deprecated: 13.0)
    @_disfavoredOverload
    public static func monospacedSystemFont(ofSize size: CGFloat, weight: UIFontWeight) -> UIFont {
        switch weight {
        case .ultraLight, .thin, .light, .regular:
            return UIFont(name: "Courier", size: size) ?? UIFont.systemFont(ofSize: size)
        case .medium, .semibold, .bold, .heavy, .black:
            return UIFont(name: "Courier-Bold", size: size) ?? UIFont.boldSystemFont(ofSize: size)
        }
    }
}
