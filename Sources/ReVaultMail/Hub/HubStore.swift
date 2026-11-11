import Foundation
import Observation
import UserNotifications
import AppKit

/// Общие обсуждения писем на сервере Re:Vault: комментарии, участники, Револт внутри треда.
struct HubComment: Codable, Identifiable, Hashable {
    var id: Int
    var author: String
    var author_name: String?
    var kind: String          // user | agent | system
    var text: String
    var mentions: [String]?
    var created: Double
    /// На какой комментарий отвечает Револт (сервер ставит, если умеет).
    var reply_to: Int?

    var date: Date { Date(timeIntervalSince1970: created) }
    var isAgent: Bool { kind == "agent" }
    var name: String { (author_name?.isEmpty == false ? author_name! : author.components(separatedBy: "@").first ?? author) }
}

struct HubPerson: Codable, Hashable, Identifiable {
    var email: String
    var name: String?
    var role: String?
    var id: String { email }
    var display: String { (name?.isEmpty == false) ? name! : email.components(separatedBy: "@").first!.capitalized }
    var handle: String { role == "agent" ? "revolt" : email.components(separatedBy: "@").first!.lowercased() }
}

struct HubSnapshotMessage: Codable, Hashable {
    var id: String
    var from: String
    var to: String
    var date: String
    var ts: Double?
    var text: String
}

struct HubThread: Codable, Hashable {
    var key: String
    var subject: String
    var owner: String
    var account: String
    var messages: [HubSnapshotMessage]
    var updated: Double
}

struct HubThreadInfo: Codable, Hashable, Identifiable {
    struct Last: Codable, Hashable {
        var id: Int; var author_name: String?; var text: String; var created: Double; var kind: String
        var author: String?
        var mentions: [String]?
    }
    var key: String
    var subject: String
    var owner: String
    var account: String
    var updated: Double
    var comments: Int
    var members: [String]
    var last: Last?
    var unread: Bool
    var id: String { key }
}

private struct ThreadPayload: Codable {
    var thread: HubThread?
    var comments: [HubComment]
    var members: [HubPerson]
    var agent: String?
}

@Observable
@MainActor
final class HubStore {
    // The standalone edition has no shared server or team account.
    var me: HubPerson?
    var people: [HubPerson] = []
    var threads: [HubThreadInfo] = []
    var comments: [String: [HubComment]] = [:]
    var members: [String: [HubPerson]] = [:]
    var snapshots: [String: HubThread] = [:]
    var agentStatus: [String: String] = [:]
    var error: String?
    var notice: String?
    let online = false
    let reconnecting = false
    let isOwner = false
    nonisolated static let notificationPrefix = "hub:"
    static func key(_ k: ThreadKey) -> String { k.account + "/" + k.threadID }
    func attach(_ mail: MailStore) {}
    func bootstrap() async {}
    func loadThreads() async {}
    func open(_ key: ThreadKey?) {}
    func loadThread(_ key: String) async {}
    struct ClassifyItem: Encodable { var id: String; var from: String; var to: String; var subject: String; var snippet: String }
    func classify(_ items: [ClassifyItem]) async -> [String: Double] { [:] }
    func translate(_ text: String, to lang: String) async -> (text: String?, error: String?) { (nil, nil) }
    func cancel(key: String) async -> Bool { false }
    func cancel(thread key: ThreadKey) async {}
    func postRaw(key: String, text: String, model: String? = nil, effort: String? = nil) async -> Int? { nil }
    func fetchRaw(key: String, after: Int) async -> ([HubComment], String?) { ([], nil) }
    func comment(_ text: String, on detail: ThreadDetail) async -> Bool { false }
    func invite(email: String, name: String, to detail: ThreadDetail) async -> Bool { false }
    func removeMember(_ email: String, from key: ThreadKey) async -> Bool { false }
    func pushSnapshot(_ d: ThreadDetail) async {}
    func syncIfDiscussed(_ d: ThreadDetail) {}
    func snapshotDetail(_ key: ThreadKey) -> ThreadDetail? { nil }
    func threadKey(from key: String) -> ThreadKey? {
        guard let slash = key.lastIndex(of: "/") else { return nil }
        return ThreadKey(account: String(key[..<slash]), threadID: String(key[key.index(after: slash)...]))
    }
}
