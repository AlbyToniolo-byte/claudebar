import AppKit
import ServiceManagement

// ClaudeBar: lo stato di Claude Code nella Touch Bar.
// Lo stesso eseguibile fa due lavori:
//  - `ClaudeBar --hook` lo lancia Claude Code a ogni evento (hook in ~/.claude/settings.json): scrive un file e esce;
//  - `ClaudeBar` normale vive nella Control Strip e legge quei file.
// Niente server né porte: i file in Application Support sono l'unico canale tra i due.

let bundleID = "local.claudebar"
let dataDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("ClaudeBar")
let sessionsDir = dataDir.appendingPathComponent("sessions") // <session_id>.json: stato di ogni sessione
let asksDir = dataDir.appendingPathComponent("asks") // <uuid>.json: permesso in attesa; <uuid>.answer: risposta dalla barra
let maxWait = 120.0 // secondi che l'hook aspetta la Touch Bar, poi lascia decidere il dialogo normale

enum State: String { case working, waiting, done }

// MARK: - Logica pura (provata da --selftest)

/// Lo stato che scrive un evento degli hook; nil = l'evento non cambia niente.
func state(for event: [String: Any]) -> State? {
    switch event["hook_event_name"] as? String {
    case "UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure": return .working
    case "Notification": // gli altri tipi (es. idle_prompt dopo un minuto fermo) non dicono niente di nuovo dopo Stop
        return ["permission_prompt", "elicitation_dialog"].contains(event["notification_type"] as? String) ? .waiting : nil
    case "Stop", "StopFailure": return .done
    default: return nil
    }
}

/// "Bash: npm test", "Edit: /percorso/file.swift"…: cosa sta per fare lo strumento, abbastanza corto per la barra.
func detail(of event: [String: Any]) -> String {
    let tool = event["tool_name"] as? String ?? ""
    let input = event["tool_input"] as? [String: Any] ?? [:]
    let arg = ["command", "file_path", "url", "pattern", "description", "prompt"].lazy.compactMap { input[$0] as? String }.first ?? ""
    let text = (arg.isEmpty ? tool : "\(tool): \(arg)").replacingOccurrences(of: "\n", with: " ")
    return text.count > 90 ? text.prefix(89) + "…" : text
}

/// L'uscita JSON che Claude Code legge per un PermissionRequest; nil = nessuna decisione (si apre il dialogo normale).
func decision(_ answer: String) -> String? {
    let d: [String: Any]
    switch answer {
    case "allow": d = ["behavior": "allow"]
    case "deny": d = ["behavior": "deny", "message": "Negato dalla Touch Bar"]
    default: return nil
    }
    let out = ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": d]]
    return String(decoding: try! JSONSerialization.data(withJSONObject: out), as: UTF8.self)
}

/// Il session_id diventa un nome di file: tengo solo caratteri sicuri.
func safeName(_ s: String) -> String { String(s.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }.prefix(80)) }

