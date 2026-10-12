import Foundation

public struct EasySignError: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// Parses a single MIME HTML part. Header bytes are never regenerated.
public struct SignatureDocument {
    public let headers: Data
    public let html: String
    public let charset: String
    public let transferEncoding: String
    private let stringEncoding: String.Encoding
    private let newline: String

    public init(data: Data, allowUnencodedQuotedPrintable: Bool = false) throws {
        guard data.count <= 10_000_000 else { throw EasySignError("Signature exceeds the 10 MB safety limit.") }
        let crlf = data.range(of: Data("\r\n\r\n".utf8))
        let lf = data.range(of: Data("\n\n".utf8))
        guard let separator = [crlf, lf].compactMap({ $0 }).min(by: { $0.lowerBound < $1.lowerBound }),
              separator.lowerBound < 65_536,
              let text = String(data: data[..<separator.lowerBound], encoding: .ascii) else {
            throw EasySignError("Unsupported signature: missing or invalid MIME headers.")
        }
        headers = Data(data[..<separator.upperBound])
        newline = crlf == separator ? "\r\n" : "\n"
        var fields: [String: String] = [:]
        var current: String?
        for line in text.components(separatedBy: newline) {
            if line.hasPrefix(" ") || line.hasPrefix("\t") {
                guard let current else { throw EasySignError("Invalid folded MIME header.") }
                fields[current, default: ""] += " " + line.trimmingCharacters(in: .whitespaces)
            } else {
                guard let colon = line.firstIndex(of: ":") else { throw EasySignError("Invalid MIME header.") }
                let key = line[..<colon].lowercased()
                guard !key.isEmpty, fields[key] == nil else { throw EasySignError("Duplicate or empty MIME header.") }
                fields[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                current = key
            }
        }
        guard let contentType = fields["content-type"],
              contentType.components(separatedBy: ";")[0].trimmingCharacters(in: .whitespaces).lowercased() == "text/html",
              fields["mime-version"]?.range(of: #"^1\.0(?:\s*\(.*\))?$"#, options: .regularExpression) != nil, fields["content-length"] == nil else {
            throw EasySignError("Only single-part text/html MIME 1.0 signatures without Content-Length are supported.")
        }
        let pattern = #"(?i)(?:^|;)\s*charset\s*=\s*(?:"([^"]+)"|([^;\s]+))"#
        let regex = try NSRegularExpression(pattern: pattern)
        guard let match = regex.firstMatch(in: contentType, range: NSRange(contentType.startIndex..., in: contentType)) else {
            throw EasySignError("No declared charset. EasySign will not guess the signature encoding.")
        }
        let range = match.range(at: match.range(at: 1).location == NSNotFound ? 2 : 1)
        guard let swiftRange = Range(range, in: contentType) else { throw EasySignError("Invalid charset.") }
        charset = String(contentType[swiftRange]).lowercased()
        switch charset {
        case "utf-8", "utf8": stringEncoding = .utf8
        case "us-ascii", "ascii": stringEncoding = .ascii
        case "iso-8859-1": stringEncoding = .isoLatin1
        case "windows-1252": stringEncoding = .windowsCP1252
        default: throw EasySignError("Unsupported charset: \(charset). The file has not been changed.")
        }
        transferEncoding = fields["content-transfer-encoding"]?.lowercased() ?? "7bit"
        let payload = Data(data[separator.upperBound...])
        let decoded: Data
        switch transferEncoding {
        case "7bit":
            guard payload.allSatisfy({ $0 < 128 }) else { throw EasySignError("Invalid non-ASCII bytes in a 7bit payload.") }
            decoded = payload
        case "8bit", "binary": decoded = payload
        case "quoted-printable":
            do { decoded = try Self.decodeQuotedPrintable(payload) }
            catch {
                guard allowUnencodedQuotedPrintable else { throw error }
                decoded = payload
            }
        case "base64":
            let compact = payload.filter { ![9, 10, 13, 32].contains($0) }
            guard let bytes = Data(base64Encoded: compact) else { throw EasySignError("Invalid base64 payload.") }
            decoded = bytes
        default: throw EasySignError("Unsupported content transfer encoding: \(transferEncoding).")
        }
        guard let source = String(data: decoded, encoding: stringEncoding),
              source.data(using: stringEncoding) == decoded else {
            throw EasySignError("Payload does not match its declared charset; refusing a lossy conversion.")
        }
        html = source
    }

    public func replacingHTML(_ source: String) throws -> Data {
        guard let bytes = source.data(using: stringEncoding, allowLossyConversion: false),
              String(data: bytes, encoding: stringEncoding) == source else {
            throw EasySignError("This HTML cannot be represented in the signature’s \(charset) charset.")
        }
        let payload: Data
        switch transferEncoding {
        case "base64":
            let encoded = Array(bytes.base64EncodedString())
            payload = Data(stride(from: 0, to: encoded.count, by: 76).map {
                String(encoded[$0..<min($0 + 76, encoded.count)])
            }.joined(separator: newline).utf8)
        case "quoted-printable":
            // Encoding every byte avoids changing line endings or trailing whitespace in the user's source.
            var lines: [String] = []
            var line = ""
            for byte in bytes {
                if line.count + 3 > 72 { lines.append(line + "="); line = "" }
                line += String(format: "=%02X", byte)
            }
            lines.append(line)
            payload = Data(lines.joined(separator: newline).utf8)
        case "7bit":
            guard bytes.allSatisfy({ $0 < 128 }) else { throw EasySignError("The original declares 7bit encoding, which cannot store this Unicode source without changing Mail’s headers.") }
            payload = bytes
        default: payload = bytes
        }
        let result = headers + payload
        guard try Self(data: result).html == source else { throw EasySignError("Encoded HTML failed verification.") }
        return result
    }

    private static func decodeQuotedPrintable(_ data: Data) throws -> Data {
        let bytes = Array(data)
        var output = Data()
        var index = 0
        while index < bytes.count {
            if bytes[index] != 61 { output.append(bytes[index]); index += 1; continue }
            if index + 1 < bytes.count, bytes[index + 1] == 10 { index += 2; continue }
            if index + 2 < bytes.count, bytes[index + 1] == 13, bytes[index + 2] == 10 { index += 3; continue }
            guard index + 2 < bytes.count,
                  let high = hex(bytes[index + 1]), let low = hex(bytes[index + 2]) else {
                throw EasySignError("Malformed quoted-printable payload.")
            }
            output.append(high * 16 + low)
            index += 3
        }
        return output
    }

    private static func hex(_ value: UInt8) -> UInt8? {
        switch value {
        case 48...57: return value - 48
        case 65...70: return value - 55
        case 97...102: return value - 87
        default: return nil
        }
    }

    public static func warnings(for html: String) -> [String] {
        var warnings: [String] = []
        let sourcePattern = #"(?i)\bsrc\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))"#
        if let regex = try? NSRegularExpression(pattern: sourcePattern) {
            let matches = regex.matches(in: html, range: NSRange(html.startIndex..., in: html))
            let hasLocalSource = matches.contains { match in
                let group = (1...3).first { match.range(at: $0).location != NSNotFound }
                guard let group, let range = Range(match.range(at: group), in: html) else { return false }
                let value = html[range].trimmingCharacters(in: .whitespacesAndNewlines)
                guard !value.isEmpty else { return false }
                let scheme = URL(string: value)?.scheme?.lowercased()
                return scheme == nil || scheme == "file" || scheme == "cid"
            }
            if hasLocalSource || html.range(of: #"(?i)url\(\s*["']?\s*(?:file:|/|\.\.?/)"#, options: .regularExpression) != nil {
                warnings.append("A local, relative, or cid source won’t be packaged with your signature. Use publicly accessible HTTPS URLs.")
            }
        }
        if html.range(of: #"(?i)<img\b(?![^>]*\bsrc\s*=)[^>]*>|<img\b[^>]*\bsrc\s*=\s*["']\s*["']"#, options: .regularExpression) != nil {
            warnings.append("An image has no source.")
        }
        return warnings
    }
}
