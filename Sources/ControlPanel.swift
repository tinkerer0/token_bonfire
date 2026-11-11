import AppKit

/// 불을 누르면 옆에 뜨는 창. 위쪽에서 목표 양과 시간을 바로 정하고, 나머지는 "설정"을 펼쳐서 바꾼다.
/// 값은 AppDelegate가 들고 있고 여기서는 보여 주고 바뀐 것을 알리기만 한다.
final class ControlPanel: NSPanel, NSTextFieldDelegate {
    struct State {
        var count = "0"
        var status = ""
        var goal: BurnGoal?
        var sources = Set<UsageSource>()
        var scale = 1.5
        var color = FireColor.orange
        var showNumber = true
        var preview: Int?
        var login = false
    }
    var onReset: (() -> Void)?
    /// nil이면 목표를 끈다.
    var onGoal: ((BurnGoal?) -> Void)?
    var onThresholds: (() -> Void)?
    var onSource: ((UsageSource, Bool) -> Void)?
    var onScale: ((Double) -> Void)?
    var onColor: ((FireColor) -> Void)?
    var onNumber: ((Bool) -> Void)?
    var onPreview: ((Int?) -> Void)?
    var onLogin: (() -> Void)?

    private let count = NSTextField(labelWithString: "0")
    private let status = NSTextField(labelWithString: "")
    private let amount = NSTextField(string: "")
    private let units = NSPopUpButton(frame: .zero, pullsDown: false)
    private let timed = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let hours = NSTextField(string: "")
    private let hint = NSTextField(wrappingLabelWithString: "")
    private let off = NSButton(title: "목표 끄기", target: nil, action: nil)
    private let disclosure = NSButton(title: "설정", target: nil, action: nil)
    private let settings = NSStackView()
    private var sourceBoxes: [NSButton] = []
    private let slider: NSSlider
    private let scaleLabel = NSTextField(labelWithString: "")
    private let colors: NSSegmentedControl
    private let number = NSButton(checkboxWithTitle: "숫자 표시", target: nil, action: nil)
    private let preview: NSSegmentedControl
    private let login = NSButton(checkboxWithTitle: "로그인 시 자동 실행", target: nil, action: nil)
    private var anchor = NSRect.zero
    private var filled = false
    private var filledGoal: BurnGoal?
    private static let width: CGFloat = 288

    init(scaleRange: ClosedRange<Double>, scaleStep: Double) {
        slider = NSSlider(value: scaleRange.lowerBound, minValue: scaleRange.lowerBound, maxValue: scaleRange.upperBound, target: nil, action: nil)
        slider.numberOfTickMarks = Int(((scaleRange.upperBound - scaleRange.lowerBound) / scaleStep).rounded()) + 1
        slider.allowsTickMarkValuesOnly = true
        let colorTitles: [String] = FireColor.allCases.map { $0.title }
        colors = NSSegmentedControl(labels: colorTitles, trackingMode: .selectOne, target: nil, action: nil)
        var tierTitles: [String] = ["자동"]
        tierTitles.append(contentsOf: BurnModel.tierNames)
        preview = NSSegmentedControl(labels: tierTitles, trackingMode: .selectOne, target: nil, action: nil)
        super.init(contentRect: NSRect(x: 0, y: 0, width: Self.width + 32, height: 300),
                   styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel], backing: .buffered, defer: false)
        title = "Token Bonfire"
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false

        // 지금 상태
        count.font = .monospacedDigitSystemFont(ofSize: 24, weight: .semibold)
        status.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        status.textColor = .secondaryLabelColor
        stack.addArrangedSubview(count)
        stack.setCustomSpacing(2, after: count)
        stack.addArrangedSubview(status)
        stack.setCustomSpacing(12, after: status)
        stack.addArrangedSubview(separator())

