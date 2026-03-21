import XCTest
import AppKit
@testable import Buffer

final class CodeRenderSnapshotTests: XCTestCase {

    @MainActor func testSnapshotInlineAndBlockCode() throws {
        let sampleText = """
        Here is some `inline code` in a sentence.
        Multiple `spans` on `one line` work too.
        ```
        func hello() {
            print("world")
        }
        ```
        Back to normal text after the block.
            - A list item with `code` in it
        """

        let font = NSFont.systemFont(ofSize: 14)
        let paragraphStyle: NSParagraphStyle = {
            let style = NSMutableParagraphStyle()
            style.lineSpacing = 2
            style.paragraphSpacing = 2
            return style
        }()
        let textStorage = NSTextStorage(
            string: sampleText,
            attributes: [
                .font: font,
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: paragraphStyle,
            ]
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

        // Apply code styling
        let codeSpans = CodeStyling.detectSpans(in: sampleText as NSString)
        CodeStyling.applyAttributes(to: textStorage, spans: codeSpans, linkSpans: [])
        layoutManager.codeSpans = codeSpans

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

        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: imageWidth, height: imageHeight).fill()

        let drawOrigin = NSPoint(x: padding, y: padding)
        let fullGlyphRange = layoutManager.glyphRange(for: textContainer)
        layoutManager.drawBackground(forGlyphRange: fullGlyphRange, at: drawOrigin)
        layoutManager.drawGlyphs(forGlyphRange: fullGlyphRange, at: drawOrigin)

        NSGraphicsContext.restoreGraphicsState()

        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let outputPath = repoRoot.appendingPathComponent("Tests/BufferTests/__Snapshots__/code_render_snapshot.png").path
        guard let pngData = bitmap.representation(
            using: NSBitmapImageRep.FileType.png, properties: [:]
        ) else {
            XCTFail("Failed to create PNG data")
            return
        }
        try pngData.write(to: URL(fileURLWithPath: outputPath))
        print("✅ Code render snapshot saved to \(outputPath)")
    }
}
