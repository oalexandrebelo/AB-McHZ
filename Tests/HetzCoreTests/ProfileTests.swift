import Foundation
import Testing
@testable import HetzCore

let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

func profileURL(_ name: String) -> URL {
    repoRoot.appendingPathComponent("profiles/\(name).json")
}

@Suite struct ProfileTests {
    static let files = ["benq-xl2430t", "asus-pg259qn", "asus-xg259qn"]

    @Test(arguments: files)
    func everyProfileParses(name: String) throws {
        let profile = try Profile.load(from: profileURL(name))
        #expect(profile.schema == Profile.schemaID)
        #expect(!profile.presets.isEmpty)
        #expect(profile.presets.values.filter(\.isDefault).count == 1)
        for presetName in profile.presets.keys {
            let plan = try profile.plan(for: presetName)
            #expect(plan.mode.width == 1920 && plan.mode.height == 1080)
            #expect(!plan.hiDPI)
        }
    }

    @Test func profilesFolderHasExactlyTheseThree() throws {
        let names = try FileManager.default.contentsOfDirectory(atPath: repoRoot.appendingPathComponent("profiles").path)
            .filter { $0.hasSuffix(".json") }.map { String($0.dropLast(5)) }
        #expect(Set(names) == Set(Self.files))
    }

    @Test func benqWorkPreset() throws {
        let profile = try Profile.load(from: profileURL("benq-xl2430t"))
        #expect(profile.defaultPresetName == "trabalho")
        #expect(profile.presets["trabalho"]?.ddc == [0x10: 25, 0x12: 50, 0x14: 11, 0x16: 93, 0x18: 88, 0x1A: 97])
        let plan = try profile.plan(for: "trabalho")
        #expect(plan.mode == DisplayModeSpec(width: 1920, height: 1080, hz: 144))
        #expect(plan.fallbackHz == 60)
        #expect(plan.ddc.map(\.code) == [0x10, 0x12, 0x14, 0x16, 0x18, 0x1A])
        #expect(try profile.plan(for: "competitivo").requires == "DisplayPort 144 Hz")
    }

    @Test func benqNightPresetKeepsMacOSNoteAsText() throws {
        let night = try #require(try Profile.load(from: profileURL("benq-xl2430t")).presets["noite"])
        #expect(night.macosNote?.contains("Night Shift") == true)
        #expect(night.hzOverride == nil)
        #expect(night.ddc == [0x10: 8])
    }

    @Test func benqProfileMatchesEDIDReadFromTheMonitor() throws {
        let profile = try Profile.load(from: profileURL("benq-xl2430t"))
        let edid = try EDID(Array(Data(contentsOf: repoRoot.appendingPathComponent("profiles/edid/benq-xl2430t-hdmi.bin"))))
        #expect(try #require(profile.monitor.edid).matches(edid))
    }

    @Test func matchesDisplaysByEDIDOrModelName() throws {
        let edid = try EDID(Array(Data(contentsOf: repoRoot.appendingPathComponent("profiles/edid/benq-xl2430t-hdmi.bin"))))
        let benq = try Profile.load(from: profileURL("benq-xl2430t"))
        let pg = try Profile.load(from: profileURL("asus-pg259qn"))
        #expect(benq.matches(edid: edid, name: nil))
        #expect(!benq.matches(edid: nil, name: "BenQ XL2430T"))  // o perfil tem EDID: nome não basta
        #expect(pg.matches(edid: nil, name: "ROG PG259QN"))
        #expect(!pg.matches(edid: edid, name: "BenQ XL2430T"))
    }

    @Test func loadAllReadsTheProfilesFolder() {
        let ids = Profile.loadAll(in: repoRoot.appendingPathComponent("profiles")).map(\.id)
        #expect(ids == ["asus-pg259qn", "asus-xg259qn", "benq-xl2430t"])
    }

    @Test func userFolderOverridesBundledProfileByID() throws {
        let user = FileManager.default.temporaryDirectory.appendingPathComponent("ab-mchz-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: user, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: user) }
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: profileURL("benq-xl2430t"))) as! [String: Any]
        json["monitor"] = (json["monitor"] as! [String: Any]).merging(["model": "BenQ editado"]) { $1 }
        try JSONSerialization.data(withJSONObject: json).write(to: user.appendingPathComponent("minha-benq.json"))

