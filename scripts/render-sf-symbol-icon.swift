import AppKit
import Foundation

let args = CommandLine.arguments
if args.count < 3 {
    fputs("Usage: render-sf-symbol-icon.swift <background-png> <output-png> [symbol-name]\n", stderr)
    exit(1)
}

let backgroundPath = args[1]
let outputPath = args[2]
let symbolName = args.count > 3 ? args[3] : "scribble"

guard
    let background = NSImage(contentsOfFile: backgroundPath),
    let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
else {
    fputs("Failed to load background or SF Symbol.\n", stderr)
    exit(1)
}

let canvas = CGSize(width: 1024, height: 1024)
let symbolConfig = NSImage.SymbolConfiguration(pointSize: 720, weight: .bold, scale: .large)
let colorConfig = NSImage.SymbolConfiguration(paletteColors: [.white])
let glyph = (symbol
    .withSymbolConfiguration(symbolConfig)?
    .withSymbolConfiguration(colorConfig)) ?? symbol

let output = NSImage(size: canvas)
output.lockFocus()

NSColor.clear.setFill()
NSRect(origin: .zero, size: canvas).fill()

let clipRect = NSRect(x: 44, y: 44, width: 936, height: 936)
NSBezierPath(roundedRect: clipRect, xRadius: 212, yRadius: 212).addClip()

background.draw(in: NSRect(origin: .zero, size: canvas))

let targetRect = NSRect(x: 150, y: 220, width: 724, height: 584)
glyph.draw(in: targetRect, from: .zero, operation: .sourceOver, fraction: 1.0)

output.unlockFocus()

guard
    let tiff = output.tiffRepresentation,
    let rep = NSBitmapImageRep(data: tiff),
    let png = rep.representation(using: .png, properties: [:])
else {
    fputs("Failed to encode PNG output.\n", stderr)
    exit(1)
}

try png.write(to: URL(fileURLWithPath: outputPath))
print("Wrote \(outputPath)")
