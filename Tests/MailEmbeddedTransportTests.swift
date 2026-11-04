import Foundation

@main
struct MailEmbeddedTransportTests {
    static var assertions = 0
    static func expect(_ condition: @autoclosure () -> Bool, _ name: String) {
        assertions += 1
        guard condition() else { fatalError("FAIL: \(name)") }
    }
    static func main() async throws {
        expect(MailTransport.decodeHeader("=?UTF-8?B?5rWL6K+V?= =?UTF-8?B?6YKu5Lu2?=") == "测试邮件", "adjacent encoded headers")
        expect(MailTransport.decodeHeader("=?ISO-8859-1?Q?Andr=E9?=") == "André", "legacy header charset")
        expect(MailTransport.decodeModifiedUTF7("&ZcWITA- &- INBOX") == "旅行 & INBOX", "modified UTF7")
        expect(MailTransport.parameter("filename", in: "attachment; filename*=UTF-8''%E6%B5%8B%E8%AF%95.pdf") == "测试.pdf", "RFC2231 attachment name")
        expect(MailTransport.parameter("filename", in: "attachment; filename*0*=UTF-8''%E6%B5%8B; filename*1*=%E8%AF%95.pdf") == "测试.pdf", "RFC2231 continuation")
        expect(MailTransport.sanitizeFilename("../a\\b\u{0}.pdf") == ".._a_b.pdf", "attachment traversal sanitization")
        let original = TransportOutgoing(from: "sender@example.invalid", fromName: "测试发件人", to: ["to@example.invalid"], cc: ["cc@example.invalid"], bcc: ["secret@example.invalid"], subject: "中文附件测试", body: "第一行\n第二行", attachments: [TransportAttachment(filename: "实验结果.txt", mimeType: "text/plain", data: Data("秘密附件内容\n".utf8))], inReplyTo: "<test@example.invalid>")
        let encoded = try MailTransport.encode(original)
        let text = String(decoding: encoded, as: UTF8.self)
        expect(!text.contains("secret@example.invalid") && !text.contains("Bcc:"), "Bcc envelope privacy")
        let parsed = MailTransport.parseMIME(encoded)
        expect(parsed.text == "第一行\r\n第二行", "outgoing unicode body roundtrip")
        expect(parsed.attachments.count == 1, "multipart attachment count")
        expect(parsed.attachments.first?.filename == "实验结果.txt", "outgoing unicode filename roundtrip")
        expect(parsed.attachments.first?.data == original.attachments[0].data, "attachment byte integrity")
        expect(MailTransport.decodeHeader(MailTransport.parseHeaders(encoded).headers["subject"] ?? "") == original.subject, "subject roundtrip")
        var longFile = original
        longFile.attachments[0].filename = String(repeating: "实验数据", count: 30) + ".txt"
        let longFileMIME = try MailTransport.encode(longFile)
        expect(MailTransport.parseMIME(longFileMIME).attachments[0].filename == longFile.attachments[0].filename, "long RFC2231 filename roundtrip")
        expect(String(decoding: longFileMIME, as: UTF8.self).components(separatedBy: "\r\n").allSatisfy { $0.utf8.count < 998 }, "RFC line length bound")
        let long = String(repeating: "测试😀", count: 80)
        var longer = original
        longer.subject = long
        let longEncoded = try MailTransport.encode(longer)
        expect(MailTransport.decodeHeader(MailTransport.parseHeaders(longEncoded).headers["subject"] ?? "") == long, "folded long unicode subject")
        var injection = original
        injection.subject = "Test\r\nBcc: victim@example.invalid"
        do { _ = try MailTransport.encode(injection); fatalError("Header injection accepted") } catch { assertions += 1 }
        let folders = MailTransport.parseFolders(Data("* LIST (\\HasNoChildren) \"/\" \"INBOX\"\r\n* LIST (\\Sent) \"/\" \"&XfJT0ZAB-\"\r\n* LIST (\\Noselect) NIL \"Root\"\r\n".utf8))
        expect(folders.count == 3 && folders[1].displayName == "已发送" && !folders[2].selectable, "folder flags and unicode names")
        let fixture = "Date: Tue, 06 Oct 2026 18:20:00 +0800\r\nFrom: Test <from@example.invalid>\r\nTo: to@example.invalid\r\nSubject: =?UTF-8?B?5rWL6K+V?=\r\nContent-Type: multipart/alternative; boundary=abc\r\n\r\n--abc\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Transfer-Encoding: quoted-printable\r\n\r\nHello=20world\r\n--abc\r\nContent-Type: text/html; charset=utf-8\r\n\r\n<p>Hello world</p>\r\n--abc--\r\n"
        let response = Data("* 1 FETCH (UID 12 FLAGS (\\Seen \\Flagged) INTERNALDATE \"06-Oct-2026 18:20:00 +0800\" RFC822.SIZE \(fixture.utf8.count) BODY[] {\(fixture.utf8.count)}\r\n\(fixture))\r\n".utf8)
        let messages = MailTransport.parseFetch(response, bodyLoaded: true)
        expect(messages.count == 1 && messages[0].uid == 12 && messages[0].isRead && messages[0].isFlagged, "FETCH UID and flags")
        expect(messages[0].body == "Hello world" && messages[0].html == "<p>Hello world</p>", "nested alternative plaintext and HTML")
        expect(messages[0].subject == "测试" && messages[0].date > Date(timeIntervalSince1970: 1_000_000_000), "FETCH date and decoded subject")
        if CommandLine.arguments.count > 3 {
            let ca = CommandLine.arguments[1]
            let port = Int(CommandLine.arguments[2])!, smtpPort = Int(CommandLine.arguments[3])!
            let connection = TransportConnection(imapHost: "localhost", imapPort: port, smtpHost: "localhost", smtpPort: smtpPort, username: "test@example.invalid", password: "test-pass", trustedCAFile: ca)
            try await MailTransport.testConnection(connection)
            let serverFolders = try await MailTransport.listFolders(connection)
            expect(serverFolders.contains { $0.path == "Sent" }, "real TLS IMAP LIST")
            let serverMessages = try await MailTransport.fetchMessages(connection, folder: "INBOX", limit: 1)
            expect(serverMessages.count == 1 && serverMessages[0].uid == 12 && serverMessages[0].uidValidity == 42, "real TLS IMAP SEARCH FETCH")
            expect(serverMessages[0].subject == "测试邮件" && serverMessages[0].replyTo == "reply@example.invalid" && !serverMessages[0].bodyLoaded, "real header decoding")
            let detail = try await MailTransport.fetchMessage(connection, folder: "INBOX", uid: 12)
            expect(detail.body == "Hello from local TLS IMAP.", "real lazy MIME body fetch")
            try await MailTransport.setRead(connection, folder: "INBOX", uids: [12], read: true, expectedUIDValidity: 42)
            try await MailTransport.setFlagged(connection, folder: "INBOX", uids: [12], flagged: true)
            try await MailTransport.move(connection, folder: "INBOX", uid: 12, destination: "Trash")
            do { try await MailTransport.setRead(connection, folder: "INBOX", uids: [999], read: true, expectedUIDValidity: 41); fatalError("Stale validity store accepted") }
            catch TransportError.server { assertions += 1 }
            do { _ = try await MailTransport.fetchMessage(connection, folder: "INBOX", uid: 999, expectedUIDValidity: 41); fatalError("Stale validity fetch accepted") }
            catch TransportError.server { assertions += 1 }
            do { try await MailTransport.move(connection, folder: "INBOX", uid: 999, destination: "Trash", expectedUIDValidity: 41); fatalError("Stale validity move accepted") }
            catch TransportError.server { assertions += 1 }
            if CommandLine.arguments.count > 5 {
                var startTLS = connection
                startTLS.imapPort = Int(CommandLine.arguments[4])!
                startTLS.smtpPort = Int(CommandLine.arguments[5])!
                startTLS.imapSecurity = .startTLS
                startTLS.smtpSecurity = .startTLS
                try await MailTransport.testConnection(startTLS)
                let startMessages = try await MailTransport.fetchMessages(startTLS, folder: "INBOX", limit: 1)
                expect(startMessages.count == 1 && startMessages[0].uidValidity == 42, "STARTTLS upgraded IMAP+SMTP")
            }
            let sent = try await MailTransport.send(connection, message: original, sentFolder: "Sent")
            expect(sent.deliveredToServer && sent.sentCopyWarning == nil, "SMTP accepted and IMAP sent append")
            var rejected = original
            rejected.to = ["to@example.invalid", "reject@example.invalid"]
            do { _ = try await MailTransport.send(connection, message: rejected); fatalError("Partial recipient failure accepted") }
            catch TransportError.server { assertions += 1 }
            var disconnected = original
            disconnected.to = ["drop@example.invalid"]
            do { _ = try await MailTransport.send(connection, message: disconnected); fatalError("Lost SMTP final response accepted") }
            catch TransportError.sendUncertain { assertions += 1 }
            var rejectedData = original
            rejectedData.to = ["rejectdata@example.invalid"]
            do { _ = try await MailTransport.send(connection, message: rejectedData); fatalError("Rejected DATA accepted") }
            catch TransportError.server { assertions += 1 }
            let missingSent = try await MailTransport.send(connection, message: original, sentFolder: "FailSent")
            expect(missingSent.deliveredToServer && missingSent.sentCopyWarning != nil, "append failure keeps SMTP success")
            var invalidCA = connection
            invalidCA.trustedCAFile = nil
            do { _ = try await MailTransport.listFolders(invalidCA); fatalError("Untrusted TLS accepted") }
            catch TransportError.certificate { assertions += 1 }
            var wrongPassword = connection
            wrongPassword.password = "incorrect"
            do { _ = try await MailTransport.listFolders(wrongPassword); fatalError("Bad password accepted") }
            catch TransportError.authentication { assertions += 1 }
            print("PASS: local TLS IMAP/SMTP integration, certificate rejection and authentication rejection")
        }
        print("PASS: \(assertions) transport assertions")
    }
}