func readJSON(_ url: URL) -> [String: Any]? { (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } }
// .atomic = scrivo su un file temporaneo e poi lo rinomino: chi legge non vede mai un file a metà
func writeJSON(_ obj: [String: Any], to url: URL) { try? JSONSerialization.data(withJSONObject: obj).write(to: url, options: .atomic) }
func modified(_ url: URL) -> Date? { (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date }

// MARK: - Modalità hook (la lancia Claude Code)

func runHook() -> Never {
    let input = FileHandle.standardInput.readDataToEndOfFile()
    // qualunque problema: esco con 0 e senza output, così Claude Code va avanti come se l'hook non ci fosse
    guard let ev = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any],
          let sid = (ev["session_id"] as? String).map(safeName), !sid.isEmpty else { exit(0) }
    let fm = FileManager.default
    try? fm.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
    try? fm.createDirectory(at: asksDir, withIntermediateDirectories: true)
    let sessionFile = sessionsDir.appendingPathComponent(sid + ".json")
    let project = URL(fileURLWithPath: ev["cwd"] as? String ?? "/").lastPathComponent

    switch ev["hook_event_name"] as? String {
    case "SessionEnd":
        try? fm.removeItem(at: sessionFile)
    case "PermissionRequest":
        // app spenta: nessuno risponderebbe, quindi non aspetto
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty else { break }
        let id = UUID().uuidString
        let ask = asksDir.appendingPathComponent(id + ".json"), answer = asksDir.appendingPathComponent(id + ".answer")
        // il pid serve all'app: se Claude Code uccide questo hook (Esc, chiusura), la richiesta sparisce dalla barra
        writeJSON(["session": sid, "project": project, "detail": detail(of: ev), "time": Date().timeIntervalSince1970, "pid": Int(getpid())], to: ask)
        defer { try? fm.removeItem(at: ask); try? fm.removeItem(at: answer) }
        let before = modified(sessionFile), deadline = Date() + maxWait
        while Date() < deadline {
            if let a = try? String(contentsOf: answer, encoding: .utf8) {
                if let out = decision(a) { print(out) } // "skip" (tasto Terminale) = nessuna decisione
                break
            }
            // un altro evento della stessa sessione = si è già risposto altrove (terminale/app): smetto di aspettare
            if modified(sessionFile) != before { break }
            usleep(100_000)
        }
    default:
        if let s = state(for: ev) {
            writeJSON(["state": s.rawValue, "project": project, "detail": detail(of: ev), "time": Date().timeIntervalSince1970], to: sessionFile)
        }
    }
    exit(0)
}

// MARK: - Lettura dei file (lato app)

struct Session { let state: State, project: String, time: Double }
struct Ask { let id: String, project: String, detail: String, time: Double }

func loadSessions() -> [Session] {
    let files = (try? FileManager.default.contentsOfDirectory(at: sessionsDir, includingPropertiesForKeys: nil)) ?? []
    let now = Date().timeIntervalSince1970
    return files.compactMap { url -> Session? in
        guard url.pathExtension == "json", let j = readJSON(url), let s = (j["state"] as? String).flatMap(State.init),
              let t = j["time"] as? Double else { return nil }
        // shortcut: una sessione chiusa male (senza SessionEnd) sparisce dopo 12 ore; se serve, aggiungere un tasto "pulisci"
        guard now - t < 12 * 3600 else { return nil }
        return Session(state: s, project: j["project"] as? String ?? "?", time: t)
    }.sorted { $0.time > $1.time }
}

