import SwiftUI

public struct Wordmark: View {
    @Environment(\.theme) private var theme
    public var height: CGFloat

    public init(height: CGFloat = 22) {
        self.height = height
    }

    public var body: some View {
        Image(theme.dark ? "WordmarkDark" : "WordmarkLight", bundle: .module)
            .resizable()
            .scaledToFit()
            .frame(height: height)
            .accessibilityLabel("Odete")
    }
}

public struct BrandIcon: View {
    public var size: CGFloat
    public init(size: CGFloat = 32) {
        self.size = size
    }

    public var body: some View {
        Image("OdeteIcon", bundle: .module)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
            .accessibilityHidden(true)
    }
}
