import AppKit
import EasySignCore

@MainActor
final class AccessStore {
    let support: URL
    private var scoped: [URL] = []
    private var bookmarks: [Data] = []
    private var preferences: URL { support.appendingPathComponent("Access.plist") }

    init() {
        support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("EasySign", isDirectory: true)
    }

    func restore() throws -> [URL] {
        guard FileManager.default.fileExists(atPath: preferences.path) else { return [] }
        bookmarks = try PropertyListDecoder().decode([Data].self, from: Data(contentsOf: preferences))
        var urls: [URL] = []
        var renewed: [Data] = []
        for bookmark in bookmarks {
            var stale = false
            let url = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale)
            if url.startAccessingSecurityScopedResource() { scoped.append(url) }
            urls.append(url)
            renewed.append(stale ? try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil) : bookmark)
        }
        bookmarks = renewed
        try save()
        return urls
    }

    func remember(_ url: URL) throws {
        if url.startAccessingSecurityScopedResource() { scoped.append(url) }
        bookmarks.append(try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil))
        try save()
    }

    private func save() throws {
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try PropertyListEncoder().encode(bookmarks).write(to: preferences, options: .atomic)
    }
}
