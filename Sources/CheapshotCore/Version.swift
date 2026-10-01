// Swift. The version every output reports (--version, the --help header, the JSON "version" field).
//
// cheapshotBaseVersion is the release number. cheapshotBuild is empty in the source tree;
// `make build` stamps it with the commit and the UTC build date while it compiles, then puts the
// file back, so a binary built with make reports e.g. "0.5.0+157ccf4.20261029" and a stale
// install is visible at a glance. The "+" part is semver build metadata, so anything that parses
// the version as semver still reads 0.5.0. Plain `swift build` and `swift test` stay unstamped.
public let cheapshotBaseVersion = "0.5.0"
public let cheapshotVersion = cheapshotBuild.isEmpty ? cheapshotBaseVersion : cheapshotBaseVersion + "+" + cheapshotBuild
