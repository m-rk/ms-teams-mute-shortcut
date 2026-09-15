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
context.cgContext.clear(CGRect(x: 0, y: 0, width: size, height: size))
image.draw(
    in: NSRect(x: 0, y: 0, width: size, height: size),
    from: .zero,
    operation: .sourceOver,
    fraction: 1
)
NSGraphicsContext.restoreGraphicsState()

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
