// Gestione Monitor — regolazioni del monitor dalla barra dei menu.
// Software (gamma): luminosità, contrasto, gamma, temperatura colore, guadagni R/G/B.
// Nativo: risoluzione e frequenza. Hardware (DDC/CI): solo se il monitor lo accetta.
import SwiftUI
import AppKit
import CoreGraphics
import IOKit
import ServiceManagement
import XPC

// MARK: - DDC/CI (IOAVService, API private usate anche da MonitorControl)

@_silgen_name("IOAVServiceCreateWithService")
func IOAVServiceCreateWithService(_ alloc: CFAllocator?, _ service: io_service_t) -> Unmanaged<CFTypeRef>?
@_silgen_name("IOAVServiceReadI2C")
func IOAVServiceReadI2C(_ s: CFTypeRef, _ chip: UInt32, _ offset: UInt32, _ buf: UnsafeMutableRawPointer, _ len: UInt32) -> IOReturn
@_silgen_name("IOAVServiceWriteI2C")
func IOAVServiceWriteI2C(_ s: CFTypeRef, _ chip: UInt32, _ offset: UInt32, _ buf: UnsafeMutableRawPointer, _ len: UInt32) -> IOReturn

enum DDC {
    static func externalService() -> CFTypeRef? {
        var iter = io_iterator_t()
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("DCPAVServiceProxy"), &iter) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iter) }
        while case let s = IOIteratorNext(iter), s != 0 {
            defer { IOObjectRelease(s) }
            let loc = IORegistryEntryCreateCFProperty(s, "Location" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String
            if loc == "External", let av = IOAVServiceCreateWithService(kCFAllocatorDefault, s) { return av.takeRetainedValue() }
        }
        return nil
    }

    static func send(_ av: CFTypeRef, _ payload: [UInt8]) {
        var pkt: [UInt8] = [0x80 | UInt8(payload.count)] + payload
        var chk: UInt8 = 0x6E ^ 0x51
        for b in pkt { chk ^= b }
        pkt.append(chk)
        for _ in 0..<2 { _ = IOAVServiceWriteI2C(av, 0x37, 0x51, &pkt, UInt32(pkt.count)); usleep(10_000) }
    }

    static func get(_ av: CFTypeRef, _ code: UInt8) -> (cur: Int, max: Int)? {
        for _ in 0..<3 {
            send(av, [0x01, code])
            usleep(50_000)
            var r = [UInt8](repeating: 0, count: 11)
            guard IOAVServiceReadI2C(av, 0x37, 0, &r, 11) == 0 else { continue }
            var chk: UInt8 = 0x50
            for b in r[0..<10] { chk ^= b }
            if chk == r[10], r[2] == 0x02, r[3] == 0x00 { return (Int(r[8]) << 8 | Int(r[9]), Int(r[6]) << 8 | Int(r[7])) }
            usleep(20_000)
        }
        return nil
    }

    static func set(_ av: CFTypeRef, _ code: UInt8, _ value: Int) {
        send(av, [0x03, code, UInt8(value >> 8), UInt8(value & 0xFF)])
    }
}

// MARK: - Modello

struct ColorSettings: Codable, Equatable {
    var brightness = 1.0     // 0.1 ... 1
    var contrast = 1.0       // 0.5 ... 1.5
    var gamma = 1.0          // 0.5 ... 2 (esponente aggiuntivo)
    var temperature = 6500.0 // K, 6500 = neutro
    var red = 1.0, green = 1.0, blue = 1.0

    static let neutral = ColorSettings()
}

struct DisplayMode: Hashable {
    let width: Int, height: Int, refresh: Double, hiDPI: Bool
    let mode: CGDisplayMode
    var label: String {
        "\(width)×\(height)" + (hiDPI ? " HiDPI" : "") + (refresh > 0 ? " @ \(Int(refresh.rounded())) Hz" : "")
    }
    static func == (a: DisplayMode, b: DisplayMode) -> Bool { a.label == b.label }
    func hash(into h: inout Hasher) { h.combine(label) }
}

struct ScreenInfo: Identifiable, Hashable {
    let id: CGDirectDisplayID
    let name: String
}

