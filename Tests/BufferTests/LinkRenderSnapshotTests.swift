import XCTest
import AppKit
@testable import Buffer

final class LinkRenderSnapshotTests: XCTestCase {

    /// Renders compressed link spans into an offscreen text system and saves
    /// a snapshot PNG.  Red lines mark the compressed-glyph-range end;
    /// green lines mark the display-text natural width.  Any gap between
    /// red and green is the "faux whitespace" the user sees.
    func testSnapshotCompressedLinks() throws {
        let sampleText = """
        https://github.com/nicklockwood/SwiftFormat/blob/main/Rules/organizeDeclarations.md
        https://github.com/nicklockwood/SwiftFormat/tree/main/
        https://github.com/nicklockwood/SwiftFormat/blob/main/foo.md
        Some plain text between links for contrast.
        https://developer.apple.com/documentation/appkit/nslayoutmanager/1403175-drawglyphs
        """

        let font = NSFont.systemFont(ofSize: 14)
        let textStorage = NSTextStorage(
            string: sampleText,
            attributes: [.font: font, .foregroundColor: NSColor.labelColor]
        )

        let layoutManager = ListBulletLayoutManager()
        textStorage.addLayoutManager(layoutManager)

        let containerWidth: CGFloat = 520
        let textContainer = NSTextContainer(
            size: NSSize(width: containerWidth, height: .greatestFiniteMagnitude)
        )
        textContainer.widthTracksTextView = false
        textContainer.lineFragmentPadding = 0
        layoutManager.addTextContainer(textContainer)

        let spans = LinkShrink.detectLinks(in: sampleText as NSString)
        layoutManager.updateLinkCompression(spans: spans, activeRanges: [])
        layoutManager.ensureLayout(for: textContainer)

        let usedRect = layoutManager.usedRect(for: textContainer)
        let padding: CGFloat = 16
        let imageWidth = Int(containerWidth + padding * 2)
        let imageHeight = Int(usedRect.height + padding * 2)

        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: imageWidth,
            pixelsHigh: imageHeight,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .calibratedRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )!

        let bitmapContext = NSGraphicsContext(bitmapImageRep: bitmap)!
        let cgCtx = bitmapContext.cgContext
        cgCtx.translateBy(x: 0, y: CGFloat(imageHeight))
        cgCtx.scaleBy(x: 1, y: -1)
        let flippedContext = NSGraphicsContext(cgContext: cgCtx, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = flippedContext

        // White background
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: imageWidth, height: imageHeight).fill()

        // Draw the text system
        let drawOrigin = NSPoint(x: padding, y: padding)
        let fullGlyphRange = layoutManager.glyphRange(for: textContainer)
        layoutManager.drawBackground(forGlyphRange: fullGlyphRange, at: drawOrigin)
        layoutManager.drawGlyphs(forGlyphRange: fullGlyphRange, at: drawOrigin)

        // Draw diagnostic lines for each compressed span
        for span in layoutManager.displaySpans {
            let glyphRange = layoutManager.glyphRange(
                forCharacterRange: span.range, actualCharacterRange: nil
            )
            guard glyphRange.location != NSNotFound else { continue }

            // Red line: where the compressed glyphs actually end
            let boundingRect = layoutManager.boundingRect(
                forGlyphRange: glyphRange, in: textContainer
            )
            let compressedEndX = drawOrigin.x + boundingRect.maxX
            let lineY = drawOrigin.y + boundingRect.minY
            let lineHeight = boundingRect.height

            NSColor.red.withAlphaComponent(0.7).setStroke()
            let redLine = NSBezierPath()
            redLine.move(to: NSPoint(x: compressedEndX, y: lineY))
            redLine.line(to: NSPoint(x: compressedEndX, y: lineY + lineHeight))
            redLine.lineWidth = 1.5
            redLine.stroke()

            // Green line: where the display text naturally ends
            let displayWidth = (span.displayText as NSString).size(
                withAttributes: [.font: font]
            ).width
            let displayEndX = drawOrigin.x + boundingRect.minX + displayWidth

            NSColor.green.withAlphaComponent(0.7).setStroke()
            let greenLine = NSBezierPath()
            greenLine.move(to: NSPoint(x: displayEndX, y: lineY))
            greenLine.line(to: NSPoint(x: displayEndX, y: lineY + lineHeight))
            greenLine.lineWidth = 1.5
            greenLine.stroke()

            // Print the gap for diagnostics
            let gap = compressedEndX - displayEndX
            print("  \(span.displayText): compressed=\(String(format: "%.1f", boundingRect.width))  display=\(String(format: "%.1f", displayWidth))  gap=\(String(format: "%.1f", gap))pt")
        }

        NSGraphicsContext.restoreGraphicsState()

        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // BufferTests/
            .deletingLastPathComponent()  // Tests/
            .deletingLastPathComponent()  // repo root
        let outputPath = repoRoot.appendingPathComponent("Tests/BufferTests/__Snapshots__/link_render_snapshot.png").path
        guard let pngData = bitmap.representation(
            using: NSBitmapImageRep.FileType.png, properties: [:]
        ) else {
            XCTFail("Failed to create PNG data")
            return
        }
        try pngData.write(to: URL(fileURLWithPath: outputPath))
        print("✅ Snapshot saved to \(outputPath)")
    }
}
