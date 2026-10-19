import AppKit
import CoreImage
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import Vision

enum ImageFormat: String, CaseIterable, Identifiable, Sendable {
    case jpeg, png, heic, tiff

    var id: Self { self }
    var title: String { rawValue.uppercased() }
    var type: UTType {
        switch self {
        case .jpeg: .jpeg
        case .png: .png
        case .heic: .heic
        case .tiff: .tiff
        }
    }
    var fileExtension: String { self == .jpeg ? "jpg" : rawValue }
}

enum ImageToolError: LocalizedError {
    case unreadable(String), unwritable(String), noSubject(String)

    var errorDescription: String? {
        switch self {
        case .unreadable(let name): "无法读取图片“\(name)”。"
        case .unwritable(let name): "无法写入“\(name)”。"
        case .noSubject(let name): "在“\(name)”中没有识别到可以抠出的主体。"
        }
    }
}

enum ImageTools {
    static func isImage(_ url: URL) -> Bool {
        guard let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType else { return false }
        return type.conforms(to: .image) && !type.conforms(to: .svg)
    }

    /// Writes a converted (and optionally downscaled) copy next to the original. Metadata is kept.
    static func convert(_ url: URL, to format: ImageFormat, maxPixel: Int? = nil, quality: Double = 0.9) throws -> URL {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { throw ImageToolError.unreadable(url.lastPathComponent) }
        let image: CGImage?
        if let maxPixel {
            image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            ] as CFDictionary)
        } else {
            image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        }
        guard let image else { throw ImageToolError.unreadable(url.lastPathComponent) }

        let stem = url.deletingPathExtension().lastPathComponent
        let suffix = maxPixel.map { " \($0)px" } ?? ""
        let target = FileOperations.uniqueURL(for: "\(stem)\(suffix).\(format.fileExtension)", in: url.deletingLastPathComponent())

        var properties = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]) ?? [:]
        if maxPixel != nil {
            // The thumbnail is already upright, so the orientation tag must not rotate it again.
            properties[kCGImagePropertyOrientation] = 1
            properties[kCGImagePropertyPixelWidth] = image.width
            properties[kCGImagePropertyPixelHeight] = image.height
        }
        properties[kCGImageDestinationLossyCompressionQuality] = quality
        try write(image, to: target, type: format.type, properties: properties)
        return target
    }

    /// Rotates in place. The original goes to the Trash first, so the returned steps undo it exactly.
    static func rotate(_ url: URL, clockwise: Bool) throws -> [UndoStep] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let type = CGImageSourceGetType(source).flatMap({ UTType($0 as String) }) else {
            throw ImageToolError.unreadable(url.lastPathComponent)
        }
        let props = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]) ?? [:]
        let w = props[kCGImagePropertyPixelWidth] as? Int ?? 0, h = props[kCGImagePropertyPixelHeight] as? Int ?? 0
        guard let upright = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(w, h, 1),
        ] as CFDictionary) else { throw ImageToolError.unreadable(url.lastPathComponent) }

        let width = upright.height, height = upright.width
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: upright.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw ImageToolError.unwritable(url.lastPathComponent)
        }
        context.translateBy(x: CGFloat(width) / 2, y: CGFloat(height) / 2)
        context.rotate(by: clockwise ? -.pi / 2 : .pi / 2)
        context.draw(upright, in: CGRect(x: -CGFloat(upright.width) / 2, y: -CGFloat(upright.height) / 2,
                                         width: CGFloat(upright.width), height: CGFloat(upright.height)))
        guard let rotated = context.makeImage() else { throw ImageToolError.unwritable(url.lastPathComponent) }

        var trashed: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &trashed)
        var properties = props
        properties[kCGImagePropertyOrientation] = 1
        properties[kCGImagePropertyPixelWidth] = width
        properties[kCGImagePropertyPixelHeight] = height
        properties[kCGImageDestinationLossyCompressionQuality] = 0.95
        do {
            try write(rotated, to: url, type: type, properties: properties)
        } catch {
            if let trashed = trashed as URL? { try? FileManager.default.moveItem(at: trashed, to: url) }
            throw error
        }
        guard let original = trashed as URL? else { return [] }
        return [.trash(url), .move(from: original, to: url)]
    }

    /// One page per image, in the given order.
    static func makePDF(_ urls: [URL], in directory: URL) throws -> URL {
        let document = PDFDocument()
        for url in urls {
            guard let image = NSImage(contentsOf: url), let page = PDFPage(image: image) else {
                throw ImageToolError.unreadable(url.lastPathComponent)
            }
            document.insert(page, at: document.pageCount)
        }
        let name = urls.count == 1 ? urls[0].deletingPathExtension().lastPathComponent + ".pdf" : "合并的图片.pdf"
        let target = FileOperations.uniqueURL(for: name, in: directory)
        guard document.write(to: target) else { throw ImageToolError.unwritable(target.lastPathComponent) }
        return target
    }

    /// Cuts out the foreground subject (Vision) into a transparent PNG.
    static func removeBackground(_ url: URL) throws -> URL {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: 8192,
              ] as CFDictionary) else { throw ImageToolError.unreadable(url.lastPathComponent) }
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image)
        try handler.perform([request])
        guard let result = request.results?.first, !result.allInstances.isEmpty else {
            throw ImageToolError.noSubject(url.lastPathComponent)
        }
        let buffer = try result.generateMaskedImage(ofInstances: result.allInstances, from: handler, croppedToInstancesExtent: false)
        let ciImage = CIImage(cvPixelBuffer: buffer)
        let target = FileOperations.uniqueURL(for: url.deletingPathExtension().lastPathComponent + " 去背景.png",
                                              in: url.deletingLastPathComponent())
        try CIContext().writePNGRepresentation(of: ciImage, to: target, format: .RGBA8,
                                               colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        return target
    }

    private static func write(_ image: CGImage, to url: URL, type: UTType, properties: [CFString: Any]) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            throw ImageToolError.unwritable(url.lastPathComponent)
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ImageToolError.unwritable(url.lastPathComponent) }
    }
}
