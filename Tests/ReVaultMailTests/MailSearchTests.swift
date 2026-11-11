import Foundation

private var assertions = 0
func XCTAssertEqual<T: Equatable>(_ a: T, _ b: T) { assertions += 1; precondition(a == b, "Expected \(b), got \(a)") }
func XCTAssertTrue(_ value: Bool) { assertions += 1; precondition(value) }
func XCTAssertNil<T>(_ value: T?, _ message: String) { assertions += 1; precondition(value == nil, message) }

@main
struct MailSearchTests {
    static func main() {
        let suite = MailSearchTests()
        suite.testBareAddressSearchesContentAndAllParticipants()
        suite.testNameAlsoFindsKnownAddress()
        suite.testExplicitOperatorsNeverBroadenToOtherFields()
        suite.testAdvancedGmailSyntaxIsPreserved()
        suite.testQuotedPhraseRemainsOneTerm()
        suite.testEmptyQueryRestoresMailbox()
        suite.testSearchIsNotRestrictedToInboxSentOrArchive()
        suite.testPickingPersonDoesNotInventFromFilter()
        suite.testPickingPersonPreservesExplicitFieldAndOtherFilters()
        suite.testPickingUnqualifiedPersonKeepsOtherFilters()
        suite.testAutocompleteUsesFullNamesAndRejectsIncompleteOperators()
        suite.testContactExpansionIsDeterministicAndDoesNotInjectSyntax()
        suite.testAutomaticSearchWaitsForCompleteQuery()
        suite.testInterfaceScaleLimits()
        suite.testLayoutAcrossAllInterfaceSizes()
        print("PASS: 15 search/layout scenarios, \(assertions) assertions")
    }

    func testBareAddressSearchesContentAndAllParticipants() {
        let email = "solon@freshfounders.com"
        let q = MailSearch.gmailQuery("  " + email + "  ")
        XCTAssertEqual(q, "{\(email) from:\(email) to:\(email) cc:\(email) bcc:\(email)}")
    }

    func testNameAlsoFindsKnownAddress() {
        let q = MailSearch.gmailQuery("Solon Angel", matchingEmails: ["solon@freshfounders.com"])
        XCTAssertTrue(q.contains("from:Solon"))
        XCTAssertTrue(q.contains("to:Angel"))
        XCTAssertTrue(q.contains("from:solon@freshfounders.com"))
        XCTAssertTrue(q.contains("to:solon@freshfounders.com"))
    }

    func testExplicitOperatorsNeverBroadenToOtherFields() {
        for q in ["from:solon@freshfounders.com", "to:solon@freshfounders.com", "cc:Solon", "bcc:Solon",
                  "from:\"Solon Angel\"", "to: Solon", "subject:invoice has:attachment", "after:2026/10/01 Solon"] {
            XCTAssertEqual(MailSearch.gmailQuery(q, matchingEmails: ["solon@freshfounders.com"]), q)
        }
    }

    func testAdvancedGmailSyntaxIsPreserved() {
        for q in ["{from:a@example.com to:b@example.com}", "(Solon OR Angel)", "Solon -invoice", "Solon OR Angel",
                  "label:\"Client work\" is:unread", "in:anywhere filename:pdf", "+Solon", "invoice AROUND 5 payment"] {
            XCTAssertEqual(MailSearch.gmailQuery(q), q)
        }
    }

    func testQuotedPhraseRemainsOneTerm() {
        XCTAssertEqual(MailSearch.tokens("from:\"Solon Angel\" has:attachment"), ["from:\"Solon Angel\"", "has:attachment"])
        XCTAssertEqual(MailSearch.gmailQuery("\"Solon Angel\""), "{\"Solon Angel\" from:\"Solon Angel\" to:\"Solon Angel\" cc:\"Solon Angel\" bcc:\"Solon Angel\"}")
    }

    func testEmptyQueryRestoresMailbox() {
        XCTAssertEqual(MailSearch.gmailQuery(" \n\t"), "")
        XCTAssertEqual(MailSearch.label(mailbox: "INBOX", query: ""), "INBOX")
        XCTAssertEqual(MailSearch.label(mailbox: "IMPORTANT_RV", query: ""), "INBOX")
    }

