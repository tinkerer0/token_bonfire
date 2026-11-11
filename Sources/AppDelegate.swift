import AppKit
import ServiceManagement
import UserNotifications

final class BonfirePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, UNUserNotificationCenterDelegate {
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
    private var goalWindow: GoalPanel?
    private var controls: ControlPanel?
    private var goal: BurnGoal?
    private var goalReached = false
    private var goalReachedAt: Double?
    private var savedCount = -1.0
    private var goalStart = Date()
    private static let blinkSeconds = 6.0
    private var observers: [NSObjectProtocol] = []
    private let defaults = UserDefaults.standard
    // 설정
    private var scale = 1.5
    private var sources = Set(UsageSource.allCases)
    private var showNumber = true
    private var fireColor = FireColor.orange

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
        renderer.atlas.color = fireColor
        renderer.showNumber = showNumber
        model.thresholds = BurnThresholds.load()
        restoreGoalCount()
        UNUserNotificationCenter.current().delegate = self
        view = BonfireView(frame: NSRect(origin: .zero, size: size))
        view.onClick = { [weak self] in self?.toggleControls() }
        view.onMoveEnded = { [weak self] in
            guard let self else { return }
            self.keepOnScreen()
            self.savePosition()
            if self.controls?.isVisible == true { self.controls?.show(beside: self.panel.frame) }
        }
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

    func applicationWillTerminate(_ notification: Notification) { if renderer != nil { saveGoalCount() } }

    private func loadSettings() {
        let saved = defaults.double(forKey: "scaleFactor")
        if Self.scaleRange.contains(saved) { scale = saved }
        if let names = defaults.stringArray(forKey: "sources") { sources = Set(names.compactMap(UsageSource.init(rawValue:))) }
        fireColor = FireColor(rawValue: defaults.string(forKey: "fireColor") ?? "") ?? .orange
        if defaults.object(forKey: "showNumber") != nil { showNumber = defaults.bool(forKey: "showNumber") }
        var hours: Double? = BurnGoal.suggestedHours
        if defaults.object(forKey: "goalHours") != nil {
            let saved = defaults.double(forKey: "goalHours")
            hours = saved > 0 ? saved : nil
        } else if defaults.object(forKey: "goalDaily") != nil, !defaults.bool(forKey: "goalDaily") {
            hours = nil
        }
        goal = BurnGoal(target: defaults.double(forKey: "goalTokens"), hours: hours)
    }

    // MARK: 목표

