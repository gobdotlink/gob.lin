import Testing
@testable import GoblinCore

@Test func releaseVersionsCompareNumericallyAndExcludeUnstableVersions() {
    #expect(ReleaseVersion("v1.10.0")! > ReleaseVersion("1.9.9")!)
    #expect(ReleaseVersion("2.0.0")! > ReleaseVersion("1.999.999")!)
    #expect(ReleaseVersion("v0.1.0") == ReleaseVersion("0.1.0"))
    #expect(ReleaseVersion("0.0.0")?.description == "0.0.0")
    for value in ["", "v", "1", "1.0", "01.0.0", "1.00.0", "1.0.0-beta.1", "1.0.0+build", "-1.0.0", "1.0.0\n", "1.0.0.1", "١.0.0", "9999999999999999999999.0.0"] {
        #expect(ReleaseVersion(value) == nil, "Rejected release version: \(value)")
    }
}
