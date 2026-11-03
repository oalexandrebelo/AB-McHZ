import CoreGraphics
import Foundation
import Testing
@testable import HetzCore

@Suite struct AutoPilotTests {
    let key = DisplayKey(vendor: 0x09D1, model: 0x7F3E, serial: 1, fallbackID: nil)
    let t0 = Date(timeIntervalSince1970: 1_793_000_000)
    let m60 = ModeInfo(width: 1920, height: 1080, hz: 60)
    let m240 = ModeInfo(width: 1920, height: 1080, hz: 240)
    let m360 = ModeInfo(width: 1920, height: 1080, hz: 360)
    let pg = try! Profile.load(from: profileURL("asus-pg259qn"))
    let benq = try! Profile.load(from: profileURL("benq-xl2430t"))

    private func connected() -> AutoPilot {
        var pilot = AutoPilot()
        pilot.observe([key], now: t0)
        return pilot
    }

    @Test func fixesRefreshOnConnectButOnlyObservesOnTick() {
        var pilot = connected()
        #expect(pilot.refreshDecision(key, current: m60, target: m360, trigger: .tick) == .switchTo(m360))  // 1ª vez: alvo novo
        pilot.recordSwitch(key, target: m360, result: .success(.applied(m360)))
        // macOS (ou o usuário) baixou para 60 Hz: no timer, só observa e passa a respeitar.
        #expect(pilot.refreshDecision(key, current: m60, target: m360, trigger: .tick) == .keep)
        #expect(pilot.isUserOverride(key))
        #expect(pilot.refreshDecision(key, current: m60, target: m360, trigger: .connectOrWake) == .keep)
    }

    @Test func wakeRestoresRefreshWhenTheUserDidNotChooseAnother() {
        var pilot = connected()
        _ = pilot.refreshDecision(key, current: m360, target: m360, trigger: .connectOrWake)
        #expect(pilot.refreshDecision(key, current: m60, target: m360, trigger: .connectOrWake) == .switchTo(m360))
    }

    @Test func doesNotRetryAModeTheWatchdogReverted() {
        var pilot = connected()
        #expect(pilot.refreshDecision(key, current: m240, target: m360, trigger: .connectOrWake) == .switchTo(m360))
        pilot.recordSwitch(key, target: m360, result: .success(.reverted(attempted: m360, observed: nil, restored: m240, revertError: 0, droppedOffline: true)))
        for trigger in [PilotTrigger.connectOrWake, .tick, .connectOrWake] {
            #expect(pilot.refreshDecision(key, current: m240, target: m360, trigger: trigger) == .keep)
        }
    }

    @Test func manualModeIsRespectedUntilThePresetChangesTheTarget() {
        var pilot = connected()
        _ = pilot.refreshDecision(key, current: m360, target: m360, trigger: .connectOrWake)
        pilot.recordUserMode(key, mode: m60)
        #expect(pilot.refreshDecision(key, current: m60, target: m360, trigger: .connectOrWake) == .keep)
        // Preset ULMB muda o alvo para 240 Hz: agora a troca é pedida.
        #expect(pilot.refreshDecision(key, current: m60, target: m240, trigger: .tick) == .switchTo(m240))
    }

    @Test func shortAbsenceIsNotAReconnection() {
        var pilot = connected()
        pilot.recordAutomaticPreset(key, desired: DesiredPreset(name: "trabalho", reason: .defaultPreset), succeeded: true)
        pilot.recordColor(key)
        #expect(pilot.observe([], now: t0 + 60).isEmpty)  // sleep: tela some por 1 min
        #expect(pilot.observe([key], now: t0 + 120).isEmpty)
        #expect(!pilot.needsColor(key))
        #expect(!pilot.shouldApply(key, desired: DesiredPreset(name: "trabalho", reason: .defaultPreset)))
        // Fora do ar além da carência: conexão nova, tudo de novo.
        pilot.observe([], now: t0 + 120 + AutoPilot.grace + 1)
        #expect(pilot.observe([key], now: t0 + 1000) == [key])
        #expect(pilot.needsColor(key))
    }

    @Test func presetIsEdgeTriggeredAndRetriesFailedDDCAFewTimes() {
        var pilot = connected()
        let work = DesiredPreset(name: "trabalho", reason: .defaultPreset)
        #expect(pilot.shouldApply(key, desired: work))
        for _ in 1..<AutoPilot.maxPresetAttempts {
            pilot.recordAutomaticPreset(key, desired: work, succeeded: false)
            #expect(pilot.shouldApply(key, desired: work))
        }
        pilot.recordAutomaticPreset(key, desired: work, succeeded: false)
        #expect(!pilot.shouldApply(key, desired: work))  // desistiu nesta conexão
        // Escolha manual vale até o desejado mudar.
        pilot.recordManualPreset(key, name: "competitivo")
        #expect(!pilot.shouldApply(key, desired: work))
        #expect(pilot.shouldApply(key, desired: DesiredPreset(name: "noite", reason: .schedule)))
    }

