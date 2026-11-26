import XCTest
@testable import CheapshotCore

final class ValidatorsTests: XCTestCase {
    func testLuhn() {
        XCTAssertTrue(Validators.luhn("4111 1111 1111 1111"))
        XCTAssertFalse(Validators.luhn("4111-1111-1111-1112"))
        XCTAssertFalse(Validators.luhn("123456789012"))   // 12 digits, too short
    }

    func testABA() {
        XCTAssertTrue(Validators.aba("021000021"))
        XCTAssertFalse(Validators.aba("123456789"))
        XCTAssertFalse(Validators.aba("02100002"))
    }

    func testEntropy() {
        XCTAssertEqual(Validators.entropy(""), 0)
        XCTAssertEqual(Validators.entropy("aaaa"), 0)
        XCTAssertEqual(Validators.entropy("ab"), 1, accuracy: 0.0001)
    }

    func testLooksLikeSecret() {
        XCTAssertFalse(Validators.looksLikeSecret("https://example.com/AbCdEf"))
        XCTAssertFalse(Validators.looksLikeSecret("/Users/ryan/local-dev/Cheapshot"))
        XCTAssertTrue(Validators.looksLikeSecret("dGhpcyBpcyBhIHNlY3JldCB0b2tlbiBub2JvZHkgc2hvdWxkIHNlZQ=="))
    }

    // ISO 13616 examples; one check digit changed must fail.
    func testIBAN() {
        XCTAssertTrue(Validators.iban("GB82WEST12345698765432"))
        XCTAssertTrue(Validators.iban("DE89 3704 0044 0532 0130 00"))
        XCTAssertFalse(Validators.iban("GB00WEST12345698765432"))
        XCTAssertFalse(Validators.iban("GB82WEST1234"))            // too short
    }

    func testBasicAuthNeedsDecodableUserColonPassword() {
        XCTAssertTrue(Validators.basicAuth("Basic YWxhZGRpbjpvcGVuc2VzYW1l"))   // aladdin:opensesame
        XCTAssertFalse(Validators.basicAuth("Basic setup"))                    // decodes to bytes, no colon
        XCTAssertFalse(Validators.basicAuth("Basic dXNlcm5hbWU="))             // "username", no colon
    }

    func testDigitCount() {
        XCTAssertTrue(Validators.digitCount("+44 7911 123456", in: 8...15))
        XCTAssertFalse(Validators.digitCount("+120 -30", in: 8...15))
    }

    func testSecretValueVetoesPlaceholdersAndCode() {
        XCTAssertTrue(Validators.secretValue("hunter22"))
        XCTAssertTrue(Validators.secretValue("9f86d081884c7d659a2feaa0c55ad015"))
        XCTAssertTrue(Validators.secretValue("correcthorsebatterystaple"))   // letters only, long
        XCTAssertFalse(Validators.secretValue("forgotten"))                  // letters only, short
        XCTAssertFalse(Validators.secretValue("[OPENAI_KEY]"))               // already redacted
        XCTAssertFalse(Validators.secretValue("${DB_PASSWORD}"))
        XCTAssertFalse(Validators.secretValue("process.env.API_KEY"))
        XCTAssertFalse(Validators.secretValue("getToken()"))
        XCTAssertFalse(Validators.secretValue("********"))
        XCTAssertFalse(Validators.secretValue("YOUR_API_KEY_HERE"))
        XCTAssertFalse(Validators.secretValue("https://example.com/x"))
        XCTAssertFalse(Validators.secretValue("/etc/secrets"))
        XCTAssertFalse(Validators.secretValue("4096"))                       // under 6 characters
    }

    // Review finding 2: the veto is whole-value reference shapes, not a single leading symbol.
    // Inputs here are not secret-shaped for scanners (short or obviously fake).
    func testSecretValueKeepsPasswordsWithSymbols() {
        XCTAssertTrue(Validators.secretValue("$ecretP4ss!"))        // "$" not followed by an UPPER_IDENT
        XCTAssertTrue(Validators.secretValue("#Tr0ub4dor"))
        XCTAssertTrue(Validators.secretValue("%9fK2xQ7mZ"))
        XCTAssertTrue(Validators.secretValue("Hunter2(prod)"))      // parens, but not call syntax
        XCTAssertTrue(Validators.secretValue("/x9Kq2vB7"))          // one slash is not a path
        XCTAssertTrue(Validators.secretValue("yourpass99!"))        // starts with "your", not a placeholder
        XCTAssertFalse(Validators.secretValue("$DB_PASSWORD"))
        XCTAssertFalse(Validators.secretValue("%DB_PASSWORD%"))
        XCTAssertFalse(Validators.secretValue("%(password)s"))
        XCTAssertFalse(Validators.secretValue("{{ secrets.TOKEN }}"))
        XCTAssertFalse(Validators.secretValue("<your-token>"))
        XCTAssertFalse(Validators.secretValue("getSecret(name)"))   // camelCase name reads as code
        XCTAssertFalse(Validators.secretValue("os.getenv(\"X\")"))
        XCTAssertFalse(Validators.secretValue("xxxx-xxxx"))         // mask
        XCTAssertFalse(Validators.secretValue("~/.ssh/id_rsa"))      // path
        XCTAssertFalse(Validators.secretValue("is required"))        // quoted prose
    }

