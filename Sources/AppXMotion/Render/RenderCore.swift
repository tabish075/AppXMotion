import CoreImage
import CoreVideo
import ImageIO
import Metal
import UniformTypeIdentifiers

enum RenderCore {
    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
    static let linearSRGB = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!

    /// One shared, thread-safe Metal-backed Core Image context.
    static let context: CIContext = {
        let options: [CIContextOption: Any] = [
            .workingColorSpace: linearSRGB,
            .outputColorSpace: sRGB,
            .name: "AppX Motion",
        ]
        if let device = MTLCreateSystemDefaultDevice() {
            return CIContext(mtlDevice: device, options: options)
        }
        return CIContext(options: options)
    }()

    enum Tagging { case preview, export }

    /// Colour tags for rendered frames.
    ///
    /// The pixels are always sRGB. For export they're tagged BT.709 so the H.264 encoder stores them
    /// unchanged with BT.709 metadata: that is what browsers and the X apps expect, so the colours
    /// you see here are the colours people see on X. The preview is tagged with the sRGB transfer
    /// so macOS shows it exactly as rendered.
    static func tag(_ buffer: CVPixelBuffer, _ tagging: Tagging) {
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        let transfer = tagging == .export ? kCVImageBufferTransferFunction_ITU_R_709_2 : kCVImageBufferTransferFunction_sRGB
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, transfer, .shouldPropagate)
    }

    /// Writes an sRGB PNG or JPEG (X strips colour profiles, so everything is converted to sRGB first).
    static func writeImage(_ image: CGImage, to url: URL, format: ImageFormat) throws {
        let type = format == .png ? UTType.png : UTType.jpeg
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        var properties: [CFString: Any] = [:]
        if format == .jpeg { properties[kCGImageDestinationLossyCompressionQuality] = 0.95 }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    }
}
