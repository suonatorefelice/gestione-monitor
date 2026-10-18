// ddc — controllo nativo DDC/CI del monitor esterno su Apple Silicon.
// Uso: ddc get <vcp>          es. ddc get 0x10   (luminosità)
//      ddc set <vcp> <valore> es. ddc set 0x10 70
//      ddc dim <5-100>        luminosità software (gamma), senza DDC
// VCP utili: 0x10 luminosità, 0x12 contrasto, 0x62 volume, 0x8D mute, 0x60 input, 0xD6 power
import Foundation
import IOKit
import CoreGraphics

typealias IOAVService = CFTypeRef
@_silgen_name("IOAVServiceCreateWithService")
func IOAVServiceCreateWithService(_ alloc: CFAllocator?, _ service: io_service_t) -> Unmanaged<IOAVService>?
@_silgen_name("IOAVServiceReadI2C")
func IOAVServiceReadI2C(_ s: IOAVService, _ chip: UInt32, _ offset: UInt32, _ buf: UnsafeMutableRawPointer, _ len: UInt32) -> IOReturn
@_silgen_name("IOAVServiceWriteI2C")
func IOAVServiceWriteI2C(_ s: IOAVService, _ chip: UInt32, _ offset: UInt32, _ buf: UnsafeMutableRawPointer, _ len: UInt32) -> IOReturn

let chip: UInt32 = 0x37, dataAddr: UInt32 = 0x51

func externalAVService() -> IOAVService? {
    var iter = io_iterator_t()
    guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("DCPAVServiceProxy"), &iter) == KERN_SUCCESS else { return nil }
    defer { IOObjectRelease(iter) }
    while case let s = IOIteratorNext(iter), s != 0 {
        let loc = IORegistryEntryCreateCFProperty(s, "Location" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String
        if loc == "External", let av = IOAVServiceCreateWithService(kCFAllocatorDefault, s) {
            IOObjectRelease(s); return av.takeRetainedValue()
        }
        IOObjectRelease(s)
    }
    return nil
}

func send(_ av: IOAVService, _ payload: [UInt8]) -> IOReturn {
    var pkt: [UInt8] = [0x80 | UInt8(payload.count)] + payload
    var chk = UInt8(chip << 1) ^ UInt8(dataAddr)
    for b in pkt { chk ^= b }
    pkt.append(chk)
    var r: IOReturn = 0
    for _ in 0..<2 { r = IOAVServiceWriteI2C(av, chip, dataAddr, &pkt, UInt32(pkt.count)); usleep(10_000) }
    return r
}

func getVCP(_ av: IOAVService, _ code: UInt8) -> (cur: Int, max: Int)? {
    for _ in 0..<5 {
        _ = send(av, [0x01, code])
        usleep(50_000)
        var reply = [UInt8](repeating: 0, count: 11)
        guard IOAVServiceReadI2C(av, chip, 0, &reply, 11) == 0 else { usleep(20_000); continue }
        var chk: UInt8 = 0x50
        for b in reply[0..<10] { chk ^= b }
        guard chk == reply[10], reply[2] == 0x02, reply[3] == 0x00 else { usleep(20_000); continue }
        return (Int(reply[8]) << 8 | Int(reply[9]), Int(reply[6]) << 8 | Int(reply[7]))
    }
    return nil
}

func parse(_ s: String) -> Int? { s.hasPrefix("0x") ? Int(s.dropFirst(2), radix: 16) : Int(s) }

// --- Luminosità software (gamma): funziona anche senza DDC.
// Il gamma vale solo finché il processo che l'ha impostato è vivo, quindi
// `dim` avvia un processo in background che lo mantiene (e lo riapplica).
func externalDisplay() -> CGDirectDisplayID? {
    var ids = [CGDirectDisplayID](repeating: 0, count: 8); var n: UInt32 = 0
    CGGetOnlineDisplayList(8, &ids, &n)
    return ids.prefix(Int(n)).first { CGDisplayIsBuiltin($0) == 0 }
}
let pidFile = NSHomeDirectory() + "/.ddc-dim.pid"
func stopHolder() {
    if let s = try? String(contentsOfFile: pidFile, encoding: .utf8), let pid = pid_t(s.trimmingCharacters(in: .whitespacesAndNewlines)) { kill(pid, SIGTERM) }
    try? FileManager.default.removeItem(atPath: pidFile)
}

let a = CommandLine.arguments
if a.count > 2, a[1] == "dim", let pct = Int(a[2]) {
    stopHolder()
    if pct >= 100 { print("Luminosità software ripristinata al 100%"); exit(0) }
    let p = Process(); p.executableURL = URL(fileURLWithPath: a[0]); p.arguments = ["_hold", String(max(5, pct))]
    try p.run()
    try? String(p.processIdentifier).write(toFile: pidFile, atomically: true, encoding: .utf8)
    print("Luminosità software al \(max(5, pct))% (pid \(p.processIdentifier)). 'ddc dim 100' per tornare normale.")
    exit(0)
}
if a.count > 2, a[1] == "_hold", let pct = Int(a[2]) {
    signal(SIGTERM) { _ in CGDisplayRestoreColorSyncSettings(); exit(0) }
    let f = Float(pct) / 100
    while true {
        if let d = externalDisplay() { CGSetDisplayTransferByFormula(d, 0, f, 1, 0, f, 1, 0, f, 1) }
        sleep(2)
    }
}

guard let av = externalAVService() else { fputs("Nessun display esterno DCPAVService trovato\n", stderr); exit(1) }
switch (a.count > 1 ? a[1] : "", a.count > 2 ? parse(a[2]) : nil) {
case ("get", let c?):
    if let v = getVCP(av, UInt8(c)) { print("VCP 0x\(String(c, radix: 16)): \(v.cur) / \(v.max)") }
    else { fputs("Lettura fallita (il monitor/porta potrebbe non supportare DDC)\n", stderr); exit(2) }
case ("set", let c?) where a.count > 3:
    guard let v = parse(a[3]) else { exit(64) }
    let r = send(av, [0x03, UInt8(c), UInt8(v >> 8), UInt8(v & 0xff)])
    print(r == 0 ? "OK" : "Errore IOReturn \(r)")
default:
    print("Uso: ddc get <vcp> | ddc set <vcp> <valore> | ddc dim <5-100>")
}
