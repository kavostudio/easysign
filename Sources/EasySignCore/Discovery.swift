import Foundation

public struct SignatureEntry: Identifiable, Hashable, Sendable {
    public var id: URL { url }
    public let url: URL
    public let name: String
    public let excerpt: String
    public init(url: URL, name: String, excerpt: String) { self.url = url; self.name = name; self.excerpt = excerpt }
}

public enum SignatureDiscovery {
    /// Candidate locations only; version numbers and modification dates do not prove which one is active.
    public static func candidates(in mailRoot: URL) throws -> [URL] {
        let children = try FileManager.default.contentsOfDirectory(at: mailRoot, includingPropertiesForKeys: [.isDirectoryKey])
        return try children.filter {
            try $0.lastPathComponent.range(of: #"^V\d+$"#, options: .regularExpression) != nil &&
            (try $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true)
        }.compactMap { version in
            let candidate = version.appendingPathComponent("MailData/Signatures")
            do {
                let values = try candidate.resourceValues(forKeys: [.isDirectoryKey])
                return values.isDirectory == true ? candidate : nil
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
        }.sorted { $0.path < $1.path }
    }

    public static func signatures(in directory: URL) throws -> [SignatureEntry] {
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey])
        let metadata = directory.appendingPathComponent("AllSignatures.plist")
        var names: [String: [String]] = [:]
        if FileManager.default.fileExists(atPath: metadata.path),
           let value = try? PropertyListSerialization.propertyList(from: Data(contentsOf: metadata), format: nil),
           let rows = value as? [[String: Any]] {
            for row in rows {
                if let id = row["SignatureUniqueId"] as? String, let name = row["SignatureName"] as? String, !name.isEmpty {
                    names[id, default: []].append(name)
                }
            }
        }
        return files.filter { !$0.lastPathComponent.hasPrefix(".") && $0.pathExtension.lowercased() == "mailsignature" }.map { url in
            let id = url.deletingPathExtension().lastPathComponent
            let matches = names[id] ?? []
            let excerpt: String
            do {
                let document = try SignatureDocument(data: FileSnapshot(url: url).data)
                excerpt = String(document.html.replacingOccurrences(of: #"<[^>]*>"#, with: " ", options: .regularExpression)
                    .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines).prefix(90))
            } catch { excerpt = "Needs inspection — \(error.localizedDescription)" }
            return SignatureEntry(url: url, name: matches.count == 1 ? matches[0] : url.lastPathComponent, excerpt: excerpt)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
