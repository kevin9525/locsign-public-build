import Foundation
import XKit

// Closed categories only: never retain a decoding context or server-provided text.
enum CertificateResponseProblem: Sendable, Equatable {
    case envelope, missingRequest, missingContent, contentType, emptyContent
    case oversizedContent, encoding, x509, ambiguousContent

    var message: String {
        switch self {
        case .envelope: return "响应格式或结果状态无法读取（C01）"
        case .missingRequest: return "响应中未找到有效的证书记录（C02）"
        case .missingContent: return "证书记录中缺少证书内容（C03）"
        case .contentType: return "证书内容的数据类型无法识别（C04）"
        case .emptyContent: return "返回的证书内容为空（C05）"
        case .oversizedContent: return "返回的证书内容超过大小限制（C06）"
        case .encoding: return "证书的 PEM 或 Base64 编码无效（C07）"
        case .x509: return "证书内容无法解析为有效的 X.509 证书（C08）"
        case .ambiguousContent: return "响应包含多个证书内容字段，无法确定使用哪一个（C09）"
        }
    }
}

enum CertificateResponseDecoder {
    static func decode(_ content: Data) throws -> Data {
        guard !content.isEmpty else { throw failure(.emptyContent) }
        guard content.count <= 1_048_576 else { throw failure(.oversizedContent) }
        let der: Data
        if content.first == 0x30 {
            // DER certificates start with a SEQUENCE. The X.509 parser below
            // requires the entire input to be a single complete certificate.
            der = content
        } else {
            guard let text = String(data: content, encoding: .utf8) else { throw failure(.x509) }
            let trimmed = text.trimmingCharacters(in: CharacterSet(charactersIn: " \t\r\n"))
            guard !trimmed.isEmpty else { throw failure(.emptyContent) }
            let begin = "-----BEGIN CERTIFICATE-----"
            let end = "-----END CERTIFICATE-----"
            if trimmed.hasPrefix(begin) {
                guard trimmed.hasSuffix(end) else { throw failure(.encoding) }
                let body = trimmed.dropFirst(begin.count).dropLast(end.count)
                der = try base64(String(body))
            } else {
                der = try base64(trimmed)
            }
        }
        guard (try? XKit.Certificate(data: der)) != nil else { throw failure(.x509) }
        return der
    }

    private static func base64(_ text: String) throws -> Data {
        // Remove only ASCII whitespace. Unknown characters, extra PEM blocks,
        // and leading/trailing labels must not be silently ignored.
        let bytes = text.utf8.filter { ![UInt8(9), 10, 13, 32].contains($0) }
        guard let data = Data(base64Encoded: Data(bytes)), !data.isEmpty else { throw failure(.encoding) }
        return data
    }

    private static func failure(_ problem: CertificateResponseProblem) -> DeveloperServicesError {
        .certificateResponse(problem)
    }
}
