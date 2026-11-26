import XCTest
@testable import CheapshotCore

/// NOV-161, v0.6.0 release hold: the two leaks the release reviews found, the strings that the
/// two backed-out patches leaked, and a seeded random-secret harness over the same templates.
/// Secrets are built at run time (concatenation or a seeded generator), so no whole
/// secret-shaped literal sits in the source for scanners to flag.
final class LeakRegressionTests: XCTestCase {
    private let r = Redactor()

    // MARK: Leak 1: aligned YAML with an empty field before a password key

    /// Both the key-shaped text and the value after it are redacted: `password:` reads as a
    /// key, but so does a password such as `admin_pass:`, so neither is kept in the clear.
    func testEmptyFieldDoesNotHideTheNextPassword() {
        let pw = "hunter" + "2x9"
        XCTAssertEqual(r.redact("secrets:        password: \(pw)").text, "secrets:        [SECRET] [SECRET]")
        XCTAssertEqual(r.redact("credentials:     db_password: s3cret" + "Val9").text,
                       "credentials:     [SECRET] [SECRET]")
        XCTAssertEqual(r.redact("token:   api_key: abcd1234" + "efgh").text, "token:   [SECRET] [SECRET]")
        XCTAssertEqual(r.redact("secrets:\tpassword\t\(pw)").text, "secrets:\tpassword\t[SECRET]")
        XCTAssertEqual(r.redact(#"secrets:   "password": "\#(pw)""#).text, #"secrets:   "password": "[SECRET]""#)
        // A PIN is a value after a password key, as on a line of its own.
        XCTAssertEqual(r.redact("secrets:   password: 482913").text, "secrets:   [SECRET] [SECRET]")
        // Three empty fields in a row still reach the value.
        XCTAssertEqual(r.redact("secrets:  password:  token:  api_key: \(pw)").text,
                       "secrets:  [SECRET]  [SECRET]  [SECRET] [SECRET]")
        // Brackets, and a key prefix longer than 40 characters (a Spring property path).
        for line in ["secrets:        {password: \(pw)}", "secrets: [password: \(pw)]",
                     "secrets:        spring.datasource.hikari.data-source-properties.password: \(pw)"] {
            let out = r.redact(line).text
            XCTAssertFalse(out.contains(pw), out)
        }
    }

    func testEmptyFieldWithTailsOfCommasAndAt() {
        XCTAssertEqual(r.redact("secrets:        password: p@ss" + "w0rd!x").text, "secrets:        [SECRET] [SECRET]")
        XCTAssertEqual(r.redact("secrets:        password: hunter" + "2x9,").text, "secrets:        [SECRET] [SECRET],")
        let quoted = "hunter2,x9@" + "home"
        XCTAssertEqual(r.redact(#"secrets:        password: "\#(quoted)""#).text,
                       #"secrets:        [SECRET] "[SECRET]""#)
    }

    /// The strings the two backed-out patches leaked must stay redacted, with and without an
    /// empty field in front of them.
    func testStringsTheBackedOutPatchesLeaked() {
        for pw in ["hunter" + "2x9", "Pass" + "word123"] {
            XCTAssertEqual(r.redact("password: \(pw): authentication failed").text,
                           "password: [SECRET] authentication failed", pw)
            XCTAssertEqual(r.redact("secrets:        password: \(pw): authentication failed").text,
                           "secrets:        [SECRET] [SECRET] authentication failed", pw)
        }
        XCTAssertEqual(r.redact("token=" + "9f8e7d6c" + "5b4a3928" + "1706f5e4d3c2b1a0: unauthorized").text,
                       "token=[SECRET] unauthorized")
    }

    /// Mid-task review of the first version of this fix: a password that reads as a key
    /// (`admin_pass:`) was kept in the clear when the value after it was refused or accepted.
    func testKeyShapedPasswordsAreNeverKept() {
        for (line, pw) in [("password: admin_pass: failed", "admin_pass"),
                           ("password: Password: failed", "Password:"),
                           ("password: my-secret: login denied", "my-secret"),
                           ("password: master.key: invalid", "master.key"),
                           ("password: admin_pass: authentication failed", "admin_pass"),
                           ("password\tadmin_pass\tactive", "admin_pass"),
                           ("password: secret_sauce: authentication failed", "secret_sauce"),
                           ("secrets:  MyPassword: hunter" + "2x9", "hunter2x9"),
                           ("password: superpassword: denied", "superpassword"),
                           ("secrets:   password_v2: hunter" + "2x9", "hunter2x9")] {
            let out = r.redact(line).text
            XCTAssertFalse(out.contains(pw), "\(line) -> \(out)")
        }
        // A refused value is scanned as before, so a keyword inside it still counts.
        let out = r.redact("secrets: password: process.env.token=Zx8k2" + "Lm9Qp7").text
        XCTAssertFalse(out.contains("Zx8k2Lm9Qp7"), out)
    }

    // MARK: Leak 2: URL passwords longer than the old 256-character cap

    /// Swift: an RDS IAM auth token as it sits in a connection URL (percent-encoded, ~700
    /// characters). Built from a seeded generator, so the source holds no real-looking token.
    static func rdsToken() -> String {
        var state: UInt64 = 0xD15EA5E
        let hex = Array("0123456789abcdef"), b62 = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        func pick(_ a: [Character], _ n: Int) -> String {
            String((0..<n).map { _ in
                state ^= state << 13; state ^= state >> 7; state ^= state << 17
                return a[Int(state % UInt64(a.count))]
            })
        }
        let cred = "ZZZZ" + pick(b62, 16)
        let token = "mydb.abc123.us-east-1.rds.amazonaws.com%3A5432%2F%3FAction%3Dconnect%26DBUser%3Diamuser"
            + "%26X-Amz-Algorithm%3DAWS4-HMAC-SHA256%26X-Amz-Credential%3D\(cred)%252F20261125%252Fus-east-1"
            + "%252Frds-db%252Faws4_request%26X-Amz-Date%3D20261125T000000Z%26X-Amz-Expires%3D900"
            + "%26X-Amz-Security-Token%3D" + pick(b62 + hex, 300)
            + "%26X-Amz-SignedHeaders%3Dhost%26X-Amz-Signature%3D" + pick(hex, 64)
        return token
    }

    func testLongURLPasswordsAreRedacted() {
        let tok = Self.rdsToken()
        XCTAssertGreaterThan(tok.count, 600)
        XCTAssertEqual(r.redact("postgres://iamuser:\(tok)@mydb.abc123.us-east-1.rds.amazonaws.com:5432/app").text,
                       "postgres://[URL_CREDS]@mydb.abc123.us-east-1.rds.amazonaws.com:5432/app")
        for n in [257, 4097, 20_000] {
            let pw = String(repeating: "aZ9%", count: n / 4 + 1)
            XCTAssertEqual(r.redact("redis://:\(pw)@cache.internal:6379").text,
                           "redis://[URL_CREDS]@cache.internal:6379", "length \(pw.count)")
        }
    }

    func testTwoCredentialURLsInOneJSONLine() {
        let a = "pw1Sec" + "ret9", b = "pw2Sec" + "ret8"
        XCTAssertEqual(r.redact(#"{"a":"postgres://u:\#(a)@h1","b":"mysql://u2:\#(b)@h2"}"#).text,
                       #"{"a":"postgres://[URL_CREDS]@h1","b":"mysql://[URL_CREDS]@h2"}"#)
        XCTAssertEqual(r.redact(#"{"a":"postgres://u:\#(a)@h1:5432/x","b":"mysql://u2:\#(b)@h2/y"}"#).text,
                       #"{"a":"postgres://[URL_CREDS]@h1:5432/x","b":"mysql://[URL_CREDS]@h2/y"}"#)
        let tok = Self.rdsToken()
        XCTAssertEqual(r.redact(#"{"a":"postgres://u:\#(tok)@h1","b":"postgres://u:\#(tok)@h2"}"#).text,
                       #"{"a":"postgres://[URL_CREDS]@h1","b":"postgres://[URL_CREDS]@h2"}"#)
        XCTAssertEqual(r.redact(#"DATABASE_URL="postgres://u:\#(a)@localhost""#).text,
                       #"DATABASE_URL="postgres://[URL_CREDS]@localhost""#)
        XCTAssertEqual(r.redact("['postgres://u:\(a)@h1','mysql://u2:\(b)@h2']").text,
                       "['postgres://[URL_CREDS]@h1','mysql://[URL_CREDS]@h2']")
    }

    func testURLPasswordTailsWithCommasAndAt() {
        XCTAssertEqual(r.redact("postgres://u:p@ss,w0" + "rd@host:5432/db").text, "postgres://[URL_CREDS]@host:5432/db")
        XCTAssertEqual(r.redact("postgres://u:p@ss)w0" + "rd@host/db").text, "postgres://[URL_CREDS]@host/db")
        XCTAssertEqual(r.redact("postgres://u:p@ss:w0" + "rd@host:5432/db").text, "postgres://[URL_CREDS]@host:5432/db")
        XCTAssertEqual(r.redact("postgres://u:hunter2,x" + "9@db").text, "postgres://[URL_CREDS]@db")
        XCTAssertEqual(r.redact("(postgres://u:hunter" + "2x9@db)").text, "(postgres://[URL_CREDS]@db)")
        XCTAssertEqual(r.redact("url=postgres://u:hunter" + "2x9@db, retry").text, "url=postgres://[URL_CREDS]@db, retry")
        // Mid-task review: a bare URL keeps a raw quote, ">" or backtick inside its password.
        XCTAssertEqual(r.redact("mysql://app:Kq7>Mp2Qv" + "9xx@db:3306/app").text, "mysql://[URL_CREDS]@db:3306/app")
        XCTAssertEqual(r.redact("mongodb+srv://app:Tr0ub4dor&3`" + "x@cluster0.mongodb.net/db").text,
                       "mongodb+srv://[URL_CREDS]@cluster0.mongodb.net/db")
        XCTAssertEqual(r.redact("pg://u:Zx9@q\"Lm4" + "v8k@db/x").text, "pg://[URL_CREDS]@db/x")
        XCTAssertEqual(r.redact("pg://u:p@ss'word" + "12@db.internal/x").text, "pg://[URL_CREDS]@db.internal/x")
        // Second review: a password that holds its own URL's closer is still caught.
        XCTAssertEqual(r.redact(#"{"url":"postgres://u:pa\"ss" + "1234@db/app"}"#.replacingOccurrences(of: #"" + ""#, with: "")).text,
                       #"{"url":"postgres://[URL_CREDS]@db/app"}"#)
        XCTAssertEqual(r.redact("connecting (postgres://app:Xy)9k" + "Lm2@db:5432/app)").text,
                       "connecting (postgres://[URL_CREDS]@db:5432/app)")
        XCTAssertEqual(r.redact(#"url='postgres://u:pa\'ss1234@db/app'"#).text, "url='postgres://[URL_CREDS]@db/app'")
        XCTAssertEqual(r.redact("<postgres://app:Kq7>Mp2Q" + "v9xx@db/app>").text, "<postgres://[URL_CREDS]@db/app>")
        XCTAssertEqual(r.redact("`postgres://app:Kq7`Mp2Q" + "v9xx@db/app`").text, "`postgres://[URL_CREDS]@db/app`")
        // Still not credentials: a port, and an address after a path.
        XCTAssertEqual(r.redact("http://localhost:3000/x@b.com").text, "http://localhost:3000/[EMAIL]")
        XCTAssertEqual(r.redact("https://example.com:8443/status").text, "https://example.com:8443/status")
    }

    /// The scanner replaced a regex. On inputs where the old caps cannot bite, it must find
    /// exactly what the reference regex (the same rules, written as a regex) finds. Seeded, so a
    /// failure reproduces. The oracle's six lookbehind branches are slow, hence 6,000 cases.
    func testURLCredsScannerMatchesReferenceRegex() throws {
        let re = try NSRegularExpression(pattern: URLCreds.referencePattern, options: [.caseInsensitive])
        let alphabet = Array("ab1Z:/@?#\"'<>`,;)(][.- %=\t")
        var state: UInt64 = 0xC0FFEE
        func next(_ n: Int) -> Int {
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            return Int(state % UInt64(n))
        }
        for i in 0..<6_000 {
            var s = ""
            for _ in 0..<(8 + next(50)) {
                // Plant scheme separators and "@host" pieces often enough to exercise every path.
                switch next(10) {
                case 0: s += "://"
                case 1: s += "@h" + (next(2) == 0 ? "ost" : "") + String(alphabet[next(alphabet.count)])
                case 2: s += ":\(next(70000))"
                default: s.append(alphabet[next(alphabet.count)])
                }
            }
            let ns = s as NSString
            let want = re.matches(in: s, range: NSRange(location: 0, length: ns.length)).map(\.range)
            let got = URLCreds.ranges(in: s)
            XCTAssertEqual(got, want, "case \(i): \(s.debugDescription)")
            if got != want { break }
        }
    }

    // MARK: Fable final review of 801ab86

    /// Independent expected outputs (the differential test shares its design with its oracle).
    func testFableReviewURLShapes() {
        let pw = "Aa1b" + "Zz9y"
        let cases: [(String, String)] = [
            // A raw "@" before a closer that is not followed by a delimiter.
            ("(postgres://u:p@ss)w0" + "rd@host/db)", "(postgres://[URL_CREDS]@host/db)"),
            ("'postgres://u:p@ss'w0" + "rd@host/db'", "'postgres://[URL_CREDS]@host/db'"),
            ("[db](postgres://u:P@ss)w0" + "rd@host/db)", "[db](postgres://[URL_CREDS]@host/db)"),
            // A JSON-escaped quote is not the closer.
            (#"{"url":"postgres://u:p@ss\"w0"# + #"rd@host/db"}"#, #"{"url":"postgres://[URL_CREDS]@host/db"}"#),
            // Digits before the closer are a port; only the address is redacted.
            (#"{"api":"http://localhost:8080","status":"ok","items":[1,2,3],"owner":"me@example.com"}"#,
             #"{"api":"http://localhost:8080","status":"ok","items":[1,2,3],"owner":"[EMAIL]"}"#),
            // The closer ends a host.
            ("(pg://u:\(pw)@db)", "(pg://[URL_CREDS]@db)"),
            ("\"pg://u:\(pw)@db\"", "\"pg://[URL_CREDS]@db\""),
            ("<pg://u:\(pw)@db>", "<pg://[URL_CREDS]@db>"),
            ("`pg://u:\(pw)@db`", "`pg://[URL_CREDS]@db`"),
            ("'pg://u:\(pw)@db'", "'pg://[URL_CREDS]@db'"),
            // Two URLs per line for each closer pair.
            ("(pg://u:\(pw)@h1) (pg://v:\(pw)@h2)", "(pg://[URL_CREDS]@h1) (pg://[URL_CREDS]@h2)"),
            ("(pg://u:\(pw)@h1)(pg://v:\(pw)@h2)", "(pg://[URL_CREDS]@h1)(pg://[URL_CREDS]@h2)"),
            ("<pg://u:\(pw)@h1>,<pg://v:\(pw)@h2>", "<pg://[URL_CREDS]@h1>,<pg://[URL_CREDS]@h2>"),
            ("`pg://u:\(pw)@h1`,`pg://v:\(pw)@h2`", "`pg://[URL_CREDS]@h1`,`pg://[URL_CREDS]@h2`"),
            ("['pg://u:\(pw)@h1','pg://v:\(pw)@h2']", "['pg://[URL_CREDS]@h1','pg://[URL_CREDS]@h2']"),
            (#"["pg://u:\#(pw)@h1","pg://v:\#(pw)@h2"]"#, #"["pg://[URL_CREDS]@h1","pg://[URL_CREDS]@h2"]"#),
            // No username length cap.
            ("pg://" + String(repeating: "u", count: 129) + ":Qsecret7z@db/x", "pg://[URL_CREDS]@db/x"),
            ("pg://" + String(repeating: "u", count: 2000) + ":Qsecret7z@db/x", "pg://[URL_CREDS]@db/x"),
        ]
        for (input, want) in cases {
            XCTAssertEqual(r.redact(input).text, want, input)
        }
    }

    func testFableReviewKeysInsideAcceptedValues() {
        let pw = "hunter" + "2x9"
        let long = String(repeating: "a1", count: 70)
        let out1 = r.redact("secrets:   password: \(long)token: \(pw)").text
        XCTAssertFalse(out1.contains(pw), out1)
        let out2 = r.redact(#"secrets:  password: "prod, token": "Zx9kQ2"# + #"mW7p""#).text
        XCTAssertFalse(out2.contains("Zx9kQ2mW7p"), out2)
        // A value that holds its own assignment is one hit, not two.
        XCTAssertEqual(r.redact("secrets: token=Zx8k2" + "Lm9Qp7").text, "secrets: [SECRET]")
        XCTAssertEqual(r.redact("password: token:abc1" + "23xyz").text, "password: [SECRET]")
    }

    // MARK: Fable re-review of e90d1a2

    /// Row 1: a very long value used to make the SECRET regex give up, and every later
    /// assignment in the document leaked.
    func testLongValueDoesNotStopLaterRedaction() {
        let m = "Zq9kQ2" + "mW7p"
        for n in [80_000, 100_000, 400_000] {
            for head in ["token=" + String(repeating: "a", count: n),
                         "password=\"" + String(repeating: "a,", count: n / 2),
                         "token: '" + String(repeating: "b", count: n),
                         "password: " + String(repeating: "1", count: n)] {
                let out = r.redact(head + "\npassword=" + m).text
                XCTAssertTrue(out.hasSuffix("\npassword=[SECRET]"), "\(head.prefix(12))... at \(n): \(out.suffix(40))")
            }
        }
    }

    /// Row 2: a refused long value whose key was itself read as the previous value.
    func testRefusedLongValueAfterKeyShapedValue() {
        let m = "Zq9kQ2" + "mW7p"
        let line = "credentials:   secret_url: jdbc:postgresql://my-production-database-instance.cluster-ro-"
            + "abcdefghijkl.us-east-1.rds.amazonaws.com:5432/application_production?password=\(m)"
        let out = r.redact(line).text
        XCTAssertFalse(out.contains(m), out)
    }

    /// Fuzz row (seed 161): a long refused value found only by reading an accepted value
    /// again must not move the scan past where the plain scan resumed.
    func testRescanFoundRefusedValueResumesAtPlainEnd() {
        let m = "ZquTuu" + "68d5"
        let line = #"- session_id: $HOMEpasswd: "db_password_credentials': 'https://example.com/"#
            + String(repeating: "a", count: 130) + #"; token:   ""# + m + #"""#
        let out = r.redact(line).text
        XCTAssertFalse(out.contains(m), out)
    }

    /// The 128-character bound on scanning a refused value again. At 128 a key inside it is
    /// found; at 129 the value is skipped whole, as e8c5749 skips every refused value.
    func testRefusedValueRescanBoundIs128() {
        let m = "Zq9kQ2" + "mW7p"
        func line(_ length: Int) -> String {
            let tail = "token=" + m
            return "password: process.env." + String(repeating: "a", count: length - 12 - tail.count) + tail
        }
        // The refused value is everything after "password: ".
        XCTAssertEqual(line(128).count - "password: ".count, 128)
        XCTAssertFalse(r.redact(line(128)).text.contains(m))
        XCTAssertTrue(r.redact(line(129)).text.contains(m), "129 is past the bound")
    }

    /// Row 5: a hit that overlaps only the tail of the last redacted span; the tail is redacted
    /// and scanned, so a key after it is still found.
    func testOverlapTail() {
        let m = "Zq9kQ2" + "mW7p"
        let out = r.redact(#"password: "x1 token: 'abc"de_secret' = "# + m).text
        XCTAssertFalse(out.contains(m), out)
        XCTAssertFalse(out.contains("de_secret"), out)
    }

    func testFableReReviewURLShapes() {
        let pw = "Zq9kQ2" + "mW7p"
        let cases: [(String, String)] = [
            // Row 3: a username holding the closer character, not a real closer.
            ("(pg://us)er:\(pw)@host/db)", "(pg://[URL_CREDS]@host/db)"),
            // Row 4: a real closer after "@host" chars, then more password and a later "@".
            ("(postgres://u:p@ss).w0rd\(pw)@host/db)", "(postgres://[URL_CREDS]@host/db)"),
            ("'postgres://u:p@ss''w0rd\(pw)@host/db'", "'postgres://[URL_CREDS]@host/db'"),
            (#""pg://u:p@ss\",w0rd"# + pw + #"@host/db""#, #""pg://[URL_CREDS]@host/db""#),
            // A real closer does not stop when any "@" before a host character lies ahead in the
            // same item, even one whose host ends oddly (fuzz row: "@host:]").
            (#"url="s3://u:Zq9k!",x"# + pw + #"@host:]."#, #"url="s3://[URL_CREDS]@host:]."#),
            // A stopping closer right after the colon is an empty password, not a credential.
            (#""pg://u:","b@db""#, #""pg://u:","b@db""#),
            // An escaped quote is password text even before a delimiter and another escape.
            (#"{"u":"pg://u:p\",\"x9"# + pw + #"@db"}"#, #"{"u":"pg://[URL_CREDS]@db"}"#),
            // A stray ")" between a real closer and the "@" stays in the password; a new "("
            // starts another item. Doubled backticks are escaped.
            ("(s3://u:" + pw + "@h1))!x" + pw + "@db/x)", "(s3://[URL_CREDS]@db/x)"),
            ("(pg://u:\(pw)@h1),(me@example.com)", "(pg://[URL_CREDS]@h1),([EMAIL])"),
            ("`mysql://u:" + pw + "``@ss>x" + pw + "@db.internal?x=1`", "`mysql://[URL_CREDS]@db.internal?x=1`"),
            // Row 7: the bare-URL fallback no longer runs past a real closing quote.
            (#"{"url":"http://localhost:port","email":"me@example.com"}"#,
             #"{"url":"http://localhost:port","email":"[EMAIL]"}"#),
            (#"{"a":"pg://u:","b":"me@example.com"}"#, #"{"a":"pg://u:","b":"[EMAIL]"}"#),
            // "." after a closer makes it real, so these stay two URLs.
            ("(pg://u:\(pw)@h1).(pg://v:\(pw)@h2)", "(pg://[URL_CREDS]@h1).(pg://[URL_CREDS]@h2)"),
            // A host of 253 characters ends a password; the "@" before it is the end.
            ("pg://u:Aa1b@" + String(repeating: "a", count: 253) + "/x@db/y",
             "pg://[URL_CREDS]@" + String(repeating: "a", count: 253) + "/x@db/y"),
            // A "://" inside the password is one hit, not two.
            ("pg://u:a://b:c@h/x", "pg://[URL_CREDS]@h/x"),
        ]
        for (input, want) in cases {
            XCTAssertEqual(r.redact(input).text, want, input)
        }
    }

    // MARK: Random-secret harness

    /// Swift: seeded random secrets in every leak template. None may survive in the output.
    func testRandomSecretsNeverSurvive() {
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789!%+_-")
        var state: UInt64 = 0xBADC0DE
        func secret(_ n: Int) -> String {
            var s = String((0..<n).map { _ -> Character in
                state ^= state << 13; state ^= state >> 7; state ^= state << 17
                return alphabet[Int(state % UInt64(alphabet.count))]
            })
            s.replaceSubrange(s.startIndex...s.startIndex, with: "Q")   // never starts with "-"
            return s + "7z"                                               // a digit and a lowercase
        }
        let templates: [(String, Int)] = [
            ("secrets:        password: {S}", 12),
            ("credentials:\tdb_password: {S}", 12),
            ("password: {S}: authentication failed", 12),
            ("secrets:        password: {S}: authentication failed", 12),
            ("token:   api_key: {S}", 16),
            (#"{"a":"postgres://u:{S}@h1","b":"mysql://u:{S}@h2"}"#, 24),
            ("postgres://u:{S}@db.internal:5432/app", 700),
            ("redis://:{S}@cache:6379", 300),
            (#"{"a":"postgres://u:{S}@h1","b":"postgres://u:{S}@h2"}"#, 700),
        ]
        for (template, length) in templates {
            for _ in 0..<50 {
                let s1 = secret(length), s2 = secret(length)
                var line = template
                if let r1 = line.range(of: "{S}") { line.replaceSubrange(r1, with: s1) }
                if let r2 = line.range(of: "{S}") { line.replaceSubrange(r2, with: s2) }
                let out = r.redact(line).text
                XCTAssertFalse(out.contains(s1) || out.contains(s2), "\(template): \(out.prefix(160))")
            }
        }
    }
}
