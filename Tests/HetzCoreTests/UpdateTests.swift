import Foundation
import Testing
@testable import HetzCore

@Suite struct UpdateTests {
    @Test func versionsCompareNumerically() throws {
        let v = { (text: String) in try #require(AppVersion(text)) }
        #expect(try v("0.10.0") > v("0.9.1"))
        #expect(try v("v0.3.0") == v("0.3"))
        #expect(try v("1.0.0-beta") == v("1.0.0"))
        #expect(AppVersion("abc") == nil)
        #expect(AppVersion("") == nil)
    }

    private func release(_ tag: String, prerelease: Bool = false) -> Data {
        Data(#"{"tag_name":"\#(tag)","html_url":"https://github.com/oalexandrebelo/AB-McHZ/releases/tag/\#(tag)","draft":false,"prerelease":\#(prerelease)}"#.utf8)
    }

    @Test func onlyNewerStableReleaseIsOffered() throws {
        let current = try #require(AppVersion("0.3.0"))
        #expect(UpdateCheck.parse(release("v0.3.1"), current: current)?.version.description == "0.3.1")
        #expect(UpdateCheck.parse(release("v0.3.0"), current: current) == nil)
        #expect(UpdateCheck.parse(release("v0.2.9"), current: current) == nil)
        #expect(UpdateCheck.parse(release("v0.4.0", prerelease: true), current: current) == nil)
        #expect(UpdateCheck.parse(Data("{}".utf8), current: current) == nil)
    }
}
