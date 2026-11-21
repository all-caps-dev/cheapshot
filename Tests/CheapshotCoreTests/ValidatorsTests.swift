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
}