/// Moltiplicatori RGB per una temperatura colore (approssimazione di Tanner Helland), normalizzati a 6500 K.
func kelvinToRGB(_ k: Double) -> (Double, Double, Double) {
    func raw(_ k: Double) -> (Double, Double, Double) {
        let t = k / 100
        let r = t <= 66 ? 255 : 329.698727446 * pow(t - 60, -0.1332047592)
        let g = t <= 66 ? 99.4708025861 * log(t) - 161.1195681661 : 288.1221695283 * pow(t - 60, -0.0755148492)
        let b = t >= 66 ? 255 : (t <= 19 ? 0 : 138.5177312231 * log(t - 10) - 305.0447927307)
        return (min(max(r, 0), 255), min(max(g, 0), 255), min(max(b, 0), 255))
    }
    let c = raw(k), n = raw(6500)
    let (r, g, b) = (c.0 / n.0, c.1 / n.1, c.2 / n.2)
    let m = max(r, g, b)
    return (r / m, g / m, b / m)
}

@MainActor
final class MonitorModel: ObservableObject {
    @Published var screens: [ScreenInfo] = []
    @Published var selected: CGDirectDisplayID = 0 { didSet { loadForSelected() } }
    @Published var settings = ColorSettings() { didSet { if settings != oldValue { applyAll(); save() } } }
    @Published var modes: [DisplayMode] = []
    @Published var currentMode: DisplayMode?
    @Published var ddcAvailable = false
    @Published var ddcBrightness = 50.0
    @Published var ddcContrast = 50.0
    @Published var ddcVolume = 50.0
    /// Agente launchd (~/Library/LaunchAgents) che avvia l'app quando si collega un monitor esterno.
    static let agentLabel = "local.pasquale.gestionemonitor.agent"
    static let agentPath = NSHomeDirectory() + "/Library/LaunchAgents/\(agentLabel).plist"
    @Published var launchOnConnect = FileManager.default.fileExists(atPath: MonitorModel.agentPath)
    private var quitWork: DispatchWorkItem?

    private var allSettings: [String: ColorSettings] = [:]
    private var customNames: [String: String] = UserDefaults.standard.dictionary(forKey: "names") as? [String: String] ?? [:]

    /// Nome personalizzato del monitor selezionato (vuoto = nome di sistema).
    var customName: String {
        get { customNames[key(selected)] ?? "" }
        set {
            let v = newValue.trimmingCharacters(in: .whitespaces)
            customNames[key(selected)] = v.isEmpty ? nil : v
            UserDefaults.standard.set(customNames, forKey: "names")
            refreshScreens()
        }
    }
    private var ddcService: CFTypeRef?
    private var timer: Timer?

