#!/usr/bin/env xcrun swift

import AppKit
import Foundation

guard CommandLine.arguments.count == 4,
      let size = Int(CommandLine.arguments[3]),
      size > 0 else {
    FileHandle.standardError.write(Data("Usage: render-template-icon.swift INPUT.svg OUTPUT.png SIZE\n".utf8))
    exit(1)
}

let inputURL = URL(fileURLWithPath: CommandLine.arguments[1])
let outputURL = URL(fileURLWithPath: CommandLine.arguments[2])

guard let image = NSImage(contentsOf: inputURL),
      let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
      ),
      let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
    FileHandle.standardError.write(Data("Could not prepare the template icon render.\n".utf8))
    exit(1)
}

bitmap.size = NSSize(width: size, height: size)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
context.imageInterpolation = .high
context.cgContext.setAllowsAntialiasing(true)
context.cgContext.setShouldAntialias(true)
context.cgContext.clear(CGRect(x: 0, y: 0, width: size, height: size))
image.draw(
    in: NSRect(x: 0, y: 0, width: size, height: size),
    from: .zero,
    operation: .sourceOver,
    fraction: 1
)
NSGraphicsContext.restoreGraphicsState()

guard let pixels = bitmap.bitmapData else {
    FileHandle.standardError.write(Data("Could not access the template icon pixels.\n".utf8))
    exit(1)
}

for y in 0..<size {
    for x in 0..<size {
        let offset = y * bitmap.bytesPerRow + x * 4
        let red = Double(pixels[offset]) / 255
        let green = Double(pixels[offset + 1]) / 255
        let blue = Double(pixels[offset + 2]) / 255
        let sourceAlpha = Double(pixels[offset + 3]) / 255
        let luminance = 0.2126 * red + 0.7152 * green + 0.0722 * blue
        let templateAlpha = UInt8((255 * sourceAlpha * (1 - luminance)).rounded())

        pixels[offset] = 0
        pixels[offset + 1] = 0
        pixels[offset + 2] = 0
        pixels[offset + 3] = templateAlpha
    }
}

let corners = [
    (0, 0),
    (size - 1, 0),
    (0, size - 1),
    (size - 1, size - 1),
]
let cornersAreTransparent = corners.allSatisfy { x, y in
    bitmap.colorAt(x: x, y: y)?.alphaComponent == 0
}
let containsVisibleArtwork = (0..<size).contains { y in
    (0..<size).contains { x in
        (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0
    }
}
guard cornersAreTransparent, containsVisibleArtwork else {
    FileHandle.standardError.write(
        Data("Template icon must contain visible artwork on a transparent canvas.\n".utf8)
    )
    exit(1)
}

guard let data = bitmap.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write(Data("Could not encode the template icon PNG.\n".utf8))
    exit(1)
}

do {
    try data.write(to: outputURL, options: .atomic)
} catch {
    FileHandle.standardError.write(Data("Could not write the template icon PNG: \(error)\n".utf8))
    exit(1)
}