        let merged = Profile.loadAll(in: [repoRoot.appendingPathComponent("profiles"), user])
        #expect(merged.map(\.id) == ["asus-pg259qn", "asus-xg259qn", "benq-xl2430t"])
        #expect(merged.last?.monitor.model == "BenQ editado")
    }

    @Test func pg259qnULMBOverridesRefreshWithoutFallback() throws {
        let profile = try Profile.load(from: profileURL("asus-pg259qn"))
        let plan = try profile.plan(for: "ulmb")
        #expect(plan.mode.hz == 240)
        #expect(plan.fallbackHz == nil)
        #expect(plan.ddc.isEmpty)
        #expect(plan.requires?.contains("240 Hz") == true)
        #expect(try profile.plan(for: "trabalho").mode.hz == 360)
        #expect(try profile.plan(for: "trabalho").fallbackHz == 240)
    }

    @Test func xg259qnHasNoEDIDReference() throws {
        let profile = try Profile.load(from: profileURL("asus-xg259qn"))
        #expect(profile.monitor.edid == nil)
        #expect(profile.presets["trabalho"]?.ddc == [0x10: 25])
        #expect(profile.presets["competitivo"]?.ddc == [0x10: 60])
    }

    @Test func unknownPresetListsAlternatives() throws {
        let profile = try Profile.load(from: profileURL("asus-xg259qn"))
        #expect(throws: ProfileError.unknownPreset("ulmb", available: ["competitivo", "trabalho"])) {
            try profile.plan(for: "ulmb")
        }
    }

    @Test func rejectsOtherSchemas() throws {
        let url = try temporaryJSON(#"{"schema":"ab-mchz/profile@2","id":"x","monitor":{"model":"m"},"macos":{"mode":{"width":1,"height":1,"hz":1}},"presets":{}}"#)
        #expect(throws: ProfileError.unsupportedSchema("ab-mchz/profile@2")) { try Profile.load(from: url) }
    }

    @Test(arguments: [#"{"10": 5}"#, #"{"0x10": 70000}"#, #"{"0x1FF": 1}"#])
    func rejectsInvalidDDCPairs(ddc: String) throws {
        let url = try temporaryJSON(#"{"schema":"ab-mchz/profile@1","id":"x","monitor":{"model":"m"},"macos":{"mode":{"width":1,"height":1,"hz":1}},"presets":{"p":{"ddc":\#(ddc)}}}"#)
        #expect(throws: DecodingError.self) { try Profile.load(from: url) }
    }

    private func temporaryJSON(_ text: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hetz-\(UUID().uuidString).json")
        try Data(text.utf8).write(to: url)
        return url
    }
}

@Suite struct EDIDTests {
    let bytes = try! Array(Data(contentsOf: repoRoot.appendingPathComponent("profiles/edid/benq-xl2430t-hdmi.bin")))

    @Test func decodesBenQ() throws {
        let edid = try EDID(bytes)
        #expect(edid.manufacturerID == "BNQ")
        #expect(edid.vendorNumber == 0x09D1)
        #expect(edid.productCode == 0x7F3E)
        #expect(edid.displayName == "BenQ XL2430T")
        #expect(edid.serialText == "00000000000")
        #expect(edid.yearOfManufacture == 2014)
        #expect(edid.extensionCount == 1)
    }

    @Test func reportsTheCorruptedFirstByte() throws {
        let issues = try EDID(bytes).issues
        #expect(issues.contains { $0.contains("byte 0 = 0xFF") })
        #expect(issues.contains { $0.contains("bloco 0") })
        var fixed = bytes
        fixed[0] = 0x00
        #expect(try EDID(fixed).issues.isEmpty)
    }

    @Test func repairsOnlyAHeaderByteDefect() throws {
        let repaired = try #require(try EDID(bytes).headerRepaired)
        #expect(repaired.bytes[0] == 0x00)
        #expect(repaired.issues.isEmpty)
        #expect(Array(repaired.bytes[1...]) == Array(bytes[1...]))
        #expect(repaired.headerRepaired == nil)  // nada mais a corrigir
        var twoDefects = bytes
        twoDefects[20] ^= 0x01  // outro byte errado: o checksum não fecha só com o cabeçalho
        #expect(try EDID(twoDefects).headerRepaired == nil)
    }

    @Test func refusesGarbage() {
        #expect(throws: EDIDError.notAnEDID) { try EDID([UInt8](repeating: 0xFF, count: 128)) }
        #expect(throws: EDIDError.badLength(100)) { try EDID([UInt8](repeating: 0, count: 100)) }
    }
}
