import UIKit

enum CompressionError: Error {
    case noImageData
    case encodingFailed
}

enum ImageCompressor {
    static let maxDimension: CGFloat = 1920
    static let jpegQuality: CGFloat = 0.75

    // Exposed for unit tests: scale + JPEG-encode a UIImage directly.
    static func compressImage(_ image: UIImage) throws -> Data {
        let scaled = scale(image, maxDimension: maxDimension)
        guard let data = scaled.jpegData(compressionQuality: jpegQuality) else {
            throw CompressionError.encodingFailed
        }
        return data
    }

    private static func scale(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
        // Measure in pixels (size × scale) so the JPEG output is bounded correctly
        // regardless of screen scale. Floor ensures we never exceed maxDimension by
        // even 1 pixel due to floating-point rounding.
        let pixelWidth = image.size.width * image.scale
        let pixelHeight = image.size.height * image.scale
        let longestPixel = max(pixelWidth, pixelHeight)
        guard longestPixel > maxDimension else { return image }
        let ratio = maxDimension / longestPixel
        let newSize = CGSize(width: floor(pixelWidth * ratio), height: floor(pixelHeight * ratio))
        // Render at scale 1 so newSize is in pixels; the default format inherits
        // the device screen scale (2x/3x), which would multiply the bitmap size.
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: newSize, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }
}