    init() {
        if let data = UserDefaults.standard.data(forKey: "settings"),
           let s = try? JSONDecoder().decode([String: ColorSettings].self, from: data) { allSettings = s }
        refreshScreens()
        CGDisplayRegisterReconfigurationCallback({ _, flags, _ in
            guard !flags.contains(.beginConfigurationFlag) else { return }
            DispatchQueue.main.async { AppDelegate.model?.refreshScreens() }
        }, nil)
        // macOS (ColorSync, Night Shift, cambio risoluzione) può resettare il gamma: lo riapplichiamo.
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in
            MainActor.assumeIsolated { AppDelegate.model?.applyAll() }
        }
        probeDDC()
    }

    func key(_ id: CGDirectDisplayID) -> String {
        "\(CGDisplayVendorNumber(id))-\(CGDisplayModelNumber(id))-\(CGDisplaySerialNumber(id))"
    }

    func refreshScreens() {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16); var n: UInt32 = 0
        CGGetOnlineDisplayList(16, &ids, &n)
        let names = Dictionary(NSScreen.screens.compactMap { s -> (CGDirectDisplayID, String)? in
            guard let num = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            return (num.uint32Value, s.localizedName)
        }, uniquingKeysWith: { a, _ in a })
        screens = ids.prefix(Int(n)).map { ScreenInfo(id: $0, name: customNames[key($0)] ?? names[$0] ?? (CGDisplayIsBuiltin($0) != 0 ? "Interno" : "Esterno")) }
            .sorted { CGDisplayIsBuiltin($0.id) < CGDisplayIsBuiltin($1.id) }
        if !screens.contains(where: { $0.id == selected }) { selected = screens.first?.id ?? 0 } else { loadForSelected() }
        applyAll()
        scheduleQuitIfNoExternal()
    }

    /// Senza monitor esterni l'app non serve: si chiude (dopo una breve attesa, per ignorare
    /// gli scollegamenti momentanei durante i cambi di risoluzione). La riapre launchd al prossimo collegamento.
    private func scheduleQuitIfNoExternal() {
        quitWork?.cancel()
        guard !screens.contains(where: { CGDisplayIsBuiltin($0.id) == 0 }) else { return }
        let work = DispatchWorkItem {
            MainActor.assumeIsolated {
                guard let m = AppDelegate.model, !m.screens.contains(where: { CGDisplayIsBuiltin($0.id) == 0 }) else { return }
                NSApp.terminate(nil)
            }
        }
        quitWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
    }

    private func loadForSelected() {
        guard selected != 0 else { return }
        let s = allSettings[key(selected)] ?? .neutral
        if s != settings { settings = s }
        loadModes()
    }

    private func save() {
        guard selected != 0 else { return }
        allSettings[key(selected)] = settings
        if let d = try? JSONEncoder().encode(allSettings) { UserDefaults.standard.set(d, forKey: "settings") }
    }

    func applyAll() {
        for s in screens { apply(allSettings[key(s.id)] ?? .neutral, to: s.id) }
    }

    private func apply(_ c: ColorSettings, to id: CGDirectDisplayID) {
        let (tr, tg, tb) = kelvinToRGB(c.temperature)
        let gains = [tr * c.red, tg * c.green, tb * c.blue]
        let n = 256
        var tables = [[CGGammaValue]](repeating: [], count: 3)
        for ch in 0..<3 {
            tables[ch] = (0..<n).map { i in
                var x = Double(i) / Double(n - 1)
                x = (x - 0.5) * c.contrast + 0.5
                x = pow(min(max(x, 0), 1), c.gamma)
                return CGGammaValue(min(max(x * c.brightness * gains[ch], 0), 1))
            }
        }
        CGSetDisplayTransferByTable(id, UInt32(n), tables[0], tables[1], tables[2])
    }

    func reset() { settings = .neutral }

    // Risoluzione / frequenza
    func loadModes() {
        let opts = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        let all = (CGDisplayCopyAllDisplayModes(selected, opts) as? [CGDisplayMode]) ?? []
        var seen = Set<DisplayMode>()
        modes = all.filter { $0.isUsableForDesktopGUI() }.compactMap { m in
            let d = DisplayMode(width: m.width, height: m.height, refresh: m.refreshRate, hiDPI: m.pixelWidth > m.width, mode: m)
            return seen.insert(d).inserted ? d : nil
        }.sorted { ($0.width, $0.hiDPI ? 1 : 0, $0.refresh) > ($1.width, $1.hiDPI ? 1 : 0, $1.refresh) }
        if let cur = CGDisplayCopyDisplayMode(selected) {
            currentMode = DisplayMode(width: cur.width, height: cur.height, refresh: cur.refreshRate, hiDPI: cur.pixelWidth > cur.width, mode: cur)
        }
    }

    func setMode(_ m: DisplayMode) {
        var cfg: CGDisplayConfigRef?
        CGBeginDisplayConfiguration(&cfg)
        CGConfigureDisplayWithDisplayMode(cfg, selected, m.mode, nil)
        CGCompleteDisplayConfiguration(cfg, .permanently)
        loadModes()
    }

    // DDC
    func probeDDC() {
        DispatchQueue.global().async {
            let av = DDC.externalService()
            let b = av.flatMap { DDC.get($0, 0x10) }
            let c = av.flatMap { DDC.get($0, 0x12) }
            let v = av.flatMap { DDC.get($0, 0x62) }
            DispatchQueue.main.async {
                self.ddcService = av
                self.ddcAvailable = b != nil
                if let b { self.ddcBrightness = Double(b.cur) }
                if let c { self.ddcContrast = Double(c.cur) }
                if let v { self.ddcVolume = Double(v.cur) }
            }
        }
    }

    func ddcSet(_ code: UInt8, _ value: Double) {
        guard let av = ddcService else { return }
        DispatchQueue.global().async { DDC.set(av, code, Int(value)) }
    }

    private func launchctl(_ args: String...) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        try? p.run()
        p.waitUntilExit()
    }

    func toggleLaunchOnConnect() {
        let domain = "gui/\(getuid())"
        if launchOnConnect {
            // "disable" impedisce i prossimi avvii senza chiudere l'app in esecuzione
            launchctl("disable", "\(domain)/\(MonitorModel.agentLabel)")
            try? FileManager.default.removeItem(atPath: MonitorModel.agentPath)
        } else {
            if SMAppService.mainApp.status == .enabled { try? SMAppService.mainApp.unregister() }
            let plist: [String: Any] = [
                "Label": MonitorModel.agentLabel,
                "Program": Bundle.main.executablePath ?? "",
                "LimitLoadToSessionType": "Aqua",
                "RunAtLoad": true,
                "LaunchEvents": ["com.apple.iokit.matching": ["monitor-esterno": [
                    "IOProviderClass": "DCPAVServiceProxy",
                    "IOPropertyMatch": ["Location": "External"],
                    "IOMatchLaunchStream": true,
                ]]],
            ]
            if let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) {
                try? FileManager.default.createDirectory(atPath: (MonitorModel.agentPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                try? data.write(to: URL(fileURLWithPath: MonitorModel.agentPath))
            }
            launchctl("enable", "\(domain)/\(MonitorModel.agentLabel)")
            launchctl("bootstrap", domain, MonitorModel.agentPath)
        }
        launchOnConnect = FileManager.default.fileExists(atPath: MonitorModel.agentPath)
    }
}