    // Review finding 8: decoded UTF-8 is fine, control characters are not.
    func testBasicAuthAcceptsUTF8() {
        XCTAssertTrue(Validators.basicAuth("Basic am9zZTpjb250cmHDsWE="))   // jose:contraña
        XCTAssertFalse(Validators.basicAuth("Basic dXNlcjoBAgM="))          // user: plus 0x01 0x02 0x03
    }

    // Review finding 7: a phone needs a separator and is not a date or thousands grouping.
    func testInternationalPhone() {
        XCTAssertTrue(Validators.internationalPhone("+44 7911 123456"))
        XCTAssertTrue(Validators.internationalPhone("+33 1 42 68 53 00"))
        XCTAssertTrue(Validators.internationalPhone("+1.415.555.1234"))
        XCTAssertFalse(Validators.internationalPhone("+12345678"))
        XCTAssertFalse(Validators.internationalPhone("+12.345.678"))
        XCTAssertFalse(Validators.internationalPhone("+2026-11-20"))
        XCTAssertFalse(Validators.internationalPhone("+44 7911 123456 2024"))   // 16 digits
    }

    /// F1 (post-merge review): 20 to 31 character secrets used to need 4.4 bits/char, which is
    /// out of reach at 20 and rare below 32. Seeded random base62 strings, so no secret-shaped
    /// literal sits in the source: at least 85% of each length must pass now (measured ~91%).
    func testShortRandomSecretsPassTheScaledGate() {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
        var state: UInt64 = 0x5EED_CAFE
        // Swift: a tiny xorshift generator, deterministic across runs and platforms.
        func next() -> Int {
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            return Int(state % UInt64(alphabet.count))
        }
        for length in 20...31 {
            var caught = 0
            for _ in 0..<400 {
                let s = String((0..<length).map { _ in alphabet[next()] })
                if Validators.looksLikeSecret(s) { caught += 1 }
            }
            XCTAssertGreaterThanOrEqual(caught, 340, "length \(length): \(caught)/400")
        }
    }

    /// The shape checks that keep code out of the short gate.
    func testShortGateRefusesCodeShapes() {
        for s in ["getElementsByClassName", "testUTF8Decoding2Bytes", "iPhone15ProMaxSimulator",
                  "x86_64-apple-macOS14.0", "SHA256DigestComputer", "com.apple.Safari.v17",
                  "Ubuntu-22.04-LTS-arm64", "k8sApiServerEndpoint3", "CVE-2024-3094-xzUtils",
                  "HTTP2ServerConnection", "IMG_20231105_143022.jpg",
                  "iVBORw0KGgo" + "AAAANSUhEUgAA",   // PNG header, split for secret scanners
                  "src/components/Button2.tsx", "WKWebView.loadHTMLString2"] {
            XCTAssertFalse(Validators.looksLikeSecret(s), s)
        }
        // A dotted random password is still caught, even with four lowercase letters in a row.
        XCTAssertTrue(Validators.looksLikeSecret("Kx9.mQ2vB7nZ4wR8tY1pL3sD6fH"))
        XCTAssertTrue(Validators.looksLikeSecret("Kx9.mQ2vB7nZmqvbR8tY1pL3sD6fH"))
    }

    func testSecretValueVetoesCodePathsAndFractions() {
        XCTAssertFalse(Validators.secretValue("response.data.token"))
        XCTAssertFalse(Validators.secretValue("req.body.password"))
        XCTAssertFalse(Validators.secretValue("142/150"))
        XCTAssertFalse(Validators.secretValue("123.4k/200k"))
        XCTAssertTrue(Validators.secretValue("my.s3cret.pass"))   // a digit: not a code path
        XCTAssertFalse(Validators.secretValue("props.user.authToken"))  // a code root
        XCTAssertTrue(Validators.secretValue("correct.horse.battery"))  // dotted passphrase
        XCTAssertTrue(Validators.secretValue("john.smith"))
        XCTAssertTrue(Validators.secretValue("data.center.rocks"))
        XCTAssertTrue(Validators.secretValue("open.sesame.secret"))    // secret-name leaf alone
        XCTAssertTrue(Validators.secretValue("iLove.myDog"))           // camelCase alone: passphrase
        XCTAssertTrue(Validators.secretValue("horse_battery.staple"))  // "_" alone: passphrase
        XCTAssertTrue(Validators.secretValue("my_secret.phrase"))
    }
}
