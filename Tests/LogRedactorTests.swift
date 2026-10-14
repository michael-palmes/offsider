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
        ("cc a.b@sub.example.co.uk, first+tag@example.com", "cc [redacted email], [redacted email]"),
        ("host user@localhost.local", "host [redacted email]"),
        ("mail a@163.com or b@1und1.de", "mail [redacted email] or [redacted email]"),
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
        "expo-dev-client@6.0.0-canary.rc",
        "pkg@1.2.3-beta.rc",
        "installed expo-dev-client@6.0.0-canary.rc and @expo/cli@0.24.1-beta.rc2",
        "react-native-reanimated@4.1.0-nightly-20261001.abc",
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

    @Test("wallet, card, recovery and identity values are masked", arguments: [
        ("send to 0x52908400098527886E0F7030069857D2E4169EE7 now", "send to [redacted address] now"),
        ("key 0x4c0883a69102937d6231471b5dbb6204fe5129617082792ae468d01a3f362318", "key [redacted address]"),
        ("deposit bc1qar0srrr7xfkvy5l643lydnw9re59gtzzwf5mdq done", "deposit [redacted address] done"),
        ("wallet Gh9ZwEmdLJ8DscKNTkTqPbNwLNNBjuSzaG9Vp2KGtKJr ready", "wallet [redacted address] ready"),
        ("paid with 4111 1111 1111 1111 today", "paid with [redacted card] today"),
        ("card=4111-1111-1111-1111&ok=1", "card=[redacted card]&ok=1"),
        ("amex 378282246310005", "amex [redacted card]"),
        ("cardNumber: 5555 5555 5555 4444", "cardNumber: [redacted card]"),
        ("seed: abandon ability able about above absent absorb abstract absurd abuse access accident", "seed: [redacted phrase]"),
        (#"{"words":"abandon ability able about above absent absorb abstract absurd abuse access accident zoo wrong when"}"#, #"{"words":"[redacted phrase]"}"#),
        ("Your verification code is 482913.", "Your verification code is [redacted]."),
        ("OTP 004211 expires soon", "OTP [redacted] expires soon"),
        ("mnemonic=word privateKey=abc", "mnemonic=[redacted] privateKey=[redacted]"),
        (#"{"recoveryPhrase":"x","seedPhrase":"y","iban":"z","bsb":"062-000","tfn":"1","dob":"2000-01-01"}"#,
         #"{"recoveryPhrase":"[redacted]","seedPhrase":"[redacted]","iban":"[redacted]","bsb":"[redacted]","tfn":"[redacted]","dob":"[redacted]"}"#),
        ("withdrawalAddress=abc depositAddress=def accessCode=ghi routingNumber=jkl", "withdrawalAddress=[redacted] depositAddress=[redacted] accessCode=[redacted] routingNumber=[redacted]"),
        ("cvv: 123, ssn: 1, passport: X1, birthDate: 1990-01-01", "cvv: [redacted], ssn: [redacted], passport: [redacted], birthDate: [redacted]"),
    ])
    func maskedValues(input: String, expected: String) {
        let result = LogRedactor.redact(input)
        #expect(result.text == expected)
        #expect(result.count > 0)
        #expect(LogRedactor.redact(result.text).text == result.text)
        #expect(LogRedactor.redact(result.text).count == 0)
    }

    @Test("numbers, hashes, ids and sentences that only look like secrets are left alone", arguments: [
        "exit code 1",
        "process exited with code 134",
        "HTTP status code 404",
        "commit 3f786850e387550fdab836ed7e6dc881de23001b merged",
        "request aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee done",
        "uuid 3F2504E04F8911D39A0C0305E82C3301",
        "at 1790945238123 ms",
        "2026-10-14 10:22:33.123 started",
        "stamp 20261014102233",
        "card 4111 1111 1111 1112 failed Luhn",
        "the quick brown fox jumps over the lazy dog then runs away fast",
        "the quick brown fox jumps over the lazy dog then runs",
        "isPrivate: true",
        "postcode: 5000",
        "addressLine1: 1 Example Street",
        "address: 1 Example Street",
        "accountId: 42",
        "code: 7",
    ])
    func valuesLeftAlone(input: String) {
        let result = LogRedactor.redact(input)
        #expect(result.text == input)
        #expect(result.count == 0)
    }

    @Test("pairs name a secret only together")
    func pairs() {
        #expect(LogRedactor.isSensitive(key: "recoveryCode"))
        #expect(LogRedactor.isSensitive(key: "sms_code"))
        #expect(LogRedactor.isSensitive(key: "destination-address"))
        #expect(LogRedactor.isSensitive(key: "bankAccountName"))
        #expect(!LogRedactor.isSensitive(key: "code"))
        #expect(!LogRedactor.isSensitive(key: "recoveryMode"))
        #expect(!LogRedactor.isSensitive(key: "accountType"))
        #expect(!LogRedactor.isSensitive(key: "walletAddressId"))
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