// MARK: - Interfaccia

struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var format: (Double) -> String = { "\(Int(($0 * 100).rounded()))%" }
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(format(value)).monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range)
        }
    }
}

struct PanelView: View {
    @ObservedObject var model: MonitorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.screens.count > 1 {
                Picker("Schermo", selection: $model.selected) {
                    ForEach(model.screens) { Text($0.name).tag($0.id) }
                }
            }

            HStack {
                Text("Nome")
                TextField("Nome di sistema", text: Binding(get: { model.customName }, set: { model.customName = $0 }))
                    .textFieldStyle(.roundedBorder)
            }

            GroupBox("Immagine (software)") {
                VStack(spacing: 8) {
                    SliderRow(title: "Luminosità", value: $model.settings.brightness, range: 0.1...1)
                    SliderRow(title: "Contrasto", value: $model.settings.contrast, range: 0.5...1.5)
                    SliderRow(title: "Gamma", value: $model.settings.gamma, range: 0.5...2,
                              format: { String(format: "%.2f", $0) })
                }.padding(4)
            }

            GroupBox("Colore") {
                VStack(spacing: 8) {
                    SliderRow(title: "Temperatura", value: $model.settings.temperature, range: 2700...6500,
                              format: { "\(Int($0)) K" })
                    SliderRow(title: "Rosso", value: $model.settings.red, range: 0.5...1)
                    SliderRow(title: "Verde", value: $model.settings.green, range: 0.5...1)
                    SliderRow(title: "Blu", value: $model.settings.blue, range: 0.5...1)
                }.padding(4)
            }

            GroupBox("Risoluzione") {
                Picker("", selection: Binding(get: { model.currentMode }, set: { if let m = $0 { model.setMode(m) } })) {
                    ForEach(model.modes, id: \.self) { Text($0.label).tag(Optional($0)) }
                }.labelsHidden().padding(4)
            }

            GroupBox("Hardware (DDC/CI)") {
                if model.ddcAvailable {
                    VStack(spacing: 8) {
                        SliderRow(title: "Retroilluminazione", value: $model.ddcBrightness, range: 0...100, format: { "\(Int($0))" })
                            .onChange(of: model.ddcBrightness) { _, v in model.ddcSet(0x10, v) }
                        SliderRow(title: "Contrasto HW", value: $model.ddcContrast, range: 0...100, format: { "\(Int($0))" })
                            .onChange(of: model.ddcContrast) { _, v in model.ddcSet(0x12, v) }
                        SliderRow(title: "Volume", value: $model.ddcVolume, range: 0...100, format: { "\(Int($0))" })
                            .onChange(of: model.ddcVolume) { _, v in model.ddcSet(0x62, v) }
                    }.padding(4)
                } else {
                    HStack {
                        Text("Non disponibile: il monitor non accetta comandi DDC. Nitidezza, saturazione e retroilluminazione si regolano solo dall'OSD.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Button("Riprova") { model.probeDDC() }.controlSize(.small)
                    }.padding(4)
                }
            }

            HStack {
                Button("Ripristina") { model.reset() }
                Spacer()
                Toggle("Avvia quando colleghi un monitor", isOn: Binding(get: { model.launchOnConnect }, set: { _ in model.toggleLaunchOnConnect() }))
                    .toggleStyle(.checkbox)
                Button("Esci") { NSApp.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 340)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        xpc_set_event_stream_handler("com.apple.iokit.matching", DispatchQueue.main) { _ in }
    }
    @MainActor static var model: MonitorModel?
    func applicationWillTerminate(_ notification: Notification) {
        CGDisplayRestoreColorSyncSettings()
    }
}

@main
struct MonitorNativoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model: MonitorModel

    init() {
        let m = MonitorModel()
        AppDelegate.model = m
        _model = StateObject(wrappedValue: m)
    }

    var body: some Scene {
        MenuBarExtra("Gestione Monitor", systemImage: "display") {
            PanelView(model: model)
        }
        .menuBarExtraStyle(.window)
    }
}
