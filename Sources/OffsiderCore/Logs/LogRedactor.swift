import Foundation

/// Masks passwords, tokens, keys, cookies, emails, wallet addresses, card numbers, recovery phrases and one-time codes in
/// log text, keeping the text's shape so JSON still parses.
public enum LogRedactor {
    public static let marker = "[redacted]"
    public static let jwtMarker = "[redacted jwt]"
    public static let emailMarker = "[redacted email]"
    public static let addressMarker = "[redacted address]"
    public static let cardMarker = "[redacted card]"
    public static let phraseMarker = "[redacted phrase]"

    static let sensitiveSegments: Set<String> = [
        "password", "passwd", "passcode", "pwd", "pin", "secret", "token", "authorization", "jwt", "ticket", "email",
        "cookie", "otp", "apikey",
        "mnemonic", "seed", "seedphrase", "passphrase", "privatekey", "xprv", "xpriv", "totp", "mfa", "2fa", "mfacode", "otpcode",
        "verificationcode", "recoveryphrase", "recoverycode", "iban", "bsb", "cvv", "cvc", "ssn", "tfn", "passport", "dob", "birth",
        "birthdate", "birthday", "accountnumber", "cardnumber", "walletaddress",
    ]
    /// Adjacent key segments that name a secret together, though neither does alone (`code`, `address`, `account` are too broad).
    static let sensitivePairs: Set<String> = [
        "api key", "private key", "secret key", "recovery phrase", "recovery code", "recovery key", "recovery words",
        "verification code", "security code", "auth code", "sms code", "login code", "access code", "account number",
        "card number", "routing number", "bank account", "wallet address", "deposit address", "withdrawal address",
        "withdraw address", "destination address",
    ]
    static let exemptLastSegments: Set<String> = [
        "id", "ids", "type", "count", "length", "expiry", "expires", "ttl", "verified", "enabled", "required", "valid", "status", "at",
    ]
    /// Keys whose unquoted value is a whole header value, spaces included.
    static let headerKeys: Set<String> = ["authorization", "proxy-authorization", "cookie"]
    static let prefilterWords = [
        "@", "eyj", "earer", "asic ", "pass", "pwd", "pin", "secret", "token", "auth", "jwt", "ticket", "email", "cookie", "otp", "api",
        "mnemonic", "seed", "phrase", "private", "xprv", "xpriv", "mfa", "2fa", "code", "recovery", "iban", "bsb", "cvv", "cvc", "ssn",
        "tfn", "dob", "birth", "account", "card", "wallet", "address", "routing", "bank",
    ]

