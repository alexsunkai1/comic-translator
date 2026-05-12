import Foundation
import CoreGraphics
import AppKit
import ImageIO
import UniformTypeIdentifiers

// MARK: - 背景/文字颜色采样

enum BackgroundSampler {
    static func sampleBackgroundColor(image: CGImage, normalizedBox: CGRect) -> (r: Double, g: Double, b: Double) {
        let imgW = CGFloat(image.width)
        let imgH = CGFloat(image.height)

        let px = (normalizedBox.origin.x * imgW).rounded()
        let py = ((1.0 - normalizedBox.origin.y - normalizedBox.height) * imgH).rounded()
        let pw = (normalizedBox.width * imgW).rounded()
        let ph = (normalizedBox.height * imgH).rounded()

        let margin: CGFloat = 3
        let sampleX = max(0, px - margin)
        let sampleY = max(0, py - margin)
        let sampleW = min(imgW - sampleX, pw + margin * 2)
        let sampleH = min(imgH - sampleY, ph + margin * 2)

        let sampleRect = CGRect(x: sampleX, y: sampleY, width: sampleW, height: sampleH)
        guard sampleRect.width > 1, sampleRect.height > 1,
              let cropped = image.cropping(to: sampleRect) else {
            return (1, 1, 1)
        }

        return sampleEdgeMedian(cropped)
    }

    static func isLight(_ r: Double, _ g: Double, _ b: Double) -> Bool {
        (0.299 * r + 0.587 * g + 0.114 * b) > 0.5
    }

    private static func sampleEdgeMedian(_ image: CGImage) -> (r: Double, g: Double, b: Double) {
        let w = image.width
        let h = image.height
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bpp = 4
        let bpr = w * bpp
        var pixels = [UInt8](repeating: 0, count: h * bpr)

        guard let ctx = CGContext(
            data: &pixels, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: bpr,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return (1, 1, 1) }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))

        var rs: [UInt8] = [], gs: [UInt8] = [], bs: [UInt8] = []
        for y in [0, h - 1] where y >= 0 && y < h {
            for x in 0..<w {
                let off = y * bpr + x * bpp
                rs.append(pixels[off]); gs.append(pixels[off + 1]); bs.append(pixels[off + 2])
            }
        }
        for x in [0, w - 1] where x >= 0 && x < w {
            for y in 0..<h {
                let off = y * bpr + x * bpp
                rs.append(pixels[off]); gs.append(pixels[off + 1]); bs.append(pixels[off + 2])
            }
        }

        guard !rs.isEmpty else { return (1, 1, 1) }
        rs.sort(); gs.sort(); bs.sort()
        return (
            Double(rs[rs.count / 2]) / 255.0,
            Double(gs[gs.count / 2]) / 255.0,
            Double(bs[bs.count / 2]) / 255.0
        )
    }
}

// MARK: - 图片渲染

enum ImageRenderer {

    /// 在原图上覆盖译文后渲染
    static func renderTranslated(
        original: CGImage,
        ocrResults: [OCRResult],
        translations: [String]
    ) -> CGImage? {
        let width = original.width
        let height = original.height
        let colorSpace = CGColorSpaceCreateDeviceRGB()

        guard let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        let fullRect = CGRect(x: 0, y: 0, width: width, height: height)
        context.draw(original, in: fullRect)

        let imgW = CGFloat(width)
        let imgH = CGFloat(height)

        for (i, ocr) in ocrResults.enumerated() {
            guard i < translations.count, !translations[i].isEmpty else { continue }

            let visionBox = ocr.boundingBox
            let pixelX = visionBox.origin.x * imgW
            let pixelY = visionBox.origin.y * imgH
            let pixelW = visionBox.width * imgW
            let pixelH = visionBox.height * imgH
            let blockRect = CGRect(x: pixelX, y: pixelY, width: pixelW, height: pixelH)

            let bg = BackgroundSampler.sampleBackgroundColor(image: original, normalizedBox: visionBox)
            context.setFillColor(red: bg.r, green: bg.g, blue: bg.b, alpha: 1.0)
            context.fill(blockRect.insetBy(dx: -2, dy: -1))

            let textColor: (r: Double, g: Double, b: Double) =
                BackgroundSampler.isLight(bg.r, bg.g, bg.b) ? (0, 0, 0) : (1, 1, 1)

            // 自适应字号
            var fontSize = pixelH * 0.7
            let text = translations[i]
            for _ in 0..<8 {
                let font = NSFont.systemFont(ofSize: fontSize)
                let size = (text as NSString).boundingRect(
                    with: CGSize(width: pixelW, height: .greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin],
                    attributes: [.font: font]
                )
                if size.height <= pixelH * 1.1 { break }
                fontSize *= 0.85
            }
            fontSize = max(fontSize, 8)

            drawText(
                text,
                inBlock: blockRect,
                fontSize: fontSize,
                textColor: textColor,
                context: context,
                imgHeight: imgH
            )
        }

        return context.makeImage()
    }

    private static func drawText(
        _ text: String,
        inBlock blockRect: CGRect,
        fontSize: CGFloat,
        textColor: (r: Double, g: Double, b: Double),
        context: CGContext,
        imgHeight: CGFloat
    ) {
        let nsColor = NSColor(red: textColor.r, green: textColor.g, blue: textColor.b, alpha: 1.0)
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .left
        paragraphStyle.lineBreakMode = .byWordWrapping

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize),
            .foregroundColor: nsColor,
            .paragraphStyle: paragraphStyle
        ]
        let attrStr = NSAttributedString(string: text, attributes: attributes)

        context.saveGState()
        context.translateBy(x: 0, y: imgHeight)
        context.scaleBy(x: 1, y: -1)

        let flippedY = imgHeight - blockRect.origin.y - blockRect.height
        let drawRect = CGRect(x: blockRect.origin.x, y: flippedY, width: blockRect.width, height: blockRect.height)

        NSGraphicsContext.saveGraphicsState()
        let nsCtx = NSGraphicsContext(cgContext: context, flipped: true)
        NSGraphicsContext.current = nsCtx
        attrStr.draw(with: drawRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], context: nil)
        NSGraphicsContext.restoreGraphicsState()

        context.restoreGState()
    }

    /// 保存图片到文件
    static func saveImage(_ image: CGImage, to url: URL, format: UTType) throws {
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL,
            format.identifier as CFString,
            1, nil
        ) else {
            throw NSError(domain: "ImageRenderer", code: 1, userInfo: [NSLocalizedDescriptionKey: "无法创建输出: \(url.lastPathComponent)"])
        }

        var properties: [CFString: Any] = [:]
        if format == .jpeg {
            properties[kCGImageDestinationLossyCompressionQuality] = 0.9
        }
        CGImageDestinationAddImage(dest, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            throw NSError(domain: "ImageRenderer", code: 2, userInfo: [NSLocalizedDescriptionKey: "保存失败: \(url.lastPathComponent)"])
        }
    }

    static func imageFormat(for url: URL) -> UTType {
        switch url.pathExtension.lowercased() {
        case "png": return .png
        case "jpg", "jpeg": return .jpeg
        case "tiff", "tif": return .tiff
        case "bmp": return .bmp
        case "gif": return .gif
        case "heic": return .heic
        default: return .png
        }
    }
}
