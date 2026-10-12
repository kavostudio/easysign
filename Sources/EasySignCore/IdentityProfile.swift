import Foundation

public struct IdentityProfile: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var label: String
    public var name: String
    public var email: String

    public init(id: UUID = UUID(), label: String = "", name: String = "", email: String = "") {
        self.id = id; self.label = label; self.name = name; self.email = email
    }

    public func validated() throws -> Self {
        var result = self
        result.label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        result.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        result.email = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.label.isEmpty, !result.name.isEmpty,
              !result.name.contains(where: { $0.isNewline || $0 == "<" || $0 == ">" || $0.asciiValue == 0 }),
              result.email.range(of: #"^[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?\.[A-Za-z]{2,}$"#, options: .regularExpression) != nil
        else { throw IdentityError.invalidProfile }
        return result
    }

    public var sender: String {
        let quotedName = name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(quotedName)\" <\(email)>"
    }
}

public enum IdentityError: LocalizedError {
    case invalidProfile
    public var errorDescription: String? { "Enter a profile label, sender name, and valid email address." }
}

public struct ProfileStore: Sendable {
    public let url: URL
    public init(url: URL) { self.url = url }
    public func load() throws -> [IdentityProfile] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let profiles = try JSONDecoder().decode([IdentityProfile].self, from: Data(contentsOf: url))
        guard Set(profiles.map(\.id)).count == profiles.count else { throw IdentityError.invalidProfile }
        return try profiles.map { try $0.validated() }
    }
    public func save(_ profiles: [IdentityProfile]) throws {
        let validated = try profiles.map { try $0.validated() }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(validated).write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

public enum MailDraftScript {
    public enum Action: Sendable { case newMessage, reply }
    public static func literal(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\r", with: "\\r").replacingOccurrences(of: "\n", with: "\\n") + "\""
    }
    public static func create(_ action: Action) -> String {
        switch action {
        case .newMessage:
            return "tell application \"Mail\"\nset d to make new outgoing message with properties {visible:true}\nreturn id of d\nend tell"
        case .reply:
            return """
            tell application "Mail"
                set selectedMessages to selection
                if (count of selectedMessages) is 0 then error "Select an email or conversation in Mail, then try Reply again."
                if (count of selectedMessages) is not 1 then error "Select one message or reopen the reply picker."
                set d to reply (item 1 of selectedMessages) with opening window
                return id of d
            end tell
            """
        }
    }
    public static let selection = """
    tell application "Mail"
        set rows to {}
        set selectedMessages to selection
        repeat with m in selectedMessages
            set end of rows to {id of m, sender of m, subject of m, (current date) - (date received of m)}
        end repeat
        return rows
    end tell
    """

    public static func reply(to id: Int) -> String {
        """
        tell application "Mail"
            repeat with m in (get selection)
                if id of m is \(id) then
                    set d to reply m with opening window
                    return id of d
                end if
            end repeat
            error "Mail’s selection changed. Select the conversation and try Reply again."
        end tell
        """
    }

    public static func apply(_ profile: IdentityProfile, id: Int) throws -> String {
        let profile = try profile.validated()
        return """
        tell application "Mail"
            set d to first outgoing message whose id is \(id)
            set sender of d to \(literal(profile.sender))
            if sender of d is not \(literal(profile.sender)) then error "Mail did not retain the identity. The draft remains open; check its sender before sending."
            activate
            return sender of d
        end tell
        """
    }
}

public struct ReplyMessage: Identifiable, Sendable {
    public let id: Int
    public let sender: String
    public let subject: String
    public let received: Date
    public init(id: Int, sender: String, subject: String, received: Date) {
        self.id = id; self.sender = sender; self.subject = subject; self.received = received
    }
    public static func newestFirst(_ messages: [Self]) -> [Self] {
        messages.sorted { $0.received == $1.received ? $0.id < $1.id : $0.received > $1.received }
    }
}
