import CryptoKit
import Foundation
import Testing
@testable import HetzCore

@Suite struct LicenseTests {
    let signer = Curve25519.Signing.PrivateKey()
    var publicKey: String { signer.publicKey.rawRepresentation.base64EncodedString() }
    let day: TimeInterval = 86_400
    let start = Date(timeIntervalSince1970: 1_793_000_000)

    @Test func issuedKeyRoundTrips() throws {
        let key = try LicenseKey.issue(owner: "Fulano de Tal", issued: start, privateKey: signer)
        let license = try LicenseKey.parse(key, publicKey: publicKey)
        #expect(license.owner == "Fulano de Tal")
        #expect(license.issued == start)
    }

    @Test func rejectsKeyFromAnotherSigner() throws {
        let forged = try LicenseKey.issue(owner: "x", privateKey: Curve25519.Signing.PrivateKey())
        #expect(throws: LicenseError.badSignature) { try LicenseKey.parse(forged, publicKey: publicKey) }
    }

    @Test func rejectsEditedOwner() throws {
        let key = try LicenseKey.issue(owner: "a", issued: start, privateKey: signer)
        let parts = key.dropFirst(LicenseKey.prefix.count).split(separator: ".")
        let json = String(decoding: Data(base64URL: parts[0])!, as: UTF8.self)
        let edited = Data(json.replacingOccurrences(of: #""o":"a""#, with: #""o":"b""#).utf8).base64URL
        #expect(edited != String(parts[0]))
        #expect(throws: LicenseError.badSignature) { try LicenseKey.parse(LicenseKey.prefix + edited + "." + parts[1], publicKey: publicKey) }
    }

    @Test func rejectsGarbage() {
        for text in ["", "ABMCHZ-PRO.", "ABMCHZ-PRO.abc", "outra-coisa.a.b", "ABMCHZ-PRO.!!.??"] {
            #expect(throws: LicenseError.malformed) { try LicenseKey.parse(text, publicKey: publicKey) }
        }
    }

    @Test func trialCountsDownThenExpires() {
        #expect(Edition.resolve(key: nil, trialStart: start, now: start, publicKey: publicKey) == .trial(daysLeft: 14))
        #expect(Edition.resolve(key: nil, trialStart: start, now: start + 13 * day, publicKey: publicKey) == .trial(daysLeft: 1))
        #expect(Edition.resolve(key: nil, trialStart: start, now: start + 14 * day, publicKey: publicKey) == .free)
        #expect(!Edition.free.allows(.presets))
        #expect(Edition.trial(daysLeft: 1).allows(.presets))
    }

    @Test func validKeyBeatsExpiredTrialAndInvalidKeyDoesNot() throws {
        let key = try LicenseKey.issue(owner: "dono", privateKey: signer)
        #expect(Edition.resolve(key: key, trialStart: start, now: start + 100 * day, publicKey: publicKey) == .pro(owner: "dono"))
        #expect(Edition.resolve(key: "ABMCHZ-PRO.x.y", trialStart: start, now: start + 100 * day, publicKey: publicKey) == .free)
    }
}

@Suite struct LicenseHardeningTests {
    let signer = Curve25519.Signing.PrivateKey()
    var publicKey: String { signer.publicKey.rawRepresentation.base64EncodedString() }
    let day: TimeInterval = 86_400
    let start = Date(timeIntervalSince1970: 1_793_000_000)

    @Test func acceptsKeyWrappedByAnEmailClient() throws {
        let key = try LicenseKey.issue(owner: "dono", privateKey: signer)
        let wrapped = "  " + key.enumerated().map { $0.offset % 60 == 59 ? "\($0.element)\r\n" : "\($0.element)" }.joined() + "\n"
        #expect(try LicenseKey.parse(wrapped, publicKey: publicKey).owner == "dono")
    }

    @Test func rollingTheClockBackDoesNotRestoreTrialDays() {
        let lastSeen = start + 20 * day
        #expect(Edition.resolve(key: nil, trialStart: start, now: start + 1 * day, lastSeen: lastSeen, publicKey: publicKey) == .free)
    }

    @Test func trialStartInTheFutureCountsAsExpired() {
        #expect(Edition.resolve(key: nil, trialStart: start + 30 * day, now: start, publicKey: publicKey) == .free)
    }

    @Test func embeddedPublicKeyIsAValidEd25519Key() throws {
        let raw = try #require(Data(base64Encoded: LicenseKey.embeddedPublicKey))
        _ = try Curve25519.Signing.PublicKey(rawRepresentation: raw)
    }
}
