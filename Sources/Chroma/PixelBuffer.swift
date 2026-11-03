import CoreGraphics

/// A frozen copy of a screenshot's pixels (top-left origin) that the picker reads from.
final class PixelBuffer {
    let width: Int
    let height: Int
    private let pixels: [UInt32]

    init(width: Int, height: Int, pixels: [UInt32]) {
        precondition(pixels.count == width * height)
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    convenience init?(image: CGImage) {
        let width = image.width
        let height = image.height
        var pixels = [UInt32](repeating: 0, count: width * height)
        let drawn = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                // Converts from whatever space the image is in, so values are always sRGB.
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            ) else { return false }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        self.init(width: width, height: height, pixels: pixels)
    }

    func contains(x: Int, y: Int) -> Bool {
        x >= 0 && y >= 0 && x < width && y < height
    }

    /// Packed 0x__RRGGBB.
    @inline(__always)
    func packed(x: Int, y: Int) -> UInt32 {
        pixels[y * width + x]
    }

    /// The average of a `size` × `size` square centered on (x, y), clipped to the image.
    func color(x: Int, y: Int, sampleSize size: Int = 1) -> RGBColor? {
        guard contains(x: x, y: y) else { return nil }
        let radius = max(0, (size - 1) / 2)
        var r = 0, g = 0, b = 0, count = 0
        for sy in max(0, y - radius)...min(height - 1, y + radius) {
            for sx in max(0, x - radius)...min(width - 1, x + radius) {
                let p = pixels[sy * width + sx]
                r += Int((p >> 16) & 0xFF)
                g += Int((p >> 8) & 0xFF)
                b += Int(p & 0xFF)
                count += 1
            }
        }
        return RGBColor(
            r8: Int((Double(r) / Double(count)).rounded()),
            g8: Int((Double(g) / Double(count)).rounded()),
            b8: Int((Double(b) / Double(count)).rounded())
        )
    }
}
