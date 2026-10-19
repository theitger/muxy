import AppKit
import SwiftUI

/// An icon by the SF Symbol name muxy always used, drawn as its Lucide
/// counterpart (see Lucide): outlined, 2pt strokes at 24pt, round ends.
/// `size` is the font size the symbol was set at; the icon's box is a
/// little larger, where a symbol of that size would sit. Names without a
/// Lucide counterpart stay SF Symbols.
struct Icon: View {
    let name: String
    var size: CGFloat = 12

    init(_ name: String, size: CGFloat = 12) {
        self.name = name
        self.size = size
    }

    var body: some View {
        if let image = Lucide.image(name, small: size < 11) {
            Image(nsImage: image)
                .renderingMode(.template)
                .resizable()
                .interpolation(.high)
                .frame(width: (size * 1.25).rounded(), height: (size * 1.25).rounded())
                .accessibilityHidden(true)
        } else {
            Image(systemName: name)
                .font(.system(size: size, weight: .medium))
        }
    }
}

extension Lucide {
    private static let cache = NSCache<NSString, NSImage>()

    /// The icon as a template image; thicker strokes when drawn small, so
    /// it doesn't fade next to text.
    static func image(_ name: String, small: Bool) -> NSImage? {
        let key = "\(name)|\(small)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        guard let icon = icons[name] else { return nil }
        let solid = filled.contains(name)
        let svg = """
        <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" \
        fill="\(solid ? "black" : "none")" stroke="black" stroke-width="\(small ? 2.4 : 2)" \
        stroke-linecap="round" stroke-linejoin="round">\(icon.body)</svg>
        """
        guard let image = NSImage(data: Data(svg.utf8)) else { return nil }
        image.isTemplate = true
        cache.setObject(image, forKey: key)
        return image
    }
}
