import XCTest
@testable import CheapshotPortable

final class RuleCatalogTests: XCTestCase {
    /// Mutation R6: a built-in missing from the catalog, or a catalog entry naming no built-in.
    func testCatalogNamesAreExactlyTheBuiltinNames() {
        var builtinNames: [String] = []
        for r in Rule.builtin where !builtinNames.contains(r.name) { builtinNames.append(r.name) }
        XCTAssertEqual(Set(RuleCatalog.names), Set(builtinNames), "catalog and Rule.builtin names differ")
        XCTAssertEqual(RuleCatalog.names.count, Set(RuleCatalog.names).count, "a catalog name is listed twice")
        // Same order as Rule.builtin, so --list-rules reads in the order the rules run.
        XCTAssertEqual(RuleCatalog.names, builtinNames)
    }

    func testEveryEntryHasLabelAndOneLineDescription() {
        for e in RuleCatalog.entries {
            XCTAssertFalse(e.label.isEmpty, e.name)
            XCTAssertFalse(e.description.isEmpty, e.name)
            XCTAssertFalse(e.description.contains("\n"), "\(e.name) description must be one line")
        }
    }

    func testGroupSizesMatchThePlan() {
        XCTAssertEqual(RuleCatalog.names(in: .credentials).count, 29)
        XCTAssertEqual(Set(RuleCatalog.names(in: .personal)), ["EMAIL", "PHONE", "SSN"])
        XCTAssertEqual(Set(RuleCatalog.names(in: .financial)), ["IBAN", "ROUTING", "CARD", "BANK_ACCT"])
        XCTAssertEqual(RuleCatalog.names(in: .network), ["IPV4"])
    }

    func testPresetsAreEverythingAndSecretsOnly() throws {
        XCTAssertEqual(RuleCatalog.presets.map(\.name), ["everything", "secrets-only"])
        XCTAssertEqual(RuleCatalog.preset(named: "everything")?.disabled, [])
        XCTAssertEqual(RuleCatalog.defaultPreset, "everything")
        // secrets-only keeps exactly the credentials group.
        let off = try XCTUnwrap(RuleCatalog.preset(named: "secrets-only")).disabled
        XCTAssertEqual(Set(RuleCatalog.names).subtracting(off), Set(RuleCatalog.names(in: .credentials)))
        XCTAssertNil(RuleCatalog.preset(named: "nothing"))
    }

    func testResolveNamesAndGroups() {
        XCTAssertEqual(RuleCatalog.resolve("ipv4"), ["IPV4"])
        XCTAssertEqual(RuleCatalog.resolve("group:network"), ["IPV4"])
        XCTAssertEqual(RuleCatalog.resolve("GROUP:Personal").map(Set.init), ["EMAIL", "PHONE", "SSN"])
        XCTAssertNil(RuleCatalog.resolve("group:nope"))
        XCTAssertNil(RuleCatalog.resolve("NOT_A_RULE"))
        XCTAssertNil(RuleCatalog.resolve(""))
    }
}
