// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.

// Renders AppIcon.svg into AppIcon.icns, clipped to the macOS app icon shape.
// Usage: swift Support/make-icon.swift Support/AppIcon.svg Support/AppIcon.icns

import AppKit

let arguments = CommandLine.arguments
guard arguments.count == 3, let artwork = NSImage(contentsOfFile: arguments[1]) else {
  FileHandle.standardError.write(Data("Usage: make-icon.swift <icon.svg> <output.icns>\n".utf8))
  exit(1)
}
let iconset = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func render(_ pixels: Int) -> Data {
  let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
    hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
  // Apple's icon grid: an 824pt rounded square centred on a 1024pt canvas.
  let scale = CGFloat(pixels) / 1024
  let body = NSRect(x: 100 * scale, y: 100 * scale, width: 824 * scale, height: 824 * scale)
  NSBezierPath(roundedRect: body, xRadius: 185 * scale, yRadius: 185 * scale).addClip()
  artwork.draw(in: body)
  NSGraphicsContext.restoreGraphicsState()
  return bitmap.representation(using: .png, properties: [:])!
}

for size in [16, 32, 128, 256, 512] {
  try render(size).write(to: iconset.appending(path: "icon_\(size)x\(size).png"))
  try render(size * 2).write(to: iconset.appending(path: "icon_\(size)x\(size)@2x.png"))
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", arguments[2]]
try iconutil.run()
iconutil.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
exit(iconutil.terminationStatus)
