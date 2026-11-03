// Barramento I2C do monitor no Apple Silicon via IOAVService (símbolos privados do IOKit).
// Referência de abordagem: Arm64DDC do MonitorControl (MIT). Os símbolos são resolvidos por dlsym:
// num Intel, ou se a Apple removê-los, o DDC fica indisponível em vez de o binário não carregar.
import CoreGraphics
import Foundation
import IOKit

public enum DDCError: Error, Equatable, Sendable, CustomStringConvertible {
    case unavailable(CGDirectDisplayID)
    case io(IOReturn)
    case nullReply
    case badChecksum
    case malformedReply
    case badEDID(String)
    case unsupportedVCP(UInt8)
    case valueOutOfRange(code: UInt8, value: UInt16, maximum: UInt16)
    case circuitOpen(retryAfter: Duration)

    /// Falhas de barramento: contam para o circuit breaker e merecem nova tentativa.
    public var isTransient: Bool {
        switch self {
        case .io, .nullReply, .badChecksum, .malformedReply, .badEDID: true
        default: false
        }
    }

    public var description: String {
        switch self {
        case .unavailable(let id): "tela \(id) sem canal DDC (interna, virtual ou sem IOAVService externo)"
        case .io(let code): "falha de I2C (IOReturn 0x\(String(UInt32(bitPattern: code), radix: 16)))"
        case .nullReply: "monitor ocupado (null message)"
        case .badChecksum: "resposta DDC com checksum inválido"
        case .malformedReply: "resposta DDC malformada"
        case .badEDID(let why): "EDID ilegível por I2C (\(why))"
        case .unsupportedVCP(let code): "VCP \(MCCS.format(code)) não suportado pelo monitor"
        case .valueOutOfRange(let code, let value, let maximum): "valor \(value) acima do máximo \(maximum) do VCP \(MCCS.format(code))"
        case .circuitOpen(let wait): "tela isolada pelo circuit breaker; tente de novo em \(Int(wait.timeInterval.rounded(.up))) s"
        }
    }
}

/// Primitivas bloqueantes; o motor as chama só na fila serial de I2C.
public protocol I2CBus: Sendable {
    func write(chip: UInt8, offset: UInt8, _ bytes: [UInt8]) throws(DDCError)
    func read(chip: UInt8, offset: UInt8, count: Int) throws(DDCError) -> [UInt8]
    /// Entrega ao DCP um EDID substituto; nil devolve o do monitor.
    func setVirtualEDID(_ edid: [UInt8]?) throws(DDCError)
}

extension I2CBus {
    public func setVirtualEDID(_ edid: [UInt8]?) throws(DDCError) {
        throw .io(kIOReturnUnsupported)
    }
}

final class IOAVBus: I2CBus, @unchecked Sendable {
    private let service: CFTypeRef
    private let dpDevice: CFTypeRef?

    init(service: CFTypeRef, dpDevice: CFTypeRef?) {
        self.service = service
        self.dpDevice = dpDevice
    }

    /// IOAVServiceSetVirtualEDIDMode (1 = substituto, 0 = original) e IODPDeviceSetUpdated para o DCP
    /// reprocessar o EDID e refazer a tabela de modos. Sequência de owomocha/macos-360hz-unlock (MIT).
    /// Volátil: replug, sleep e reboot descartam o EDID virtual.
    func setVirtualEDID(_ edid: [UInt8]?) throws(DDCError) {
        let api = PrivateAPI.shared
        guard let setMode = api.avSetVirtualEDIDMode, let setUpdated = api.dpSetUpdated, let dpDevice else {
            throw .io(kIOReturnUnsupported)
        }
        let result = setMode(service, edid == nil ? 0 : 1, edid.map { Data($0) as CFData })
        guard result == kIOReturnSuccess else { throw .io(result) }
        let updated = setUpdated(dpDevice, 1)
        guard updated == kIOReturnSuccess else { throw .io(updated) }
    }

