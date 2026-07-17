import Foundation
import PaceCore
import Vision

struct OCRService: Sendable {
    func recognizeText(in imageData: Data) async throws -> [OCRObservation] {
        try await Task.detached(priority: .utility) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.minimumTextHeight = 0.01

            let handler = VNImageRequestHandler(data: imageData, options: [:])
            try handler.perform([request])
            return (request.results ?? []).compactMap { observation in
                guard let candidate = observation.topCandidates(1).first else { return nil }
                let box = observation.boundingBox
                return OCRObservation(
                    text: candidate.string,
                    confidence: candidate.confidence,
                    x: box.origin.x,
                    y: box.origin.y,
                    width: box.width,
                    height: box.height
                )
            }.sorted { lhs, rhs in
                if abs(lhs.y - rhs.y) < 0.025 { return lhs.x < rhs.x }
                return lhs.y > rhs.y
            }
        }.value
    }
}