    private static let key = try! NSRegularExpression(pattern: #"(["']?)([A-Za-z][A-Za-z0-9_.-]{0,63})\1[ \t]{0,16}[:=][ \t]{0,16}"#)
    private static let scheme = try! NSRegularExpression(pattern: #"\b(Bearer|Basic)[ \t]{1,16}[A-Za-z0-9._~+/=-]{8,8192}"#)
    private static let jwt = try! NSRegularExpression(pattern: #"\beyJ[A-Za-z0-9_-]{8,8192}\.eyJ[A-Za-z0-9_-]{8,8192}\.[A-Za-z0-9_-]{0,8192}"#)
    private static let email = try! NSRegularExpression(pattern: PersonalData.emailPattern)
    private static let hexAddress = try! NSRegularExpression(pattern: #"\b0x(?:[0-9A-Fa-f]{64}|[0-9A-Fa-f]{40})\b"#)
    private static let bech32 = try! NSRegularExpression(pattern: #"\b(?:bc1|tb1)[02-9ac-hj-np-z]{11,71}\b"#)
    private static let base58 = try! NSRegularExpression(pattern: #"\b[1-9A-HJ-NP-Za-km-z]{32,44}\b"#)
    private static let cardDigits = try! NSRegularExpression(pattern: #"(?<![0-9-])(?:[0-9][ -]?){12,18}[0-9](?![0-9])"#)
    private static let codeAfterKeyword = try! NSRegularExpression(
        pattern: #"(?i)(\b(?:otp|totp|code|passcode|pin|2fa|mfa)\b[^0-9\n]{0,20}?)(?<![0-9])[0-9]{6}(?![0-9])"#
    )
    private static let wordPhrase = try! NSRegularExpression(
        pattern: #"(?<![A-Za-z0-9] )(?<![A-Za-z0-9])[a-z]{3,8}(?: [a-z]{3,8}){11,23}(?![A-Za-z0-9])(?! [A-Za-z0-9])"#
    )
    /// 12 to 24 quoted words in a list, as a recovery phrase logged as an array: `["abandon", "ability", ...]`.
    private static let quotedPhrase = try! NSRegularExpression(
        pattern: #"(?<![a-z]["'][ \t]{0,2},[ \t]{0,2})(["'])[a-z]{3,8}\1(?:[ \t]{0,2},[ \t]{0,2}\1[a-z]{3,8}\1){11,23}(?![ \t]{0,2},[ \t]{0,2}["'][a-z])"#
    )
    static let phraseLengths: Set<Int> = [12, 15, 18, 21, 24]
    /// Values in a describe-ui tree no shorter than this are checked; shorter ones cannot hold a code, address, card or phrase.
    public static let minimumValueLength = 6

    /// The text with every sensitive value replaced, and how many values were replaced; markers already there are left and not counted.
    public static func redact(_ text: String) -> (text: String, count: Int) {
        let shapes = ValueShapes(text)
        let lowered = text.lowercased()
        let keyed = prefilterWords.contains(where: lowered.contains)
        guard keyed || shapes.any else { return (text, 0) }
        var count = 0
        // Whole values first, so a key-value pass never splits a card number or phrase at its first space.
        var result = redactValuePatterns(text, shapes: shapes, count: &count)
        if keyed {
            result = redactKeyValues(result, count: &count)
            result = replace(scheme, in: result, template: "$1 \(marker)", count: &count)
            result = replace(jwt, in: result, template: jwtMarker, count: &count)
            result = replace(email, in: result, template: emailMarker, count: &count)
        }
        return (result, count)
    }

    /// Only the value patterns, with no key matching: one-time codes after a keyword, wallet addresses, card numbers and
    /// recovery phrases. For screen text, where a key such as `password` names nothing.
    public static func redactValue(_ value: String) -> (text: String, count: Int) {
        let shapes = ValueShapes(value)
        guard shapes.any else { return (value, 0) }
        var count = 0
        let result = redactValuePatterns(value, shapes: shapes, count: &count)
        return (result, count)
    }

    private static func redactValuePatterns(_ text: String, shapes: ValueShapes, count: inout Int) -> String {
        var result = text
        if shapes.longToken {
            result = replace(hexAddress, in: result, template: addressMarker, count: &count)
            result = replace(bech32, in: result, template: addressMarker, count: &count)
            result = replace(base58, in: result, count: &count) { isMixedBase58($0) ? addressMarker : nil }
        }
        if shapes.cardRun {
            result = replace(cardDigits, in: result, count: &count) { isCardNumber($0) ? cardMarker : nil }
        }
        if shapes.codeRun {
            result = replace(codeAfterKeyword, in: result, template: "$1\(marker)", count: &count)
        }
        if shapes.wordRun {
            result = replace(wordPhrase, in: result, count: &count) { phrase in
                phraseLengths.contains(phrase.split(separator: " ").count) ? phraseMarker : nil
            }
        }
        if shapes.listRun {
            result = replace(quotedPhrase, in: result, count: &count) { list in
                guard let quote = list.first else { return nil }
                let words = list.split(separator: ",").count
                return phraseLengths.contains(words) ? "\(quote)\(phraseMarker)\(quote)" : nil
            }
        }
        return result
    }

    /// Which value patterns can match, from one pass over the bytes, so a line with none runs no value regex.
    struct ValueShapes {
        /// A run of 26 or more ASCII letters and digits: a hex, bech32 or base58 address.
        var longToken = false
        /// 13 or more digits, single spaces or hyphens allowed between them: a card number.
        var cardRun = false
        /// Exactly six digits in a row: a one-time code.
        var codeRun = false
        /// Twelve or more lowercase words of 3 to 8 letters, one space apart: a recovery phrase.
        var wordRun = false
        /// Twelve or more quoted lowercase words of 3 to 8 letters, comma separated: a recovery phrase logged as a list.
        var listRun = false

        var any: Bool { longToken || cardRun || codeRun || wordRun || listRun }

        init(_ text: String) {
            var alnum = 0
            var digits = 0
            var consecutive = 0
            var separated = false
            var letters = 0
            var badWord = false
            var words = 0
            func endWord(_ continues: Bool) {
                if (3...8).contains(letters), !badWord {
                    words += 1
                    if words >= 12 { wordRun = true }
                } else {
                    words = 0
                }
                if !continues { words = 0 }
                letters = 0
                badWord = false
            }
            var quote: UInt8?
            var quotedLetters = 0
            var quotedBad = false
            var listed = 0
            var comma = false
            for byte in text.utf8 {
                if let open = quote {
                    if byte == open {
                        if (3...8).contains(quotedLetters), !quotedBad {
                            listed += 1
                            if listed >= 12 { listRun = true }
                        } else {
                            listed = 0
                        }
                        quote = nil
                        comma = false
                    } else if byte >= 0x61 && byte <= 0x7A {
                        quotedLetters += 1
                    } else {
                        quotedBad = true
                    }
                } else if byte == 0x22 || byte == 0x27 {
                    if listed > 0, !comma { listed = 0 }
                    quote = byte
                    quotedLetters = 0
                    quotedBad = false
                } else if byte == 0x2C {
                    comma = true
                } else if byte != 0x20 && byte != 0x09 {
                    listed = 0
                }
                let isDigit = byte >= 0x30 && byte <= 0x39
                let isLower = byte >= 0x61 && byte <= 0x7A
                let isAlnum = isDigit || isLower || (byte >= 0x41 && byte <= 0x5A)
                alnum = isAlnum ? alnum + 1 : 0
                if alnum >= 26 { longToken = true }
                if isDigit {
                    digits += 1
                    consecutive += 1
                    separated = false
                    if digits >= 13 { cardRun = true }
                } else {
                    if consecutive == 6 { codeRun = true }
                    consecutive = 0
                    if (byte == 0x20 || byte == 0x2D) && digits > 0 && !separated {
                        separated = true
                    } else {
                        digits = 0
                        separated = false
                    }
                }
                if isLower {
                    letters += 1
                } else if isAlnum {
                    badWord = true
                } else {
                    endWord(byte == 0x20)
                }
            }
            endWord(false)
            if consecutive == 6 { codeRun = true }
        }
    }

    /// 32 to 44 base58 characters mixing upper case, lower case and digits, as a Solana or Bitcoin address does.
    static func isMixedBase58(_ token: String) -> Bool {
        var upper = false, lower = false, digit = false
        for byte in token.utf8 {
            if byte >= 0x41 && byte <= 0x5A { upper = true } else if byte >= 0x61 && byte <= 0x7A { lower = true } else if byte >= 0x30 && byte <= 0x39 { digit = true }
        }
        return upper && lower && digit
    }

    /// 13 to 19 digits with a card issuer's prefix that pass the Luhn check; spaces and hyphens between digits are ignored.
    static func isCardNumber(_ text: String) -> Bool {
        let digits = text.utf8.filter { $0 >= 0x30 && $0 <= 0x39 }.map { Int($0 - 0x30) }
        guard (13...19).contains(digits.count), hasIssuerPrefix(digits) else { return false }
        var sum = 0
        for (offset, digit) in digits.reversed().enumerated() {
            if offset % 2 == 1 {
                let doubled = digit * 2
                sum += doubled > 9 ? doubled - 9 : doubled
            } else {
                sum += digit
            }
        }
        return sum % 10 == 0
    }

    /// Visa, Mastercard, American Express, Discover, JCB, Diners Club and UnionPay prefixes, each at its own lengths.
    private static func hasIssuerPrefix(_ digits: [Int]) -> Bool {
        func prefix(_ count: Int) -> Int { digits.prefix(count).reduce(0) { $0 * 10 + $1 } }
        let length = digits.count
        switch digits[0] {
        case 4: return [13, 16, 19].contains(length)
        case 5: return length == 16 && (51...55).contains(prefix(2))
        case 2: return length == 16 && (2221...2720).contains(prefix(4))
        case 3:
            if [34, 37].contains(prefix(2)) { return length == 15 }
            if [36, 38].contains(prefix(2)) || (300...305).contains(prefix(3)) { return length >= 14 }
            return length >= 16 && (3528...3589).contains(prefix(4))
        case 6: return length >= 16 && (prefix(4) == 6011 || prefix(2) == 65 || prefix(2) == 62 || (644...649).contains(prefix(3)))
        default: return false
        }
    }

    /// Whether a key such as `accessToken`, `refresh_token` or `x-api-key` names a secret; `tokenType` and `emailVerified` do not.
    public static func isSensitive(key: String) -> Bool {
        let segments = self.segments(of: key)
        guard let last = segments.last, !exemptLastSegments.contains(last) else { return false }
        if segments.contains(where: sensitiveSegments.contains) { return true }
        return zip(segments, segments.dropFirst()).contains { sensitivePairs.contains($0 + " " + $1) }
    }

    /// Lowercased camel, snake, kebab and dot segments: `xAPIKey` is `x`, `api`, `key`.
    static func segments(of key: String) -> [String] {
        var segments: [String] = []
        var current = ""
        let characters = Array(key)
        for (index, character) in characters.enumerated() {
            if character == "_" || character == "-" || character == "." {
                if !current.isEmpty { segments.append(current) }
                current = ""
                continue
            }
            if character.isUppercase, let previous = current.last {
                let nextIsLower = index + 1 < characters.count && characters[index + 1].isLowercase
                if previous.isLowercase || previous.isNumber || (previous.isUppercase && nextIsLower) {
                    segments.append(current)
                    current = ""
                }
            }
            current.append(character)
        }
        if !current.isEmpty { segments.append(current) }
        return segments.map { $0.lowercased() }
    }

    private static func redactKeyValues(_ text: String, count: inout Int) -> String {
        let source = text as NSString
        let output = NSMutableString()
        var cursor = 0
        while cursor < source.length,
              let match = key.firstMatch(in: text, range: NSRange(location: cursor, length: source.length - cursor)) {
            let name = source.substring(with: match.range(at: 2))
            let keyQuoted = match.range(at: 1).length > 0
            let valueStart = match.range.location + match.range.length
            output.append(source.substring(with: NSRange(location: cursor, length: valueStart - cursor)))
            cursor = valueStart
            guard isSensitive(key: name), valueStart < source.length else { continue }
            if let length = markerLength(in: source, at: valueStart) {
                output.append(source.substring(with: NSRange(location: valueStart, length: length)))
                cursor = valueStart + length
                continue
            }

            let first = source.character(at: valueStart)
            if first == 0x5B || first == 0x7B {
                let end = closingBracket(in: source, from: valueStart)
                if first == 0x7B, holdsOnlyMetadata(source.substring(with: NSRange(location: valueStart, length: end - valueStart))) { continue }
                cursor = end
                count += 1
                output.append(keyQuoted ? "\"\(marker)\"" : marker)
                continue
            }
            if first == 0x22 || first == 0x27 {
                let close = closingQuote(first, in: source, from: valueStart + 1)
                let inner = source.substring(with: NSRange(location: valueStart + 1, length: close - valueStart - 1))
                if !inner.isEmpty, !isMarker(inner) { count += 1 }
                output.append(String(utf16CodeUnits: [first], count: 1))
                output.append(inner.isEmpty || isMarker(inner) ? inner : marker)
                cursor = close
                continue
            }
            let end = headerKeys.contains(name.lowercased()) ? headerValueEnd(in: source, from: valueStart) : plainValueEnd(in: source, from: valueStart)
            let value = source.substring(with: NSRange(location: valueStart, length: end - valueStart))
            guard !value.isEmpty, !["true", "false", "null", "undefined"].contains(value) else { continue }
            count += 1
            output.append(keyQuoted ? "\"\(marker)\"" : marker)
            cursor = end
        }
        if cursor < source.length {
            output.append(source.substring(from: cursor))
        }
        return output as String
    }

    /// The index of the closing quote, skipping backslash escapes; the end of the text when it never closes.
    private static func closingQuote(_ quote: unichar, in source: NSString, from start: Int) -> Int {
        var index = start
        while index < source.length {
            let character = source.character(at: index)
            if character == 0x5C { index += 2; continue }
            if character == quote { return index }
            index += 1
        }
        return source.length
    }

    /// An object such as `{expires: 3, type: "jwt"}` describes a secret without holding it, so its keys are scanned one by one instead.
    private static func holdsOnlyMetadata(_ object: String) -> Bool {
        let names = key.matches(in: object, range: NSRange(object.startIndex..., in: object)).compactMap { match in
            Range(match.range(at: 2), in: object).map { String(object[$0]) }
        }
        return !names.isEmpty && names.allSatisfy { segments(of: $0).last.map(exemptLastSegments.contains) ?? false }
    }

    /// Just past the bracket that closes the one at `start`, skipping quoted text and escapes; the end of the line when it never closes.
    private static func closingBracket(in source: NSString, from start: Int) -> Int {
        var depth = 0
        var quote: unichar?
        var index = start
        while index < source.length {
            let character = source.character(at: index)
            if character == 0x0A || character == 0x0D { return index }
            if let open = quote {
                if character == 0x5C {
                    index += 2
                    continue
                }
                if character == open { quote = nil }
            } else if character == 0x22 || character == 0x27 {
                quote = character
            } else if character == 0x5B || character == 0x7B {
                depth += 1
            } else if character == 0x5D || character == 0x7D {
                depth -= 1
                if depth == 0 { return index + 1 }
            }
            index += 1
        }
        return source.length
    }

    /// Up to a quote, a comma followed by a space, or the end of the line.
    private static func headerValueEnd(in source: NSString, from start: Int) -> Int {
        var index = start
        while index < source.length {
            let character = source.character(at: index)
            if character == 0x22 || character == 0x27 || character == 0x0A || character == 0x0D { break }
            if character == 0x2C, index + 1 < source.length, source.character(at: index + 1) == 0x20 { break }
            index += 1
        }
        while index > start, source.character(at: index - 1) == 0x20 { index -= 1 }
        return index
    }

    /// Up to whitespace or one of `,;&}])`.
    private static func plainValueEnd(in source: NSString, from start: Int) -> Int {
        let stops = Set(",;&}])".utf16)
        var index = start
        while index < source.length {
            let character = source.character(at: index)
            if stops.contains(character) || Unicode.Scalar(character).map(CharacterSet.whitespacesAndNewlines.contains) == true { break }
            index += 1
        }
        return index
    }

    /// Every marker, longest first where one starts another.
    private static let markers = [jwtMarker, emailMarker, addressMarker, cardMarker, phraseMarker, marker]

    private static func isMarker(_ value: String) -> Bool {
        markers.contains(value)
    }

    /// The length of the marker that starts at `start`, so a second pass leaves `[redacted card]` whole.
    private static func markerLength(in source: NSString, at start: Int) -> Int? {
        guard source.character(at: start) == 0x5B else { return nil }
        for candidate in markers {
            let length = (candidate as NSString).length
            if start + length <= source.length, source.substring(with: NSRange(location: start, length: length)) == candidate { return length }
        }
        return nil
    }

    /// Replaces each match `transform` returns a marker for; a nil leaves the match as it is.
    private static func replace(_ regex: NSRegularExpression, in text: String, count: inout Int, transform: (String) -> String?) -> String {
        let source = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: source.length))
        guard !matches.isEmpty else { return text }
        let output = NSMutableString()
        var cursor = 0
        for match in matches {
            guard let replacement = transform(source.substring(with: match.range)) else { continue }
            output.append(source.substring(with: NSRange(location: cursor, length: match.range.location - cursor)))
            output.append(replacement)
            cursor = match.range.location + match.range.length
            count += 1
        }
        guard cursor > 0 else { return text }
        output.append(source.substring(from: cursor))
        return output as String
    }

    private static func replace(_ regex: NSRegularExpression, in text: String, template: String, count: inout Int) -> String {
        let range = NSRange(text.startIndex..., in: text)
        let matches = regex.numberOfMatches(in: text, range: range)
        guard matches > 0 else { return text }
        count += matches
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: template)
    }
}