    /// 목표가 켜져 있으면 앱을 껐다 켜도 정한 시간 안에서는 숫자를 이어 간다(꺼져 있던 동안 쓴 양은 빠진다).
    private func restoreGoalCount() {
        guard let goal else { return }
        let start = defaults.double(forKey: "goalStart")
        let saved = defaults.double(forKey: "goalCount")
        if start > 0, !goal.expired(start: Date(timeIntervalSince1970: start)) {
            goalStart = Date(timeIntervalSince1970: start)
            if saved > 0 { model.shown = saved }
        } else {
            goalStart = Date()
            defaults.set(goalStart.timeIntervalSince1970, forKey: "goalStart")
        }
        goalReached = goal.reached(model.shown)
    }
    private func saveGoalCount() {
        guard goal != nil else { return }
        let count = model.shown + model.pending + renderer.tokensInFlight
        guard count != savedCount else { return }
        savedCount = count
        defaults.set(count, forKey: "goalCount")
    }
    /// 정한 시간이 다 지났으면 0부터 다시 센다.
    private func checkPeriod() {
        if goal?.expired(start: goalStart) == true { resetCount() }
    }
    /// "3시간 12분 남음". 시간을 정하지 않았으면 nil.
    private var remainingText: String? {
        guard let hours = goal?.hours else { return nil }
        let minutes = max(0, Int((hours * 3600 - Date().timeIntervalSince(goalStart)) / 60))
        return minutes >= 60 ? "\(minutes / 60)시간 \(minutes % 60)분" : "\(minutes)분"
    }
    private func checkGoal() {
        guard let goal, !goalReached, goal.reached(model.shown) else { return }
        goalReached = true
        goalReachedAt = ProcessInfo.processInfo.systemUptime
        let content = UNMutableNotificationContent()
        content.title = "목표 \(BurnGoal.compact(goal.target)) 토큰을 다 썼어요"
        content.body = "정한 양을 채웠습니다."
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "goal", content: content, trigger: nil))
        // 알림 권한이 꺼져 있어도 알 수 있게 소리를 낸다.
        NSSound(named: "Glass")?.play()
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
    @objc private func showGoal() {
        if goalWindow == nil {
            let window = GoalPanel()
            window.onApply = { [weak self] next in self?.applyGoal(next) }
            goalWindow = window
        }
        goalWindow?.configure(goal)
        NSApp.activate(ignoringOtherApps: true)
        goalWindow?.makeKeyAndOrderFront(nil)
    }
    private func applyGoal(_ next: BurnGoal?) {
        let wasOff = goal == nil
        goal = next
        defaults.set(next?.target ?? 0, forKey: "goalTokens")
        if let next {
            defaults.set(next.hours ?? 0, forKey: "goalHours")
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
            // 목표를 새로 켜면 0부터 센다. 켜 둔 채 양만 바꾸면 이어 센다.
            if wasOff { resetCount() } else { goalReached = next.reached(model.shown); goalReachedAt = nil }
        } else {
            goalReached = false
            goalReachedAt = nil
            defaults.removeObject(forKey: "goalCount")
        }
        shownText = ""
        updateStatus()
        refreshControls()
    }

    // MARK: 불 옆 설정 창

    private func toggleControls() {
        if let controls, controls.isVisible { controls.orderOut(nil); return }
        if controls == nil {
            let window = ControlPanel(scaleRange: Self.scaleRange, scaleStep: Self.scaleStep)
            window.onReset = { [weak self] in self?.resetCount() }
            window.onGoal = { [weak self] next in self?.applyGoal(next) }
            window.onThresholds = { [weak self] in self?.showThresholds() }
            window.onSource = { [weak self] source, on in self?.setSource(source, on: on) }
            window.onScale = { [weak self] value in self?.setScale(value) }
            window.onColor = { [weak self] color in self?.setColor(color) }
            window.onNumber = { [weak self] on in if self?.showNumber != on { self?.toggleNumber() } }
            window.onPreview = { [weak self] tier in self?.preview = tier; self?.refreshControls() }
            window.onLogin = { [weak self] in self?.toggleLoginItem(); self?.refreshControls() }
            controls = window
        }
        refreshControls(force: true)
        controls?.show(beside: panel.frame)
    }
    private func refreshControls(force: Bool = false) {
        guard let controls, force || controls.isVisible else { return }
        let tier = preview ?? model.tier
        var parts = ["불 단계 \(BurnModel.tierNames[tier])" + (preview == nil ? "" : " (미리보기)")]
        if model.rate > 0 { parts.append("분당 약 \(BurnModel.format(model.rate * 60))") }
        if let remainingText { parts.append("초기화까지 \(remainingText)") }
        var state = ControlPanel.State()
        state.count = goal?.text(shown: model.shown) ?? BurnModel.format(model.shown)
        state.status = parts.joined(separator: " · ")
        state.goal = goal
        state.sources = sources
        state.scale = scale
        state.color = fireColor
        state.showNumber = showNumber
        state.preview = preview
        state.login = SMAppService.mainApp.status == .enabled
        controls.update(state)
    }

    // MARK: 집계

    private func poll() {
        checkPeriod()
        refreshControls()
        saveGoalCount()
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
        // 목표를 채운 직후 몇 초는 불이 가장 크게 타고, 숫자는 목표를 넘긴 동안 계속 깜빡인다.
        var hidden = false, flare: Int?
        if goalReached {
            let since = goalReachedAt.map { now - $0 } ?? Self.blinkSeconds + now
            hidden = BurnGoal.blinkHidden(since: since, burst: Self.blinkSeconds)
            if since < Self.blinkSeconds { flare = 4 }
        }
        model.shown += renderer.step(dt: dt, tier: preview ?? flare ?? model.tier, released: released)
        updateStatus()
        view.show(renderer.image(number: hidden ? "" : shownText, gold: goalReached))
    }

    private func updateStatus() {
        checkGoal()
        let text = goal?.text(shown: model.shown) ?? BurnModel.format(model.shown)
        guard text != shownText else { return }
        shownText = text
        statusItem.button?.title = " " + text
        let summary = "태운 토큰 \(text)"
        view.toolTip = summary + "\n드래그로 이동 · 클릭으로 설정"
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
        func section(_ title: String) {
            menu.addItem(.separator())
            if #available(macOS 14.0, *) { menu.addItem(.sectionHeader(title: title)) } else { add(title, nil) }
        }
        let tier = preview ?? model.tier
        let total = BurnModel.format(model.shown + model.pending + renderer.tokensInFlight)
        let against = goal.map { " / " + BurnGoal.compact($0.target) + (goalReached ? " (다 씀)" : "") } ?? ""
        add("태운 토큰 \(total)\(against)", nil)
        var state = "불 단계 \(BurnModel.tierNames[tier])" + (preview == nil ? "" : " (미리보기)")
        if model.rate > 0 { state += " · 분당 약 \(BurnModel.format(model.rate * 60))" }
        add(state, nil)
        if let remainingText { add("자동 초기화까지 \(remainingText)", nil) }

        section("집계")
        if let goal {
            let period = goal.hours.map { " · \(BurnGoal.hoursText($0))시간마다" } ?? ""
            add("목표 수정… (\(BurnGoal.compact(goal.target))\(period))", #selector(showGoal))
        } else {
            add("목표 설정…", #selector(showGoal))
        }
        add("집계 초기화", #selector(resetCount))
        let counted = UsageSource.allCases.filter { sources.contains($0) }.map(\.title).joined(separator: " · ")
        submenu("집계 대상 (" + (counted.isEmpty ? "없음" : counted) + ")") { sub in
            for (index, source) in UsageSource.allCases.enumerated() {
                add(source.title, #selector(toggleSource(_:)), to: sub, on: sources.contains(source), tag: index)
            }
        }

        section("모양")
        menu.addItem(sizeItem())
        submenu("불 색 (\(fireColor.title))") { sub in
            for (index, color) in FireColor.allCases.enumerated() {
                add(color.title, #selector(pickColor(_:)), to: sub, on: fireColor == color, tag: index)
            }
        }
        add("숫자 표시", #selector(toggleNumber), on: showNumber)
        add("불 단계 기준…", #selector(showThresholds))
        submenu("불 단계 미리보기") { sub in
            add("자동 · 실제 사용량", #selector(showPreview(_:)), to: sub, on: preview == nil, tag: -1)
            for (index, name) in BurnModel.tierNames.enumerated() {
                add(name, #selector(showPreview(_:)), to: sub, on: preview == index, tag: index)
            }
        }

        section("앱")
        add("로그인 시 자동 실행", #selector(toggleLoginItem), on: SMAppService.mainApp.status == .enabled)
        let quit = NSMenuItem(title: "Token Bonfire 종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)
        return menu
    }

    @objc private func pickColor(_ sender: NSMenuItem) {
        guard FireColor.allCases.indices.contains(sender.tag) else { return }
        setColor(FireColor.allCases[sender.tag])
    }
    private func setColor(_ color: FireColor) {
        fireColor = color
        defaults.set(fireColor.rawValue, forKey: "fireColor")
        renderer.atlas.color = fireColor
        refreshControls()
    }

    @objc private func resetCount() {
        model.reset()
        renderer.clear()
        let now = Date()
        queue.async { [tailer] in tailer.notBefore = now }
        goalReached = false
        goalReachedAt = nil
        goalStart = Date()
        if goal != nil { defaults.set(goalStart.timeIntervalSince1970, forKey: "goalStart") }
        saveGoalCount()
        updateStatus()
        refreshControls()
    }
    /// 메뉴 안의 크기 막대. 0.25배 간격으로 끌면 바로 창 크기가 바뀐다.
    private func sizeItem() -> NSMenuItem {
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 230, height: 30))
        let label = NSTextField(labelWithString: "크기")
        label.font = .menuFont(ofSize: 0)
        label.frame = NSRect(x: 21, y: 6, width: 36, height: 18)
        let steps = Int(((Self.scaleRange.upperBound - Self.scaleRange.lowerBound) / Self.scaleStep).rounded()) + 1
        let slider = NSSlider(value: scale, minValue: Self.scaleRange.lowerBound, maxValue: Self.scaleRange.upperBound,
                              target: self, action: #selector(resize(_:)))
        slider.numberOfTickMarks = steps
        slider.allowsTickMarkValuesOnly = true
        slider.isContinuous = true
        slider.controlSize = .small
        slider.frame = NSRect(x: 60, y: 4, width: 156, height: 22)
        slider.setAccessibilityLabel("크기")
        box.addSubview(label)
        box.addSubview(slider)
        let item = NSMenuItem()
        item.view = box
        return item
    }

    @objc private func resize(_ slider: NSSlider) { setScale(slider.doubleValue) }
    private func setScale(_ value: Double) {
        let next = (value / Self.scaleStep).rounded() * Self.scaleStep
        guard Self.scaleRange.contains(next), next != scale else { return }
        scale = next
        defaults.set(scale, forKey: "scaleFactor")
        // 장작 바닥 가운데를 그대로 두고 크기만 바꾼다.
        let old = panel.frame
        panel.setFrame(NSRect(x: old.midX - size.width / 2, y: old.minY, width: size.width, height: size.height), display: true)
        keepOnScreen()
        savePosition()
        if controls?.isVisible == true { controls?.show(beside: panel.frame) }
        refreshControls()
    }
    @objc private func toggleSource(_ item: NSMenuItem) {
        guard UsageSource.allCases.indices.contains(item.tag) else { return }
        let source = UsageSource.allCases[item.tag]
        setSource(source, on: !sources.contains(source))
    }
    private func setSource(_ source: UsageSource, on: Bool) {
        if on { sources.insert(source) } else { sources.remove(source) }
        defaults.set(sources.map(\.rawValue).sorted(), forKey: "sources")
        refreshControls()
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
        refreshControls()
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
        refreshControls()
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
