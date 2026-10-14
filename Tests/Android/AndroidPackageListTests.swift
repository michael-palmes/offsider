@testable import OffsiderAndroid
import Testing

@Suite("Android package list")
struct AndroidPackageListTests {
    @Test("pm list packages -3 lines become sorted package names, skipping anything else")
    func parsesPackages() {
        let output = "package:com.example.zeta\r\npackage:com.mpalmes.offsider.playground\nWARNING: linker noise\npackage:com.example.zeta\npackage:\n"
        #expect(AndroidPackageList.parse(output) == ["com.example.zeta", "com.mpalmes.offsider.playground"])
    }
}
