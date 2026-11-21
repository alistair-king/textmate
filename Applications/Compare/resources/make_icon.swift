// Draws Compare.icns: two TextMate flowers, one over the other, with a pair
// of arrows (→ over ←) above them. Run from the repository root:
//
//   swift Applications/Compare/resources/make_icon.swift
//
// It reads TextMate's own icon (Applications/TextMate/icons/TextMate.icns),
// writes Applications/Compare/resources/Compare.icns, and leaves a 1024 px
// preview next to it as Compare-preview.png (not committed).

import AppKit

let root      = FileManager.default.currentDirectoryPath
let flowerURL = URL(fileURLWithPath: "\(root)/Applications/TextMate/icons/TextMate.icns")
let outputDir = URL(fileURLWithPath: "\(root)/Applications/Compare/resources")

guard let flowerIcon = NSImage(contentsOf: flowerURL),
      let flower = flowerIcon.cgImage(forProposedRect: nil, context: nil, hints: [.ctm: NSAffineTransform(transform: AffineTransform(scale: 2))]) else {
	fatalError("cannot read \(flowerURL.path)")
}

// Everything is laid out on a 1024 × 1024 canvas, origin at the bottom left.
// Shadows are not scaled by the context's transform, so they are scaled here.
var shadowScale: CGFloat = 1
func drawFlower (_ context: CGContext, center: CGPoint, size: CGFloat, degrees: CGFloat, shadow: Bool)
{
	context.saveGState()
	if shadow
	{
		context.setShadow(offset: CGSize(width: 0, height: -14 * shadowScale), blur: 36 * shadowScale, color: NSColor(white: 0, alpha: 0.45).cgColor)
	}
	context.translateBy(x: center.x, y: center.y)
	context.rotate(by: degrees * .pi / 180)
	context.draw(flower, in: CGRect(x: -size / 2, y: -size / 2, width: size, height: size))
	context.restoreGState()
}

// A thick arrow from `from` to `to` along a horizontal line.
func arrowPath (from: CGFloat, to: CGFloat, y: CGFloat) -> CGPath
{
	let shaft: CGFloat = 58, head: CGFloat = 156, headLength: CGFloat = 140
	let direction: CGFloat = to > from ? 1 : -1
	let neck = to - direction * headLength
	let path = CGMutablePath()
	path.move(to: CGPoint(x: from, y: y + shaft / 2))
	path.addLine(to: CGPoint(x: neck, y: y + shaft / 2))
	path.addLine(to: CGPoint(x: neck, y: y + head / 2))
	path.addLine(to: CGPoint(x: to, y: y))
	path.addLine(to: CGPoint(x: neck, y: y - head / 2))
	path.addLine(to: CGPoint(x: neck, y: y - shaft / 2))
	path.addLine(to: CGPoint(x: from, y: y - shaft / 2))
	path.closeSubpath()
	return path
}

func drawArrow (_ context: CGContext, _ path: CGPath)
{
	let bounds = path.boundingBox
	// Shadow, then a glossy orange body (as ThemeEditor's pencil), then an outline.
	context.saveGState()
	context.setShadow(offset: CGSize(width: 0, height: -8 * shadowScale), blur: 18 * shadowScale, color: NSColor(white: 0, alpha: 0.4).cgColor)
	context.addPath(path)
	context.setFillColor(NSColor(srgbRed: 0.93, green: 0.45, blue: 0.05, alpha: 1).cgColor)
	context.fillPath()
	context.restoreGState()

	context.saveGState()
	context.addPath(path)
	context.clip()
	let colors = [ NSColor(srgbRed: 1.00, green: 0.86, blue: 0.35, alpha: 1).cgColor,
	               NSColor(srgbRed: 0.99, green: 0.62, blue: 0.12, alpha: 1).cgColor,
	               NSColor(srgbRed: 0.88, green: 0.40, blue: 0.04, alpha: 1).cgColor ] as CFArray
	let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [ 0, 0.55, 1 ])!
	context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: bounds.maxY), end: CGPoint(x: 0, y: bounds.minY), options: [])
	// A highlight along the top edge.
	context.setFillColor(NSColor(white: 1, alpha: 0.28).cgColor)
	context.fill(CGRect(x: bounds.minX, y: bounds.midY + 6, width: bounds.width, height: bounds.height / 2))
	context.restoreGState()

	context.addPath(path)
	context.setStrokeColor(NSColor(srgbRed: 0.62, green: 0.27, blue: 0.02, alpha: 1).cgColor)
	context.setLineWidth(8)
	context.setLineJoin(.round)
	context.strokePath()
}

func render (pixels: Int) -> NSBitmapImageRep
{
	let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
	let graphics = NSGraphicsContext(bitmapImageRep: rep)!
	let context = graphics.cgContext
	context.interpolationQuality = .high
	shadowScale = CGFloat(pixels) / 1024
	context.scaleBy(x: shadowScale, y: shadowScale)

	// The flowers fill the lower part: the left one behind, turned so the
	// petals do not line up; the right one in front, with a shadow.
	drawFlower(context, center: CGPoint(x: 372, y: 350), size: 640, degrees: 14, shadow: false)
	drawFlower(context, center: CGPoint(x: 652, y: 322), size: 640, degrees: 0, shadow: true)

	// → over ←, above the flowers.
	drawArrow(context, arrowPath(from: 240, to: 784, y: 912))
	drawArrow(context, arrowPath(from: 784, to: 240, y: 768))
	return rep
}

let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("Compare-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for (points, scales) in [ (16, [1, 2]), (32, [1, 2]), (128, [1, 2]), (256, [1, 2]), (512, [1, 2]) ]
{
	for scale in scales
	{
		let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
		let png = render(pixels: points * scale).representation(using: .png, properties: [:])!
		try png.write(to: iconset.appendingPathComponent(name))
	}
}
try render(pixels: 1024).representation(using: .png, properties: [:])!.write(to: outputDir.appendingPathComponent("Compare-preview.png"))

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = [ "-c", "icns", "-o", outputDir.appendingPathComponent("Compare.icns").path, iconset.path ]
try iconutil.run()
iconutil.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
guard iconutil.terminationStatus == 0 else { fatalError("iconutil failed") }
print("wrote \(outputDir.appendingPathComponent("Compare.icns").path)")
