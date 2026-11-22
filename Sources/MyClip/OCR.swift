import Foundation
import ImageIO
import Vision

/// 用系统 Vision 框架识别图片里的文字，完全在本机进行
enum OCR {
    /// 返回识别出的文字，按行分隔；没有文字或识别失败时返回空字符串
    static func recognize(_ url: URL) async -> String {
        await Task.detached(priority: .utility) {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return "" }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
            guard (try? VNImageRequestHandler(cgImage: image).perform([request])) != nil else { return "" }
            // 过滤掉把线条、色块误认成「-」之类的结果
            return (request.results ?? [])
                .compactMap { $0.topCandidates(1).first }
                .filter { $0.confidence >= 0.3 }
                .map(\.string)
                .filter { $0.contains(where: { $0.isLetter || $0.isNumber }) }
                .joined(separator: "\n")
        }.value
    }
}