    func write(chip: UInt8, offset: UInt8, _ bytes: [UInt8]) throws(DDCError) {
        // Escrita só no DDC/CI. 0x50 é a EEPROM do EDID e 0x30 o ponteiro de segmento: gravar ali corrompe o monitor.
        guard chip == MCCS.chipAddress else { throw .io(kIOReturnNotPermitted) }
        guard let write = PrivateAPI.shared.avWrite else { throw .io(kIOReturnUnsupported) }
        var buffer = bytes
        let result = write(service, UInt32(chip), UInt32(offset), &buffer, UInt32(buffer.count))
        guard result == kIOReturnSuccess else { throw .io(result) }
    }

    func read(chip: UInt8, offset: UInt8, count: Int) throws(DDCError) -> [UInt8] {
        guard let read = PrivateAPI.shared.avRead else { throw .io(kIOReturnUnsupported) }
        var buffer = [UInt8](repeating: 0, count: count)
        let result = read(service, UInt32(chip), UInt32(offset), &buffer, UInt32(count))
        guard result == kIOReturnSuccess else { throw .io(result) }
        return buffer
    }
}

struct PrivateAPI: @unchecked Sendable {
    typealias AVCreate = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?
    typealias AVTransfer = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn
    typealias InfoDictionary = @convention(c) (CGDirectDisplayID) -> Unmanaged<CFDictionary>?
    // Modos por número (SkyLight). Declarações do displayplacer (MIT).
    typealias ModeCount = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Int32>) -> Void
    typealias ModeDescription = @convention(c) (CGDirectDisplayID, Int32, UnsafeMutableRawPointer, Int32) -> Void
    typealias ConfigureMode = @convention(c) (CGDisplayConfigRef?, CGDirectDisplayID, Int32) -> CGError

    typealias SetVirtualEDIDMode = @convention(c) (CFTypeRef, UInt32, CFData?) -> IOReturn
    typealias DeviceUpdated = @convention(c) (CFTypeRef, UInt32) -> IOReturn

    let avCreate: AVCreate?
    let avRead: AVTransfer?
    let avWrite: AVTransfer?
    let avSetVirtualEDIDMode: SetVirtualEDIDMode?
    let dpDeviceCreate: AVCreate?
    let dpSetUpdated: DeviceUpdated?
    let displayInfo: InfoDictionary?
    let modeCount: ModeCount?
    let modeDescription: ModeDescription?
    let configureMode: ConfigureMode?

    static let shared = PrivateAPI()

    private init() {
        func symbol<T>(_ handle: UnsafeMutableRawPointer?, _ name: String, as _: T.Type) -> T? {
            dlsym(handle, name).map { unsafeBitCast($0, to: T.self) }
        }
        let iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW)
        let coreDisplay = dlopen("/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay", RTLD_NOW)
        avCreate = symbol(iokit, "IOAVServiceCreateWithService", as: AVCreate.self)
        avRead = symbol(iokit, "IOAVServiceReadI2C", as: AVTransfer.self)
        avWrite = symbol(iokit, "IOAVServiceWriteI2C", as: AVTransfer.self)
        avSetVirtualEDIDMode = symbol(iokit, "IOAVServiceSetVirtualEDIDMode", as: SetVirtualEDIDMode.self)
        dpDeviceCreate = symbol(iokit, "IODPDeviceCreateWithService", as: AVCreate.self)
        dpSetUpdated = symbol(iokit, "IODPDeviceSetUpdated", as: DeviceUpdated.self)
        displayInfo = symbol(coreDisplay, "CoreDisplay_DisplayCreateInfoDictionary", as: InfoDictionary.self)
        let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW)
        modeCount = symbol(skyLight, "CGSGetNumberOfDisplayModes", as: ModeCount.self)
        modeDescription = symbol(skyLight, "CGSGetDisplayModeDescriptionOfLength", as: ModeDescription.self)
        configureMode = symbol(skyLight, "CGSConfigureDisplayMode", as: ConfigureMode.self)
    }
}

/// I2C é lento e bloqueante: tudo passa por esta fila serial, fora do pool cooperativo.
private let i2cQueue = DispatchQueue(label: "ab-mchz.i2c")

func onI2CQueue<T: Sendable>(_ work: @escaping @Sendable () throws(DDCError) -> T) async throws(DDCError) -> T {
    let result: Result<T, DDCError> = await withCheckedContinuation { continuation in
        i2cQueue.async { continuation.resume(returning: Result(catching: work)) }
    }
    return try result.get()
}
