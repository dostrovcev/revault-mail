import Foundation

/// Query policy shared by the search field, suggestions and Gmail pagination.
enum MailSearch {
    static let peopleOperators = ["from:", "to:", "cc:", "bcc:"]

    // Keep quoted phrases together. Advanced Gmail expressions pass through unchanged.
    static func tokens(_ text: String) -> [String] {
        var result: [String] = [], token = "", quoted = false, escaped = false
        for c in text {
            if c == "\"", !escaped { quoted.toggle() }
            if c.isWhitespace && !quoted {
                if !token.isEmpty { result.append(token); token = "" }
            } else { token.append(c) }
            escaped = c == "\\" && !escaped
        }
        if !token.isEmpty { result.append(token) }
        return result
    }

    static func isPlain(_ text: String) -> Bool {
        let words = tokens(text)
        return !words.isEmpty && !words.contains {
            $0.contains(":") || $0.contains(where: { "{}()".contains($0) }) ||
            $0.hasPrefix("-") || $0.hasPrefix("+") || ["OR", "AND", "NOT", "AROUND"].contains($0)
        }
    }

    static func gmailQuery(_ text: String, matchingEmails: [String] = []) -> String {
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Explicit filters must never become alternatives to the person's address.
        guard isPlain(q) else { return q }
        let terms = tokens(q)
        let allFields = terms.map { term in
            "{" + ([term] + peopleOperators.map { $0 + term }).joined(separator: " ") + "}"
        }.joined(separator: " ")
        let emails = Array(Set(matchingEmails.filter { email in
            email.contains("@") && !email.contains(where: { $0.isWhitespace || "\"{}():".contains($0) })
        })).sorted()
        guard !emails.isEmpty else { return allFields }
        return "{(" + allFields + ") " + emails.flatMap { email in peopleOperators.map { $0 + email } }.joined(separator: " ") + "}"
    }

    static func suggestionOperator(in text: String) -> String {
        let words = tokens(text)
        let last = words.last?.lowercased() ?? ""
        if let op = peopleOperators.first(where: { last.hasPrefix($0) }) { return op }
        if words.count > 1, let op = peopleOperators.first(where: { words[words.count - 2].lowercased() == $0 }) { return op }
        return ""
    }

    static func term(in text: String) -> String? {
        guard text.last?.isWhitespace != true else { return nil }
        var term: String
        if isPlain(text) { term = text.trimmingCharacters(in: .whitespacesAndNewlines) }
        else {
            term = tokens(text).last ?? ""
            let op = suggestionOperator(in: text)
            if !op.isEmpty, term.lowercased().hasPrefix(op) { term = String(term.dropFirst(op.count)) }
        }
        term = term.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        guard term.count >= 2, !term.contains(where: { ":{}()".contains($0) }), !term.hasPrefix("-") else { return nil }
        return term
    }

    static func picking(email: String, in text: String) -> String {
        if isPlain(text) { return email }
        var words = tokens(text)
        let op = suggestionOperator(in: text)
        if !words.isEmpty { words.removeLast() }
        if words.last?.lowercased() == op { words.removeLast() }
        words.append(op + email)
        return words.joined(separator: " ")
    }

    /// Wait for a complete term; never query half an operator or an open quote/group.
    static func readyForAutomaticSearch(_ text: String) -> Bool {
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty { return true }
        guard q.count >= 2, !q.hasSuffix(":"), q.filter({ $0 == "\"" }).count.isMultiple(of: 2) else { return false }
        var round = 0, curly = 0, quoted = false
        for c in q {
            if c == "\"" { quoted.toggle() }
            if quoted { continue }
            if c == "(" { round += 1 }; if c == ")" { round -= 1 }
            if c == "{" { curly += 1 }; if c == "}" { curly -= 1 }
            if round < 0 || curly < 0 { return false }
        }
        return round == 0 && curly == 0 && !["OR", "AND", "NOT"].contains(tokens(q).last ?? "")
    }

    /// Search spans Inbox, Sent and Archive, with account selection retained.
    static func label(mailbox: String, query: String) -> String {
        if !query.isEmpty { return "ALL" }
        return mailbox == "IMPORTANT_RV" ? "INBOX" : mailbox
    }
}
