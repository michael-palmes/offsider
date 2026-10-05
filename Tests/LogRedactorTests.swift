import Foundation
import OffsiderCore
import Testing

@Suite("Log redactor")
struct LogRedactorTests {
    @Test("sensitive values are masked and the text keeps its shape", arguments: [
        (#"{"password":"p\"w","user":"ada"}"#, #"{"password":"[redacted]","user":"ada"}"#),
        ("{ password: 'x' }", "{ password: '[redacted]' }"),
        ("POST /login password=abc&next=1", "POST /login password=[redacted]&next=1"),
        ("accessToken: abc.def-123", "accessToken: [redacted]"),
        ("refresh_token=r1 expires_in=3600", "refresh_token=[redacted] expires_in=3600"),
        ("x-api-key: k-123456", "x-api-key: [redacted]"),
        ("apiKey=k-123456", "apiKey=[redacted]"),
        ("Authorization: Basic dXNlcjpwYXNzd29yZA==", "Authorization: [redacted]"),
        ("cookie: sid=1; theme=dark, next", "cookie: [redacted], next"),
        ("sending Bearer abcdefgh12345 now", "sending Bearer [redacted] now"),
        ("jwt eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.sig_nature", "jwt [redacted jwt]"),
        ("signed in as e2e@example.com today", "signed in as [redacted email] today"),
        (#"{"email":"e2e@example.com","pin": 1234}"#, #"{"email":"[redacted]","pin": "[redacted]"}"#),
        ("otp=123456 secret: s3cr3t", "otp=[redacted] secret: [redacted]"),
    ])
    func masked(input: String, expected: String) {
        let result = LogRedactor.redact(input)
        #expect(result.text == expected)
        #expect(result.count > 0)
    }

    @Test("ordinary values are left alone", arguments: [
        #"tokenType: "Bearer""#,
        "emailVerified: true",
        "ticketId: 5",
        "react-native@0.81.0 loaded",
        "open https://x.com/a@b",
        "token: {expires: 3}",
        "password: null",
        "spinner: on, pinned: yes",
        "Basic auth",
        "nothing to see",
    ])
    func leftAlone(input: String) {
        let result = LogRedactor.redact(input)
        #expect(result.text == input)
        #expect(result.count == 0)
    }

    @Test("JSON with redacted values still parses")
    func jsonStillParses() throws {
        let text = LogRedactor.redact(#"{"pin": 1234, "password": "p\"w", "nested": {"token": 9}}"#).text
        let object = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        #expect(object["pin"] as? String == "[redacted]")
        #expect(object["password"] as? String == "[redacted]")
        #expect((object["nested"] as? [String: Any])?["token"] as? String == "[redacted]")
    }

    @Test("redacting twice changes nothing more and counts nothing more")
    func idempotent() {
        let once = LogRedactor.redact(#"Authorization: Bearer abcdefgh123 {"password":"x","email":"a@b.co"} eyJabcdefghij.eyJabcdefghij.x z@y.io"#)
        let twice = LogRedactor.redact(once.text)
        #expect(twice.text == once.text)
        #expect(twice.count == 0)
    }

    @Test("keys split into camel, snake, kebab and dot segments")
    func segments() {
        #expect(LogRedactor.isSensitive(key: "user.accessToken"))
        #expect(LogRedactor.isSensitive(key: "X_API_KEY"))
        #expect(LogRedactor.isSensitive(key: "xAPIKey"))
        #expect(!LogRedactor.isSensitive(key: "tokenExpiresAt"))
        #expect(!LogRedactor.isSensitive(key: "apiVersion"))
    }
}
