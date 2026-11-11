import AppKit

/// 중·강·폭주 단계가 시작되는 분당 토큰 수를 고치는 창.
final class ThresholdPanel: NSPanel, NSTextFieldDelegate {
    var onApply: ((BurnThresholds) -> Void)?
    private let presets = NSPopUpButton(frame: .zero, pullsDown: false)
    private var fields: [NSTextField] = []
    private var steppers: [NSStepper] = []
    private static let hint = "에이전트 하나가 일하는 동안 분당 4천쯤 씁니다. 같은 수이면 더 큰 불이 됩니다."
    private let message = NSTextField(wrappingLabelWithString: ThresholdPanel.hint)

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 360, height: 300),
                   styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false)
        title = "불 기준"
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        level = .floating
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(NSTextField(labelWithString: "각 단계가 시작되는 분당 토큰 수를 정해요."))
        presets.addItems(withTitles: ["에이전트 한두 개", "에이전트 여러 개 · 기본", "에이전트 열 개 넘게", "직접 설정"])
        presets.target = self
        presets.action = #selector(selectPreset(_:))
        presets.setAccessibilityLabel("불 기준 프리셋")
        stack.addArrangedSubview(presets)
        for (index, name) in BurnThresholds.titles.enumerated() {
            let label = NSTextField(labelWithString: name)
            label.widthAnchor.constraint(equalToConstant: 50).isActive = true
            let prefix = NSTextField(labelWithString: "분당")
            let field = NSTextField(string: "")
            field.tag = index
            field.alignment = .right
            field.delegate = self
            field.setAccessibilityLabel(name + " 시작 분당 천 토큰")
            field.widthAnchor.constraint(equalToConstant: 56).isActive = true
            fields.append(field)
            let stepper = NSStepper()
            stepper.tag = index
            stepper.minValue = Double(BurnThresholds.range.lowerBound)
            stepper.maxValue = Double(BurnThresholds.range.upperBound)
            stepper.increment = 1
            stepper.valueWraps = false
            stepper.target = self
            stepper.action = #selector(step(_:))
            stepper.setAccessibilityLabel(name + " 기준 조절")
            steppers.append(stepper)
            let row = NSStackView(views: [label, prefix, field, stepper, NSTextField(labelWithString: "천 토큰부터")])
            row.alignment = .centerY
            row.spacing = 8
            stack.addArrangedSubview(row)
        }
        message.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        message.textColor = .secondaryLabelColor
        message.widthAnchor.constraint(equalToConstant: 320).isActive = true
        stack.addArrangedSubview(message)
        let low = NSTextField(labelWithString: "그보다 적게 쓰는 동안은 약, 안 쓰면 대기예요.")
        low.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        low.textColor = .secondaryLabelColor
        stack.addArrangedSubview(low)
        let apply = NSButton(title: "적용", target: self, action: #selector(applySettings))
        apply.bezelStyle = .rounded
        apply.keyEquivalent = "\r"
        stack.addArrangedSubview(apply)
        contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView!.leadingAnchor, constant: 20),
            stack.topAnchor.constraint(equalTo: contentView!.topAnchor, constant: 20),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: contentView!.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: contentView!.bottomAnchor, constant: -20),
        ])
        configure(.standard)
        center()
    }

    override var canBecomeKey: Bool { true }

    func configure(_ thresholds: BurnThresholds) {
        for (index, value) in thresholds.perMinuteThousands.enumerated() {
            fields[index].integerValue = value
            steppers[index].integerValue = value
        }
        presets.selectItem(at: BurnThresholds.presets.firstIndex(of: thresholds) ?? BurnThresholds.presets.count)
        message.stringValue = Self.hint
    }
    @objc private func selectPreset(_ sender: NSPopUpButton) {
        guard BurnThresholds.presets.indices.contains(sender.indexOfSelectedItem) else { return }
        makeFirstResponder(nil)
        configure(BurnThresholds.presets[sender.indexOfSelectedItem])
    }
    @objc private func step(_ sender: NSStepper) {
        makeFirstResponder(nil)
        fields[sender.tag].integerValue = sender.integerValue
        presets.selectItem(at: BurnThresholds.presets.count)
        message.stringValue = Self.hint
    }
    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField, fields.indices.contains(field.tag) else { return }
        if let value = Int(field.stringValue), BurnThresholds.range.contains(value) { steppers[field.tag].integerValue = value }
        presets.selectItem(at: BurnThresholds.presets.count)
    }
    @objc private func applySettings() {
        makeFirstResponder(nil)
        let values = fields.compactMap { Int($0.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)) }
        guard values.count == fields.count, values.allSatisfy({ BurnThresholds.range.contains($0) }) else {
            message.stringValue = "1~9999 사이의 정수를 입력해 주세요."
            return
        }
        guard let thresholds = BurnThresholds(perMinuteThousands: values) else {
            message.stringValue = "위에서 아래로 같거나 큰 수를 입력해 주세요."
            return
        }
        onApply?(thresholds)
        configure(thresholds)
        message.stringValue = "저장했습니다. 바로 적용됩니다."
    }
}
