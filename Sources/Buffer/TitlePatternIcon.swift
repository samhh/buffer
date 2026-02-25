import SwiftUI

enum TitlePatternKind: Int, CaseIterable {
    case vertical
    case horizontal
    case diagonalDown
    case diagonalUp
    case radialCorner
}

struct TitlePatternSpec: Equatable {
    let paletteIndex: Int
    let patternKind: TitlePatternKind
    let rotationQuarterTurns: Int
    let density: Int
    let accentMix: Int
}

enum TitlePatternGenerator {
    static let densityLevels = 3
    static let accentMixLevels = 3
    // Picker icon gradients are based on Catppuccin accents:
    // - Light mode uses Latte
    // - Dark mode uses Mocha
    // Source: https://catppuccin.com/palette/
    private static let latteAccentRing: [Color] = [
        color(hex: 0xEA76CB), // Pink
        color(hex: 0x8839EF), // Mauve
        color(hex: 0xD20F39), // Red
        color(hex: 0xE64553), // Maroon
        color(hex: 0xFE640B), // Peach
        color(hex: 0xDF8E1D), // Yellow
        color(hex: 0x40A02B), // Green
        color(hex: 0x179299), // Teal
        color(hex: 0x04A5E5), // Sky
        color(hex: 0x209FB5), // Sapphire
        color(hex: 0x1E66F5), // Blue
        color(hex: 0x7287FD), // Lavender
    ]

    private static let mochaAccentRing: [Color] = [
        color(hex: 0xF5C2E7), // Pink
        color(hex: 0xCBA6F7), // Mauve
        color(hex: 0xF38BA8), // Red
        color(hex: 0xEBA0AC), // Maroon
        color(hex: 0xFAB387), // Peach
        color(hex: 0xF9E2AF), // Yellow
        color(hex: 0xA6E3A1), // Green
        color(hex: 0x94E2D5), // Teal
        color(hex: 0x89DCEB), // Sky
        color(hex: 0x74C7EC), // Sapphire
        color(hex: 0x89B4FA), // Blue
        color(hex: 0xB4BEFE), // Lavender
    ]

    static var paletteCount: Int {
        latteAccentRing.count
    }

    static func spec(for title: String) -> TitlePatternSpec {
        let normalized = normalizedTitleKey(title)
        let hash = fnv1a64(of: normalized)
        return TitlePatternSpec(
            paletteIndex: bucket(hash, shift: 0, modulo: paletteCount),
            patternKind: TitlePatternKind.allCases[bucket(hash, shift: 12, modulo: TitlePatternKind.allCases.count)],
            rotationQuarterTurns: bucket(hash, shift: 20, modulo: 4),
            density: bucket(hash, shift: 28, modulo: densityLevels),
            accentMix: bucket(hash, shift: 36, modulo: accentMixLevels)
        )
    }

    fileprivate static func palette(for index: Int, scheme: ColorScheme, accentMix: Int) -> TitlePatternPalette {
        let ring = scheme == .dark ? mochaAccentRing : latteAccentRing
        let baseIndex = index % ring.count
        let accentOffset = [2, 5, 8][accentMix % accentMixLevels]
        let contrastOffset = 6
        return TitlePatternPalette(
            background: ring[baseIndex],
            accent: ring[(baseIndex + accentOffset) % ring.count],
            contrast: ring[(baseIndex + contrastOffset) % ring.count]
        )
    }

    private static func bucket(_ hash: UInt64, shift: UInt64, modulo: Int) -> Int {
        Int((hash >> shift) % UInt64(modulo))
    }

    private static func color(hex: UInt32) -> Color {
        let red = Double((hex >> 16) & 0xFF) / 255.0
        let green = Double((hex >> 8) & 0xFF) / 255.0
        let blue = Double(hex & 0xFF) / 255.0
        return Color(.sRGB, red: red, green: green, blue: blue, opacity: 1)
    }

