// Swift. The version is the base number, plus "+<build>" only when make stamped the build.
import XCTest
@testable import CheapshotCore

final class VersionTests: XCTestCase {
    func testUnstampedVersionIsTheBaseVersion() {
        // swift test never stamps, so the source tree must report the bare release number.
        XCTAssertEqual(cheapshotBuild, "")
        XCTAssertEqual(cheapshotVersion, cheapshotBaseVersion)
    }

    func testBaseVersionIsSemver() {
        // The "+build" suffix is only valid semver if the base carries no "+" of its own.
        XCTAssertNil(cheapshotBaseVersion.firstIndex(of: "+"))
        XCTAssertNotNil(cheapshotBaseVersion.range(of: #"^\d+\.\d+\.\d+(-[0-9A-Za-z.-]+)?$"#, options: .regularExpression))
    }
}