    @Test func desiredPresetPrioritizesAppThenScheduleThenDefault() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/Sao_Paulo"))
        let noon = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 3, hour: 12)))
        let night = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 3, hour: 23, minute: 30)))
        let early = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 4, hour: 6, minute: 59)))
        let apps = ["com.example.game": "competitivo"]
        #expect(AutoPilot.desiredPreset(benq, frontmostApp: nil, appPresets: apps, now: noon, calendar: calendar) == DesiredPreset(name: "trabalho", reason: .defaultPreset))
        #expect(AutoPilot.desiredPreset(benq, frontmostApp: nil, appPresets: apps, now: night, calendar: calendar) == DesiredPreset(name: "noite", reason: .schedule))
        #expect(AutoPilot.desiredPreset(benq, frontmostApp: nil, appPresets: apps, now: early, calendar: calendar)?.name == "noite")
        #expect(AutoPilot.desiredPreset(benq, frontmostApp: "com.example.game", appPresets: apps, now: night, calendar: calendar) == DesiredPreset(name: "competitivo", reason: .app))
        #expect(AutoPilot.desiredPreset(benq, frontmostApp: "com.example.game", appPresets: ["com.example.game": "inexistente"], now: noon, calendar: calendar)?.reason == .defaultPreset)
    }

    @Test func ulmbPresetPinsTheTargetAt240() {
        let offered = [m360, m240, m60]
        #expect(Optimizer.target(pg, preset: "trabalho", offered: offered) == m360)
        #expect(Optimizer.target(pg, preset: "ulmb", offered: offered) == m240)
        #expect(Optimizer.target(pg, preset: "ulmb", offered: [m360, m60]) == nil)  // sem 240 Hz, não inventa outra taxa
    }

    @Test func missingEDIDDisplaysGetDistinctKeys() {
        let a = DisplayInfo.test(id: 3), b = DisplayInfo.test(id: 5)
        #expect(a.key != b.key)
    }
}

@Suite struct ScheduleAndSafetyTests {
    @Test func parsesWindowsAcrossMidnight() throws {
        let night = try #require(ScheduleWindow("20:00-07:00"))
        #expect(night.contains(20 * 60) && night.contains(23 * 60 + 59) && night.contains(0) && night.contains(6 * 60 + 59))
        #expect(!night.contains(7 * 60) && !night.contains(12 * 60))
        let day = try #require(ScheduleWindow("08:30 - 18:00"))
        #expect(day.contains(8 * 60 + 30) && !day.contains(18 * 60))
        for bad in ["", "20:00", "25:00-07:00", "20:00-20:00", "8h-18h"] { #expect(ScheduleWindow(bad) == nil) }
    }

    @Test func profilesCannotWriteDestructiveVCPs() throws {
        for code in ["0x04", "0x60", "0xD6"] {
            let json = #"{"schema":"ab-mchz/profile@1","id":"x","monitor":{"model":"m"},"macos":{"mode":{"width":1,"height":1,"hz":1}},"presets":{"p":{"ddc":{"\#(code)":1}}}}"#
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("hetz-\(UUID().uuidString).json")
            try Data(json.utf8).write(to: url)
            #expect(throws: DecodingError.self) { try Profile.load(from: url) }
        }
    }

    @Test func rejectsProfilesWithTwoDefaults() throws {
        let json = #"{"schema":"ab-mchz/profile@1","id":"x","monitor":{"model":"m"},"macos":{"mode":{"width":1,"height":1,"hz":1}},"presets":{"a":{"default":true},"b":{"default":true}}}"#
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hetz-\(UUID().uuidString).json")
        try Data(json.utf8).write(to: url)
        #expect(throws: ProfileError.multipleDefaults(["a", "b"])) { try Profile.load(from: url) }
    }

    @Test func busRefusesWritesOutsideDDC() {
        #expect(MCCS.safeCodes.isDisjoint(with: [0x04, 0x05, 0x06, 0x08, 0x60, 0xD6]))
    }
}

extension DisplayInfo {
    static func test(id: CGDirectDisplayID, vendor: UInt32 = 0) -> DisplayInfo {
        DisplayInfo(id: id, vendor: vendor, model: 0, serial: 0, name: nil, isBuiltin: false, isVirtual: false,
                    isMain: false, transport: "HDMI", hasDDC: true, currentMode: nil)
    }
}
