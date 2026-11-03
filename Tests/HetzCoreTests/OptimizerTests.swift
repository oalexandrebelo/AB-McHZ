import Testing
@testable import HetzCore

@Suite struct OptimizerTests {
    let pg = try! Profile.load(from: profileURL("asus-pg259qn"))
    let benq = try! Profile.load(from: profileURL("benq-xl2430t"))

    @Test func pg259qnPicks360WhenTheDisplayPortOffersIt() {
        let offered = [240, 360, 144, 60].map { ModeInfo(width: 1920, height: 1080, hz: Double($0)) }
        #expect(Optimizer.bestMode(for: pg.macos.mode, offered: offered)?.hz == 360)
    }

    @Test func pg259qnFallsBackTo240OnHDMI() {
        let offered = [240, 144, 60].map { ModeInfo(width: 1920, height: 1080, hz: Double($0)) }
        #expect(Optimizer.bestMode(for: pg.macos.mode, offered: offered)?.hz == 240)
    }

    @Test func benqOnHDMIStaysAt60AndOnDisplayPortGets144() {
        let hdmi = [60, 50, 24].map { ModeInfo(width: 1920, height: 1080, hz: Double($0)) }
        let dp = [144, 120, 60].map { ModeInfo(width: 1920, height: 1080, hz: Double($0)) }
        #expect(Optimizer.bestMode(for: benq.macos.mode, offered: hdmi)?.hz == 60)
        #expect(Optimizer.bestMode(for: benq.macos.mode, offered: dp)?.hz == 144)
    }

    @Test func skipsUnsafeHiDPIAndOtherResolutions() {
        let offered = [
            ModeInfo(width: 1920, height: 1080, hz: 360, safe: false),  // sem EDID: não arrisca
            ModeInfo(width: 1920, height: 1080, hz: 240, hiDPI: true),
            ModeInfo(width: 2560, height: 1440, hz: 240),
            ModeInfo(width: 1920, height: 1080, hz: 240, usable: false),
        ]
        #expect(Optimizer.bestMode(for: pg.macos.mode, offered: offered) == nil)
    }

    @Test func roundsFractionalRefreshRates() {
        #expect(Optimizer.bestMode(for: benq.macos.mode, offered: [ModeInfo(width: 1920, height: 1080, hz: 59.94)])?.hz == 60)
    }

    @Test func profilesAskForSRGB() {
        #expect(pg.macos.colorProfile == "sRGB IEC61966-2.1")
        #expect(benq.macos.colorProfile == "sRGB IEC61966-2.1")
    }

    @Test func findsTheSystemSRGBProfile() throws {
        let url = try #require(ColorProfiles.url(named: "sRGB IEC61966-2.1"))
        #expect(ColorProfiles.description(of: url) == "sRGB IEC61966-2.1")
    }
}
