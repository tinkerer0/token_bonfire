import AppKit

/// 목표 토큰 양을 정하는 창.
final class GoalPanel: NSPanel, NSTextFieldDelegate {
    /// nil이면 목표를 끈다.
    var onApply: ((BurnGoal?) -> Void)?
    private let field = NSTextField(string: "")
    private let units = NSPopUpButton(frame: .zero, pullsDown: false)
    private let daily = NSButton(checkboxWithTitle: "날짜가 바뀌면 0부터 다시 세기", target: nil, action: nil)
    private let share = NSTextField(wrappingLabelWithString: "")
    private let message = NSTextField(wrappingLabelWithString: "")
    private let off = NSButton(title: "목표 끄기", target: nil, action: nil)

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 360, height: 250),
                   styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false)
        title = "목표"
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        level = .floating
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(NSTextField(labelWithString: "이만큼만 쓰겠다는 토큰 양을 정해요."))
        field.alignment = .right
        field.delegate = self
        field.setAccessibilityLabel("목표 토큰 양")
        field.widthAnchor.constraint(equalToConstant: 72).isActive = true
        units.addItems(withTitles: ["K · 천", "M · 백만", "B · 십억"])
        units.target = self
        units.action = #selector(changed)
        units.setAccessibilityLabel("단위")
        let row = NSStackView(views: [field, units, NSTextField(labelWithString: "토큰")])
        row.alignment = .centerY
        row.spacing = 8
        stack.addArrangedSubview(row)
        for label in [share, message] {
            label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            label.textColor = .secondaryLabelColor
            label.widthAnchor.constraint(equalToConstant: 320).isActive = true
        }
        stack.addArrangedSubview(share)
        stack.addArrangedSubview(daily)
        stack.addArrangedSubview(message)
        let apply = NSButton(title: "적용", target: self, action: #selector(applySettings))
        apply.bezelStyle = .rounded
        apply.keyEquivalent = "\r"
        off.bezelStyle = .rounded
        off.target = self
        off.action = #selector(turnOff)
        let buttons = NSStackView(views: [apply, off])
        buttons.spacing = 8
        stack.addArrangedSubview(buttons)
        contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView!.leadingAnchor, constant: 20),
            stack.topAnchor.constraint(equalTo: contentView!.topAnchor, constant: 20),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: contentView!.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: contentView!.bottomAnchor, constant: -20),
        ])
        configure(nil)
        center()
    }

    override var canBecomeKey: Bool { true }

    private static let hint = "숫자 칸이 현재/목표로 바뀌어요. 다 채우면 숫자가 금색이 되고 알림이 한 번 와요."

    func configure(_ goal: BurnGoal?) {
        let parts = BurnGoal.split(goal?.target ?? BurnGoal.suggested)
        field.stringValue = parts.number == parts.number.rounded() ? String(Int(parts.number)) : String(parts.number)
        units.selectItem(at: parts.unit)
        daily.state = (goal?.daily ?? true) ? .on : .off
        off.isEnabled = goal != nil
        message.stringValue = Self.hint
        changed()
    }
    private var entered: Double? {
        guard let number = Double(field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)), number > 0,
              BurnGoal.units.indices.contains(units.indexOfSelectedItem) else { return nil }
        return number * BurnGoal.units[units.indexOfSelectedItem].scale
    }
    @objc private func changed() {
        share.stringValue = entered.map { BurnGoal.share(of: $0) + " (사용 기록으로 잰 어림, 요금제마다 달라요)" } ?? ""
    }
    func controlTextDidChange(_ notification: Notification) { changed() }
    @objc private func applySettings() {
        makeFirstResponder(nil)
        guard let target = entered, let goal = BurnGoal(target: target, daily: daily.state == .on) else {
            message.stringValue = "1K 이상의 수를 입력해 주세요."
            return
        }
        onApply?(goal)
        off.isEnabled = true
        message.stringValue = "저장했습니다. \(BurnGoal.compact(goal.target))까지 셉니다."
    }
    @objc private func turnOff() {
        onApply?(nil)
        configure(nil)
        message.stringValue = "목표를 껐습니다."
    }
}