    func testSearchIsNotRestrictedToInboxSentOrArchive() {
        for box in ["INBOX", "SENT", "DRAFT", "ALL", "IMPORTANT_RV", "SNOOZED"] {
            XCTAssertEqual(MailSearch.label(mailbox: box, query: "Solon"), "ALL")
        }
    }

    func testPickingPersonDoesNotInventFromFilter() {
        for text in ["Solon", "Solon Angel", "solon@freshfounders.com", " Solon Angel"] {
            XCTAssertEqual(MailSearch.picking(email: "solon@freshfounders.com", in: text), "solon@freshfounders.com")
            XCTAssertEqual(MailSearch.suggestionOperator(in: text), "")
        }
    }

    func testPickingPersonPreservesExplicitFieldAndOtherFilters() {
        for op in ["from:", "to:", "cc:", "bcc:"] {
            for text in [op + "Solon", op + "\"Solon Angel\"", op + " Solon"] {
                XCTAssertEqual(MailSearch.picking(email: "solon@example.com", in: text), op + "solon@example.com")
            }
            XCTAssertEqual(MailSearch.picking(email: "solon@example.com", in: "has:attachment " + op + "Solon"), "has:attachment " + op + "solon@example.com")
        }
    }

    func testPickingUnqualifiedPersonKeepsOtherFilters() {
        XCTAssertEqual(MailSearch.picking(email: "solon@example.com", in: "is:unread Solon"), "is:unread solon@example.com")
    }

    func testAutocompleteUsesFullNamesAndRejectsIncompleteOperators() {
        XCTAssertEqual(MailSearch.term(in: "Solon Angel"), "Solon Angel")
        XCTAssertEqual(MailSearch.term(in: "from:\"Solon Angel\""), "Solon Angel")
        XCTAssertEqual(MailSearch.term(in: "to: Solon"), "Solon")
        for text in ["from:", "has:attachment", "a", "Solon ", "-Solon", "(Solon)"] {
            XCTAssertNil(MailSearch.term(in: text), text)
        }
    }

    func testContactExpansionIsDeterministicAndDoesNotInjectSyntax() {
        let a = MailSearch.gmailQuery("Solon", matchingEmails: ["b@example.com", "a@example.com", "b@example.com", "bad@example.com} OR from:boss"])
        let b = MailSearch.gmailQuery("Solon", matchingEmails: ["a@example.com", "b@example.com"])
        XCTAssertEqual(a, b)
    }

    func testAutomaticSearchWaitsForCompleteQuery() {
        for query in ["", "Solon", "Solon Angel", "solon@example.com", "from:solon@example.com", "from:\"Solon Angel\"", "{from:a to:b}"] {
            XCTAssertTrue(MailSearch.readyForAutomaticSearch(query))
        }
        for query in ["s", "from:", "to: ", "from:\"Solon", "(Solon", "{from:a", "Solon OR", "Solon)"] {
            XCTAssertTrue(!MailSearch.readyForAutomaticSearch(query))
        }
    }

    func testInterfaceScaleLimits() {
        XCTAssertEqual(InterfaceMetrics.clamp(0.1), 0.8)
        XCTAssertEqual(InterfaceMetrics.clamp(5), 1.4)
        XCTAssertEqual(InterfaceMetrics.clamp(.nan), 1)
        XCTAssertEqual(InterfaceMetrics.clamp(.infinity), 1)
        XCTAssertEqual(InterfaceMetrics.clamp(1.09), 1.1)
    }

    func testLayoutAcrossAllInterfaceSizes() {
        for scale in InterfaceMetrics.scales {
            for window in [1100.0, 1280, 1440, 1920] {
                for showAgent in [true, false] {
                    for sidebar in [true, false] {
                        let total = window / scale
                        let l = InterfaceMetrics.layout(total: total, showSidebar: sidebar, side: 380, list: 720, showAgent: showAgent, agent: 760)
                        let handles = 7.0 + (l.sidebar > 0 ? 7 : 0) + (l.agent > 0 ? 7 : 0)
                        XCTAssertTrue(l.sidebar + l.list + l.agent + l.detail + handles + 45 <= total + 0.01)
                        XCTAssertTrue(l.detail >= 380)
                        XCTAssertTrue(l.list >= 280)
                    }
                }
            }
        }
    }

}