func loadAsks() -> [Ask] {
    let files = (try? FileManager.default.contentsOfDirectory(at: asksDir, includingPropertiesForKeys: nil)) ?? []
    return files.compactMap { url -> Ask? in
        guard url.pathExtension == "json", let j = readJSON(url), let pid = j["pid"] as? Int else { return nil }
        if kill(pid_t(pid), 0) != 0, errno == ESRCH { // hook morto (Esc, chiusura): richiesta scaduta, la butto
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return Ask(id: url.deletingPathExtension().lastPathComponent, project: j["project"] as? String ?? "?",
                   detail: j["detail"] as? String ?? "", time: j["time"] as? Double ?? 0)
    }.sorted { $0.time < $1.time } // la più vecchia per prima
}

// MARK: - Disegno

enum Look { case none, working, waiting, done }
let claudeOrange = NSColor(srgbRed: 0.85, green: 0.47, blue: 0.34, alpha: 1)

/// Il simbolo dello stato: anello grigio (niente), arco arancione che gira (lavora), "!" giallo che pulsa (aspetta), spunta verde (finito).
func drawGlyph(_ look: Look, in r: NSRect, phase: Double) {
    let c = NSPoint(x: r.midX, y: r.midY), rad = min(r.width, r.height) / 2
    let circle = NSRect(x: c.x - rad, y: c.y - rad, width: 2 * rad, height: 2 * rad)
    switch look {
    case .none:
        let p = NSBezierPath(ovalIn: circle.insetBy(dx: rad * 0.2, dy: rad * 0.2))
        p.lineWidth = rad * 0.18
        NSColor.systemGray.setStroke(); p.stroke()
    case .working:
        let p = NSBezierPath(), start = CGFloat(-phase * 360)
        p.appendArc(withCenter: c, radius: rad * 0.75, startAngle: start, endAngle: start + 270)
        p.lineWidth = rad * 0.3; p.lineCapStyle = .round
        claudeOrange.setStroke(); p.stroke()
    case .waiting:
        NSColor.systemYellow.withAlphaComponent(0.55 + 0.45 * abs(cos(phase * .pi))).setFill()
        NSBezierPath(ovalIn: circle).fill()
        NSColor.black.setFill()
        NSBezierPath(roundedRect: NSRect(x: c.x - rad * 0.12, y: c.y - rad * 0.2, width: rad * 0.24, height: rad * 0.75), xRadius: rad * 0.12, yRadius: rad * 0.12).fill()
        NSBezierPath(ovalIn: NSRect(x: c.x - rad * 0.13, y: c.y - rad * 0.63, width: rad * 0.26, height: rad * 0.26)).fill()
    case .done:
        NSColor.systemGreen.setFill(); NSBezierPath(ovalIn: circle).fill()
        let p = NSBezierPath()
        p.move(to: NSPoint(x: c.x - rad * 0.45, y: c.y + rad * 0.02))
        p.line(to: NSPoint(x: c.x - rad * 0.12, y: c.y - rad * 0.32))
        p.line(to: NSPoint(x: c.x + rad * 0.45, y: c.y + rad * 0.35))
        p.lineWidth = rad * 0.2; p.lineCapStyle = .round; p.lineJoinStyle = .round
        NSColor.white.setStroke(); p.stroke()
    }
}

final class GlyphView: NSView {
    var look = Look.none, phase = 0.0
    var onTap: (() -> Void)?
    override func touchesBegan(with event: NSEvent) { onTap?() }
    override func mouseDown(with event: NSEvent) { onTap?() }
    override init(frame: NSRect) { super.init(frame: frame); allowedTouchTypes = [.direct] }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) { drawGlyph(look, in: bounds.insetBy(dx: 4, dy: 6), phase: phase) }
}

/// Mette il disegno su un tasto vero: così la Control Strip gli dà lo stesso sfondo grigio dei tasti di sistema
/// (una vista semplice resta sul grigio più scuro della striscia). I tocchi restano alla vista.
func systemKey(_ view: NSView) -> NSButton {
    let key = NSButton(title: "", target: nil, action: nil)
    view.translatesAutoresizingMaskIntoConstraints = false
    key.addSubview(view)
    NSLayoutConstraint.activate([
        key.widthAnchor.constraint(equalToConstant: 54), // larghezza dei tasti di sistema (luminosità, volume…)
        view.leadingAnchor.constraint(equalTo: key.leadingAnchor), view.trailingAnchor.constraint(equalTo: key.trailingAnchor),
        view.topAnchor.constraint(equalTo: key.topAnchor), view.bottomAnchor.constraint(equalTo: key.bottomAnchor),
    ])
    return key
}

