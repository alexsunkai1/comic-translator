import Foundation
import Vision
import CoreGraphics

struct OCRResult: Sendable {
    let text: String
    let boundingBox: CGRect
    let confidence: Float
}

/// CGImage 线程安全包装（CGImage 本身不可变，读取线程安全）
struct SendableImage: @unchecked Sendable {
    let image: CGImage
}

struct OCREngine: Sendable {
    /// 在后台线程执行 Vision OCR，避免阻塞主线程
    func recognize(image: CGImage, languages: [String]) async throws -> [OCRResult] {
        guard image.width > 10, image.height > 10 else { return [] }

        let boxed = SendableImage(image: image)
        return try await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLanguages = languages
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true

            let handler = VNImageRequestHandler(cgImage: boxed.image, orientation: .up, options: [:])
            try handler.perform([request])

            let observations = request.results ?? []
            return observations.compactMap { obs -> OCRResult? in
                guard let candidate = obs.topCandidates(1).first,
                      candidate.confidence > 0.3 else { return nil }
                return OCRResult(
                    text: candidate.string,
                    boundingBox: obs.boundingBox,
                    confidence: candidate.confidence
                )
            }
        }.value
    }
}