        // 목표: 양과 시간
        stack.addArrangedSubview(heading("목표"))
        amount.alignment = .right
        amount.delegate = self
        amount.setAccessibilityLabel("목표 토큰 양")
        amount.widthAnchor.constraint(equalToConstant: 64).isActive = true
        units.addItems(withTitles: ["K · 천", "M · 백만", "B · 십억"])
        units.target = self
        units.action = #selector(changed)
        units.setAccessibilityLabel("단위")
        stack.addArrangedSubview(row([amount, units, NSTextField(labelWithString: "토큰까지")]))
        hours.alignment = .right
        hours.setAccessibilityLabel("초기화 시간")
        hours.widthAnchor.constraint(equalToConstant: 44).isActive = true
        timed.setAccessibilityLabel("정한 시간마다 집계 초기화")
        stack.addArrangedSubview(row([timed, hours, NSTextField(labelWithString: "시간마다 집계 초기화")], spacing: 6))
        hint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        hint.textColor = .secondaryLabelColor
        hint.widthAnchor.constraint(equalToConstant: Self.width).isActive = true
        stack.addArrangedSubview(hint)
        let apply = push("적용", #selector(applyGoal))
        apply.keyEquivalent = "\r"
        off.bezelStyle = .rounded
        off.target = self
        off.action = #selector(turnOff)
        let goalButtons = row([apply, off, flexible(), push("집계 초기화", #selector(tapReset))])
        stack.addArrangedSubview(goalButtons)
        goalButtons.widthAnchor.constraint(equalToConstant: Self.width).isActive = true
        stack.setCustomSpacing(12, after: goalButtons)
        stack.addArrangedSubview(separator())

        // 설정: 접어 둔다
        disclosure.setButtonType(.pushOnPushOff)
        disclosure.bezelStyle = .disclosure
        disclosure.title = ""
        disclosure.target = self
        disclosure.action = #selector(toggleSettings)
        disclosure.setAccessibilityLabel("설정 펼치기")
        let settingsTitle = NSButton(title: "설정", target: self, action: #selector(tapSettingsTitle))
        settingsTitle.isBordered = false
        settingsTitle.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        stack.addArrangedSubview(row([disclosure, settingsTitle], spacing: 4))

        settings.orientation = .vertical
        settings.alignment = .leading
        settings.spacing = 8
        var sourceRow: [NSView] = [caption("집계 대상")]
        for (index, source) in UsageSource.allCases.enumerated() {
            let box = NSButton(checkboxWithTitle: source.title, target: self, action: #selector(tapSource(_:)))
            box.tag = index
            sourceBoxes.append(box)
            sourceRow.append(box)
        }
        settings.addArrangedSubview(row(sourceRow, spacing: 12))
        slider.target = self
        slider.action = #selector(slide)
        slider.controlSize = .small
        slider.widthAnchor.constraint(equalToConstant: 150).isActive = true
        slider.setAccessibilityLabel("크기")
        scaleLabel.textColor = .secondaryLabelColor
        settings.addArrangedSubview(row([caption("크기"), slider, scaleLabel]))
        colors.target = self
        colors.action = #selector(tapColor)
        colors.controlSize = .small
        colors.setAccessibilityLabel("불 색")
        settings.addArrangedSubview(row([caption("불 색"), colors]))
        number.target = self
        number.action = #selector(tapNumber)
        settings.addArrangedSubview(row([caption("숫자"), number]))
        preview.target = self
        preview.action = #selector(tapPreview)
        preview.controlSize = .small
        preview.setAccessibilityLabel("불 단계 미리보기")
        settings.addArrangedSubview(row([caption("미리보기"), preview]))
        settings.addArrangedSubview(row([caption("불 단계"), push("단계 기준 바꾸기…", #selector(tapThresholds))]))
        login.target = self
        login.action = #selector(tapLogin)
        let quit = NSButton(title: "종료", target: NSApp, action: #selector(NSApplication.terminate(_:)))
        quit.bezelStyle = .rounded
        let last = row([login, flexible(), quit])
        settings.addArrangedSubview(last)
        last.widthAnchor.constraint(equalToConstant: Self.width).isActive = true
        settings.isHidden = true
        stack.addArrangedSubview(settings)

        contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView!.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: contentView!.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: contentView!.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: contentView!.bottomAnchor, constant: -16),
        ])
        fit()
    }

    override var canBecomeKey: Bool { true }

    // MARK: 조립 도구

    private func row(_ views: [NSView], spacing: CGFloat = 8) -> NSStackView {
        let row = NSStackView(views: views)
        row.alignment = .centerY
        row.spacing = spacing
        return row
    }
    private func caption(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.textColor = .secondaryLabelColor
        label.widthAnchor.constraint(equalToConstant: 56).isActive = true
        return label
    }
    private func heading(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        return label
    }
    private func separator() -> NSBox {
        let line = NSBox()
        line.boxType = .separator
        line.widthAnchor.constraint(equalToConstant: Self.width).isActive = true
        return line
    }
    private func push(_ title: String, _ action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        return button
    }
    private func flexible() -> NSView {
        let view = NSView()
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return view
    }
    private func fit() {
        contentView?.layoutSubtreeIfNeeded()
        if let size = contentView?.fittingSize { setContentSize(size) }
    }

    // MARK: 표시

    func update(_ state: State) {
        count.stringValue = state.count
        status.stringValue = state.status
        // 입력 중인 값을 덮어쓰지 않게, 목표가 실제로 바뀌었을 때만 칸을 다시 채운다.
        if !filled || filledGoal != state.goal {
            filled = true
            filledGoal = state.goal
            let parts = BurnGoal.split(state.goal?.target ?? BurnGoal.suggested)
            amount.stringValue = BurnGoal.hoursText(parts.number)
            units.selectItem(at: parts.unit)
            timed.state = (state.goal == nil || state.goal?.hours != nil) ? .on : .off
            hours.stringValue = BurnGoal.hoursText(state.goal?.hours ?? BurnGoal.suggestedHours)
            off.isEnabled = state.goal != nil
            changed()
        }
        for (box, source) in zip(sourceBoxes, UsageSource.allCases) { box.state = state.sources.contains(source) ? .on : .off }
        if slider.doubleValue != state.scale { slider.doubleValue = state.scale }
        scaleLabel.stringValue = BurnGoal.hoursText(state.scale) + "배"
        colors.selectedSegment = FireColor.allCases.firstIndex(of: state.color) ?? 0
        number.state = state.showNumber ? .on : .off
        preview.selectedSegment = state.preview.map { $0 + 1 } ?? 0
        login.state = state.login ? .on : .off
    }

    /// 불 창 옆(자리가 없으면 반대쪽)에 붙여 연다.
    func show(beside anchor: NSRect) {
        self.anchor = anchor
        let screen = NSScreen.screens.first { $0.frame.intersects(anchor) } ?? NSScreen.main
        let area = screen?.visibleFrame ?? anchor
        var x = anchor.maxX + 8
        if x + frame.width > area.maxX { x = anchor.minX - 8 - frame.width }
        x = max(area.minX, min(x, area.maxX - frame.width))
        let y = max(area.minY, min(anchor.minY, area.maxY - frame.height))
        setFrameOrigin(NSPoint(x: x, y: y))
        orderFrontRegardless()
    }

    // MARK: 목표

    private var entered: Double? {
        let text = amount.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Double(text), value > 0, BurnGoal.units.indices.contains(units.indexOfSelectedItem) else { return nil }
        return value * BurnGoal.units[units.indexOfSelectedItem].scale
    }
    @objc private func changed() {
        hint.textColor = .secondaryLabelColor
        if let entered { hint.stringValue = BurnGoal.share(of: entered) + " (어림)" } else { hint.stringValue = "" }
    }
    func controlTextDidChange(_ notification: Notification) { changed() }
    private func warn(_ text: String) {
        hint.textColor = .systemRed
        hint.stringValue = text
    }
    @objc private func applyGoal() {
        var period: Double?
        if timed.state == .on {
            let text = hours.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let value = Double(text), BurnGoal.hoursRange.contains(value) else { warn("시간은 1부터 168 사이로 입력해 주세요."); return }
            period = value
        }
        guard let target = entered, let goal = BurnGoal(target: target, hours: period) else { warn("1K 이상의 수를 입력해 주세요."); return }
        makeFirstResponder(nil)
        onGoal?(goal)
    }
    @objc private func turnOff() {
        makeFirstResponder(nil)
        onGoal?(nil)
    }

    // MARK: 설정

    @objc private func tapSettingsTitle() {
        disclosure.state = disclosure.state == .on ? .off : .on
        toggleSettings()
    }
    func expandSettings() {
        disclosure.state = .on
        toggleSettings()
    }
    @objc private func toggleSettings() {
        settings.isHidden = disclosure.state != .on
        fit()
        if isVisible { show(beside: anchor) }
    }
    @objc private func tapReset() { onReset?() }
    @objc private func tapThresholds() { onThresholds?() }
    @objc private func tapSource(_ box: NSButton) {
        guard UsageSource.allCases.indices.contains(box.tag) else { return }
        onSource?(UsageSource.allCases[box.tag], box.state == .on)
    }
    @objc private func slide() { onScale?(slider.doubleValue) }
    @objc private func tapColor() {
        guard FireColor.allCases.indices.contains(colors.selectedSegment) else { return }
        onColor?(FireColor.allCases[colors.selectedSegment])
    }
    @objc private func tapNumber() { onNumber?(number.state == .on) }
    @objc private func tapPreview() { onPreview?(preview.selectedSegment > 0 ? preview.selectedSegment - 1 : nil) }
    @objc private func tapLogin() { onLogin?() }
}