/// L'icona dell'app: i tre stati su un quadrato scuro.
func renderIcon(to path: String) {
    let size = 1024
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSColor(white: 0.12, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 185, yRadius: 185).fill()
    for (i, look) in [Look.working, .waiting, .done].enumerated() {
        drawGlyph(look, in: NSRect(x: 160 + i * 240, y: 400, width: 224, height: 224), phase: i == 0 ? 0.1 : 0)
    }
    NSGraphicsContext.current = nil
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

// MARK: - App

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    let trayID = NSTouchBarItem.Identifier("local.claudebar.tray")
    let bar = NSTouchBar()
    let tray = GlyphView()
    let barArea = NSView()
    let row = NSStackView()
    lazy var visibleWidth = row.widthAnchor.constraint(equalToConstant: 600)
    var sessions: [Session] = [], asks: [Ask] = []
    var shownAsk: String?, signature = "", autoExpanded = false, lastLoad = 0.0

    func applicationDidFinishLaunching(_ note: Notification) {
        // 1. il simbolo sempre visibile nella Control Strip: toccarlo apre la barra con le sessioni
        let item = NSCustomTouchBarItem(identifier: trayID)
        item.view = systemKey(tray)
        tray.onTap = { [unowned self] in expand() }
        NSTouchBarItem.addSystemTrayItem(item)
        DFRElementSetControlStripPresenceForIdentifier(trayID, true)

        // 2. la barra espansa: un solo elemento largo quanto la Touch Bar, con la riga stretta alla parte visibile
        // (stesso trucco di TouchPet: il sistema non restringe gli elementi e quello che sporge resta nascosto)
        row.translatesAutoresizingMaskIntoConstraints = false
        barArea.addSubview(row)
        NSLayoutConstraint.activate([
            barArea.widthAnchor.constraint(equalToConstant: 1085),
            row.leadingAnchor.constraint(equalTo: barArea.leadingAnchor),
            row.topAnchor.constraint(equalTo: barArea.topAnchor),
            row.bottomAnchor.constraint(equalTo: barArea.bottomAnchor),
            visibleWidth,
        ])
        let area = NSCustomTouchBarItem(identifier: .init("area"))
        area.view = barArea
        bar.templateItems = [area]
        bar.defaultItemIdentifiers = [area.identifier]
        if UserDefaults.standard.bool(forKey: "expand") { expand() } // `-expand YES`: parte già espansa (per le prove)

        // all'accesso deve ripartire da sola, altrimenti gli hook non trovano nessuno; lo chiedo a macOS una volta sola
        if Bundle.main.bundlePath.hasPrefix("/Applications/"), !UserDefaults.standard.bool(forKey: "loginSet") {
            try? SMAppService.mainApp.register()
            UserDefaults.standard.set(true, forKey: "loginSet")
        }

        Timer.scheduledTimer(withTimeInterval: 1.0 / 20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func expand() {
        DFRSystemModalShowsCloseBoxWhenFrontMost(true)
        NSTouchBar.presentSystemModalTouchBar(bar, systemTrayItemIdentifier: trayID)
    }

    func tick() {
        let now = CACurrentMediaTime()
        if now - lastLoad >= 0.2 { // i file: 5 volte al secondo bastano, sono pochi e piccoli
            lastLoad = now
            sessions = loadSessions()
            asks = loadAsks()
            update()
        }
        let visible = barArea.visibleRect.width
        if visible > 0, visible != visibleWidth.constant { visibleWidth.constant = visible }
        // si ridisegna solo quando si muove: arco che gira o "!" che pulsa
        if tray.look == .working || tray.look == .waiting {
            tray.phase = now.truncatingRemainder(dividingBy: 1)
            tray.needsDisplay = true
        }
    }

    func update() {
        // il simbolo mostra la cosa più urgente fra tutte le sessioni
        let look: Look = !asks.isEmpty || sessions.contains { $0.state == .waiting } ? .waiting
            : sessions.contains { $0.state == .working } ? .working
            : sessions.isEmpty ? .none : .done
        if look != tray.look { tray.look = look; tray.needsDisplay = true }

        // una nuova richiesta di permesso apre la barra da sola; quando non ce ne sono più la richiude
        let first = asks.first?.id
        if let first, first != shownAsk { expand(); autoExpanded = true }
        if first == nil, autoExpanded { NSTouchBar.minimizeSystemModalTouchBar(bar); autoExpanded = false }
        shownAsk = first

        let sig = "\(first ?? "")|\(asks.count)|" + sessions.prefix(4).map { "\($0.project):\($0.state)" }.joined(separator: ",")
        if sig != signature { signature = sig; rebuild() }
    }

    func rebuild() {
        var views: [NSView]
        if let a = asks.first {
            let what = label(a.detail, .white)
            what.setContentCompressionResistancePriority(.defaultLow, for: .horizontal) // il testo lungo si accorcia, i tasti no
            views = [label("\(a.project)\(asks.count > 1 ? " (+\(asks.count - 1))" : "")", .systemYellow), what,
                     button("Approva", .systemGreen, 0), button("Nega", .systemRed, 1), button("Terminale", nil, 2)]
        } else if sessions.isEmpty {
            views = [label("Nessuna sessione di Claude Code", .systemGray)]
        } else {
            views = sessions.prefix(4).map { s in
                let (word, color): (String, NSColor) = switch s.state {
                case .working: ("lavora", claudeOrange)
                case .waiting: ("aspetta te", .systemYellow)
                case .done: ("finito", .systemGreen)
                }
                return label("● \(s.project): \(word)", color)
            }
        }
        let spacer = NSView() // spinge "Esci" in fondo a destra
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        views += [spacer, button("Esci", nil, 3)]
        row.setViews(views, in: .leading)
        row.spacing = 12
    }

    func label(_ text: String, _ color: NSColor) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.textColor = color
        l.lineBreakMode = .byTruncatingTail
        return l
    }

    func button(_ title: String, _ color: NSColor?, _ tag: Int) -> NSButton {
        let b = NSButton(title: title, target: self, action: #selector(answer(_:)))
        b.bezelColor = color
        b.tag = tag
        return b
    }

    @objc func answer(_ sender: NSButton) {
        guard sender.tag != 3 else { return NSApp.terminate(nil) }
        guard let id = asks.first?.id else { return }
        // l'hook in attesa legge questo file entro un decimo di secondo e risponde a Claude Code
        try? ["allow", "deny", "skip"][sender.tag].write(to: asksDir.appendingPathComponent(id + ".answer"), atomically: true, encoding: .utf8)
    }
}

MainActor.assumeIsolated {
    let args = CommandLine.arguments
    if args.contains("--hook") { runHook() }
    if args.contains("--selftest") {
        assert(state(for: ["hook_event_name": "PreToolUse"]) == .working)
        assert(state(for: ["hook_event_name": "Stop"]) == .done)
        assert(state(for: ["hook_event_name": "Notification", "notification_type": "permission_prompt"]) == .waiting)
        assert(state(for: ["hook_event_name": "Notification", "notification_type": "idle_prompt"]) == nil)
        assert(state(for: ["hook_event_name": "SessionStart"]) == nil)
        assert(detail(of: ["tool_name": "Bash", "tool_input": ["command": "ls\n-la"]]) == "Bash: ls -la")
        assert(detail(of: ["tool_name": "WebSearch", "tool_input": [:]]) == "WebSearch")
        assert(detail(of: ["tool_name": "Bash", "tool_input": ["command": String(repeating: "x", count: 200)]]).count == 90)
        assert(safeName("../../etc/passwd") == "etcpasswd" && safeName("ab-12_c") == "ab-12_c")
        // la decisione riletta come JSON ha la forma che chiede Claude Code
        let out = try! JSONSerialization.jsonObject(with: Data(decision("deny")!.utf8)) as! [String: Any]
        let hso = out["hookSpecificOutput"] as! [String: Any], d = hso["decision"] as! [String: Any]
        assert(hso["hookEventName"] as? String == "PermissionRequest" && d["behavior"] as? String == "deny")
        assert(decision("skip") == nil && decision("allow")!.contains("\"allow\""))
        print("selftest ok")
        exit(0)
    }
    if let i = args.firstIndex(of: "--icon"), i + 1 < args.count { renderIcon(to: args[i + 1]); exit(0) }

    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory) // niente icona nel Dock: vive nella Touch Bar
    app.run()
}