    private static func fnv1a64(of string: String) -> UInt64 {
        let offsetBasis: UInt64 = 0xcbf29ce484222325
        let prime: UInt64 = 0x00000100000001B3
        var hash = offsetBasis
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash &*= prime
        }
        return hash
    }
}

func normalizedTitleKey(_ title: String) -> String {
    let parts = title
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .split(whereSeparator: { $0.isWhitespace })
    return parts.joined(separator: " ").lowercased()
}

struct TitlePatternIcon: View {
    @Environment(\.colorScheme) private var colorScheme
    let title: String

    private let side: CGFloat = 16
    private let cornerRadius: CGFloat = 4

    var body: some View {
        let spec = TitlePatternGenerator.spec(for: title)
        let palette = TitlePatternGenerator.palette(for: spec.paletteIndex, scheme: colorScheme, accentMix: spec.accentMix)
        Canvas { context, size in
            var drawing = context
            let rect = CGRect(origin: .zero, size: size)
            let center = CGPoint(x: rect.midX, y: rect.midY)

            drawing.translateBy(x: center.x, y: center.y)
            drawing.rotate(by: .degrees(Double(spec.rotationQuarterTurns * 90)))
            drawing.translateBy(x: -center.x, y: -center.y)

            drawGradient(kind: spec.patternKind, density: spec.density, in: rect, palette: palette, context: &drawing)
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(borderColor, lineWidth: 1)
        )
        .accessibilityHidden(true)
    }

    private var borderColor: Color {
        colorScheme == .dark ? .white.opacity(0.22) : .black.opacity(0.16)
    }

    private func drawGradient(
        kind: TitlePatternKind,
        density: Int,
        in rect: CGRect,
        palette: TitlePatternPalette,
        context: inout GraphicsContext
    ) {
        let colors = gradientColors(for: palette, density: density)
        switch kind {
        case .vertical:
            context.fill(
                Path(rect),
                with: .linearGradient(
                    Gradient(colors: colors),
                    startPoint: CGPoint(x: rect.midX, y: rect.minY),
                    endPoint: CGPoint(x: rect.midX, y: rect.maxY)
                )
            )
        case .horizontal:
            context.fill(
                Path(rect),
                with: .linearGradient(
                    Gradient(colors: colors),
                    startPoint: CGPoint(x: rect.minX, y: rect.midY),
                    endPoint: CGPoint(x: rect.maxX, y: rect.midY)
                )
            )
        case .diagonalDown:
            context.fill(
                Path(rect),
                with: .linearGradient(
                    Gradient(colors: colors),
                    startPoint: CGPoint(x: rect.minX, y: rect.minY),
                    endPoint: CGPoint(x: rect.maxX, y: rect.maxY)
                )
            )
        case .diagonalUp:
            context.fill(
                Path(rect),
                with: .linearGradient(
                    Gradient(colors: colors),
                    startPoint: CGPoint(x: rect.maxX, y: rect.minY),
                    endPoint: CGPoint(x: rect.minX, y: rect.maxY)
                )
            )
        case .radialCorner:
            context.fill(
                Path(rect),
                with: .radialGradient(
                    Gradient(colors: colors),
                    center: cornerCenter(for: density, in: rect),
                    startRadius: 0.4,
                    endRadius: rect.width * 0.9
                )
            )
        }
    }

    private func gradientColors(for palette: TitlePatternPalette, density: Int) -> [Color] {
        // Keep each icon to exactly two colors; density selects which pair to avoid repetitive combinations.
        switch density {
        case 0:
            return [palette.background, palette.accent]
        case 1:
            return [palette.accent, palette.contrast]
        default:
            return [palette.background, palette.contrast]
        }
    }

    private func cornerCenter(for density: Int, in rect: CGRect) -> CGPoint {
        switch density {
        case 0:
            return CGPoint(x: rect.minX, y: rect.minY)
        case 1:
            return CGPoint(x: rect.maxX, y: rect.minY)
        default:
            return CGPoint(x: rect.minX, y: rect.maxY)
        }
    }
}

private struct TitlePatternPalette {
    let background: Color
    let accent: Color
    let contrast: Color
}
