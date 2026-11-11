import AppKit
import ServiceManagement

final class BonfirePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var panel: BonfirePanel!
    private var view: BonfireView!
    private var statusItem: NSStatusItem!
    private var renderer: BonfireRenderer!
    private var model = BurnModel()
    private let tailer = UsageTailer()
    private let queue = DispatchQueue(label: "TokenBonfire.usage", qos: .utility)
    private var polling = false
    private var frameTimer: Timer?
    private var pollTimer: Timer?
    private var lastTick = 0.0
    private var sleeping = false
    private var preview: Int?
    private var thresholdWindow: ThresholdPanel?
    private var shownText = ""
    private var observers: [NSObjectProtocol] = []
    private let defaults = UserDefaults.standard
    // 설정
    private var scale = 1.5
    private var sources = Set(UsageSource.allCases)
    private var showNumber = true

    private static let scaleRange = 0.75...3.0, scaleStep = 0.25
    private var size: NSSize { NSSize(width: (Double(Art.width) * scale).rounded(), height: (Double(Art.height) * scale).rounded()) }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
        if others.contains(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            NSApp.terminate(nil)
            return
        }
        loadSettings()
        do {
            renderer = try BonfireRenderer(atlas: AtlasStore(resources: Bundle.main.resourceURL!))
        } catch {
            let alert = NSAlert()
            alert.messageText = "Token Bonfire 그림을 열지 못했어요"
            alert.informativeText = "빌드 스크립트로 앱을 다시 만들어 주세요. (\(error))"
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        renderer.showNumber = showNumber
        model.thresholds = BurnThresholds.load()
        view = BonfireView(frame: NSRect(origin: .zero, size: size))
        view.menuProvider = { [weak self] in self?.makeMenu() ?? NSMenu() }
        view.onMoveEnded = { [weak self] in self?.keepOnScreen(); self?.savePosition() }
        view.isOpaqueAt = { [weak self] x, y in self?.renderer.isOpaque(x: x, y: y) ?? false }
        panel = BonfirePanel(contentRect: NSRect(origin: initialOrigin(), size: size),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "Token Bonfire"
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = view
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "flame.fill", accessibilityDescription: "Token Bonfire")
        statusItem.button?.imagePosition = .imageLeading
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        keepOnScreen()
        panel.orderFrontRegardless()
        watchScreenState()
        // 시작할 때 있던 기록은 세지 않는다: 첫 훑기에서 파일 끝 위치만 적어 둔다.
        queue.async { [tailer] in _ = tailer.poll() }
        let poller = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.poll() }
        poller.tolerance = 0.3
        RunLoop.main.add(poller, forMode: .common)
        pollTimer = poller
        setAnimating(true)
    }

    private func loadSettings() {
        let saved = defaults.double(forKey: "scaleFactor")
        if Self.scaleRange.contains(saved) { scale = saved }
        if let names = defaults.stringArray(forKey: "sources") { sources = Set(names.compactMap(UsageSource.init(rawValue:))) }
        if defaults.object(forKey: "showNumber") != nil { showNumber = defaults.bool(forKey: "showNumber") }
    }

    // MARK: 집계

    private func poll() {
        guard !polling else { return }
        polling = true
        queue.async { [weak self, tailer] in
            let deltas = tailer.poll()
            DispatchQueue.main.async {
                guard let self else { return }
                self.polling = false
                var tokens = 0
                for (source, delta) in deltas where self.sources.contains(source) {
                    tokens += delta.fresh
                }
                if tokens > 0 {
                    self.model.add(Double(tokens))
                    if self.sleeping { self.model.flush(); self.updateStatus() }
                }
            }
        }
    }

    // MARK: 그리기

    private func setAnimating(_ on: Bool) {
        frameTimer?.invalidate()
        frameTimer = nil
        view.setPointerTracking(on)
        guard on else { return }
        lastTick = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: 1 / Art.fps, repeats: true) { [weak self] _ in self?.tick() }
        timer.tolerance = 0.004
        RunLoop.main.add(timer, forMode: .common)
        frameTimer = timer
        tick()
    }

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        let dt = min(0.1, max(0, now - lastTick))
        lastTick = now
        let released = model.drain(dt)
        model.shown += renderer.step(dt: dt, tier: preview ?? model.tier, released: released)
        updateStatus()
        view.show(renderer.image(number: shownText))
    }

    private func updateStatus() {
        let text = BurnModel.format(model.shown)
        guard text != shownText else { return }
        shownText = text
        statusItem.button?.title = " " + text
        let summary = "태운 토큰 \(text)"
        view.toolTip = summary + "\n드래그로 이동 · 우클릭으로 설정"
        view.setAccessibilityLabel("Token Bonfire · " + summary)
    }

    // MARK: 메뉴

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let fresh = makeMenu()
        for item in fresh.items { fresh.removeItem(item); menu.addItem(item) }
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        func add(_ title: String, _ action: Selector?, to target: NSMenu? = nil, on: Bool = false, tag: Int = 0) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = action == nil ? nil : self
            item.isEnabled = action != nil
            item.state = on ? .on : .off
            item.tag = tag
            (target ?? menu).addItem(item)
        }
        func submenu(_ title: String, _ build: (NSMenu) -> Void) {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let sub = NSMenu()
            build(sub)
            item.submenu = sub
            menu.addItem(item)
        }
        let tier = preview ?? model.tier
        let total = BurnModel.format(model.shown + model.pending + renderer.tokensInFlight)
        add("태운 토큰 \(total) · \(BurnModel.tierNames[tier])" + (preview == nil ? "" : " (미리보기)"), nil)
        if model.rate > 0 { add("지금 분당 약 \(BurnModel.format(model.rate * 60))", nil) }
        menu.addItem(.separator())
        add("초기화", #selector(resetCount))
        menu.addItem(sizeItem())
        submenu("집계 대상") { sub in
            for (index, source) in UsageSource.allCases.enumerated() {
                add(source.title, #selector(toggleSource(_:)), to: sub, on: sources.contains(source), tag: index)
            }
        }
        add("불 기준…", #selector(showThresholds))
        add("숫자 표시", #selector(toggleNumber), on: showNumber)
        add("로그인 시 실행", #selector(toggleLoginItem), on: SMAppService.mainApp.status == .enabled)
        submenu("미리보기") { sub in
            add("자동 · 실제 사용량", #selector(showPreview(_:)), to: sub, on: preview == nil, tag: -1)
            for (index, name) in BurnModel.tierNames.enumerated() {
                add(name, #selector(showPreview(_:)), to: sub, on: preview == index, tag: index)
            }
        }
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Token Bonfire 종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)
        return menu
    }

    @objc private func resetCount() {
        model.reset()
        renderer.clear()
        let now = Date()
        queue.async { [tailer] in tailer.notBefore = now }
        updateStatus()
    }
    /// 메뉴 안의 크기 막대. 0.25배 간격으로 끌면 바로 창 크기가 바뀐다.
    private func sizeItem() -> NSMenuItem {
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 230, height: 30))
        let label = NSTextField(labelWithString: "크기")
        label.font = .menuFont(ofSize: 0)
        label.frame = NSRect(x: 14, y: 6, width: 36, height: 18)
        let steps = Int(((Self.scaleRange.upperBound - Self.scaleRange.lowerBound) / Self.scaleStep).rounded()) + 1
        let slider = NSSlider(value: scale, minValue: Self.scaleRange.lowerBound, maxValue: Self.scaleRange.upperBound,
                              target: self, action: #selector(resize(_:)))
        slider.numberOfTickMarks = steps
        slider.allowsTickMarkValuesOnly = true
        slider.isContinuous = true
        slider.controlSize = .small
        slider.frame = NSRect(x: 54, y: 4, width: 162, height: 22)
        slider.setAccessibilityLabel("크기")
        box.addSubview(label)
        box.addSubview(slider)
        let item = NSMenuItem()
        item.view = box
        return item
    }

    @objc private func resize(_ slider: NSSlider) {
        let next = (slider.doubleValue / Self.scaleStep).rounded() * Self.scaleStep
        guard Self.scaleRange.contains(next), next != scale else { return }
        scale = next
        defaults.set(scale, forKey: "scaleFactor")
        // 장작 바닥 가운데를 그대로 두고 크기만 바꾼다.
        let old = panel.frame
        panel.setFrame(NSRect(x: old.midX - size.width / 2, y: old.minY, width: size.width, height: size.height), display: true)
        keepOnScreen()
        savePosition()
    }
    @objc private func toggleSource(_ item: NSMenuItem) {
        guard UsageSource.allCases.indices.contains(item.tag) else { return }
        let source = UsageSource.allCases[item.tag]
        if sources.contains(source) { sources.remove(source) } else { sources.insert(source) }
        defaults.set(sources.map(\.rawValue).sorted(), forKey: "sources")
    }
    @objc private func showThresholds() {
        if thresholdWindow == nil {
            let window = ThresholdPanel()
            window.onApply = { [weak self] next in
                self?.model.thresholds = next
                next.save()
            }
            thresholdWindow = window
        }
        thresholdWindow?.configure(model.thresholds)
        NSApp.activate(ignoringOtherApps: true)
        thresholdWindow?.makeKeyAndOrderFront(nil)
    }
    @objc private func toggleNumber() {
        showNumber.toggle()
        defaults.set(showNumber, forKey: "showNumber")
        renderer.showNumber = showNumber
    }
    @objc private func toggleLoginItem() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() } else { try SMAppService.mainApp.register() }
        } catch {
            let alert = NSAlert()
            alert.messageText = "로그인 항목을 바꾸지 못했어요"
            alert.informativeText = "\(error.localizedDescription)\n시스템 설정 › 일반 › 로그인 항목에서 직접 바꿀 수 있어요."
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }
    @objc private func showPreview(_ item: NSMenuItem) {
        preview = BurnModel.tierNames.indices.contains(item.tag) ? item.tag : nil
    }

    // MARK: 위치

    private func defaultOrigin() -> NSPoint {
        let area = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        return NSPoint(x: area.maxX - size.width - 24, y: area.minY + 24)
    }
    private func initialOrigin() -> NSPoint {
        guard defaults.object(forKey: "originX") != nil else { return defaultOrigin() }
        return NSPoint(x: defaults.double(forKey: "originX"), y: defaults.double(forKey: "originY"))
    }
    private func savePosition() {
        defaults.set(Double(panel.frame.origin.x), forKey: "originX")
        defaults.set(Double(panel.frame.origin.y), forKey: "originY")
    }
    /// 창 가운데가 어느 화면에도 없으면 기본 자리로 되돌린다.
    private func keepOnScreen() {
        let center = NSPoint(x: panel.frame.midX, y: panel.frame.midY)
        if !NSScreen.screens.contains(where: { $0.frame.contains(center) }) { panel.setFrameOrigin(defaultOrigin()) }
    }

    // MARK: 화면 꺼짐

    private func watchScreenState() {
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.sleeping = true
            self.setAnimating(false)
            self.model.flush()
            self.updateStatus()
        })
        observers.append(center.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.sleeping = false
            self.setAnimating(true)
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.keepOnScreen()
        })
    }
}
