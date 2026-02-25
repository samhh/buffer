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
    private static let hues: [Double] = [
        0.02, 0.08, 0.14, 0.21, 0.30, 0.40, 0.50, 0.58, 0.64, 0.72, 0.82, 0.92
    ]

    static var paletteCount: Int {
        hues.count
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
        let hue = hues[index % hues.count]
        let accentHue = wrappedHue(hue + [0.09, -0.12, 0.20][accentMix % accentMixLevels])
        let contrastHue = wrappedHue(hue + 0.50)
        if scheme == .dark {
            return TitlePatternPalette(
                background: Color(hue: hue, saturation: 0.80, brightness: 0.62),
                accent: Color(hue: accentHue, saturation: 0.76, brightness: 0.82),
                contrast: Color(hue: contrastHue, saturation: 0.58, brightness: 0.88)
            )
        }
        return TitlePatternPalette(
            background: Color(hue: hue, saturation: 0.68, brightness: 0.92),
            accent: Color(hue: accentHue, saturation: 0.78, brightness: 0.78),
            contrast: Color(hue: contrastHue, saturation: 0.56, brightness: 0.66)
        )
    }

    private static func bucket(_ hash: UInt64, shift: UInt64, modulo: Int) -> Int {
        Int((hash >> shift) % UInt64(modulo))
    }

    private static func wrappedHue(_ value: Double) -> Double {
        let result = value.truncatingRemainder(dividingBy: 1)
        return result >= 0 ? result : result + 1
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
