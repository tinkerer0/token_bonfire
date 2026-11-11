import AppKit

/// 합쳐진 한 장을 레이어에 그대로 올린다. 확대는 합성기가 최근접 방식으로 한다.
final class BonfireView: NSView {
    /// 끌지 않고 누르기만 했을 때(우클릭 포함).
    var onClick: (() -> Void)?
    var onMoveEnded: (() -> Void)?
    /// 그림 좌표(왼쪽 위 기준)가 불투명한지. 투명한 곳의 클릭은 아래 창으로 넘긴다.
    var isOpaqueAt: ((Int, Int) -> Bool)?
    private var pointerTimer: Timer?
    private var dragStart: (mouse: NSPoint, origin: NSPoint)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        layer?.contentsGravity = .resize
        layer?.magnificationFilter = .nearest
        layer?.minificationFilter = .nearest
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("Token Bonfire")
    }
    required init?(coder: NSCoder) { nil }

    func show(_ image: CGImage?) { layer?.contents = image }

    func setPointerTracking(_ on: Bool) {
        pointerTimer?.invalidate()
        pointerTimer = nil
        guard on else { return }
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.updateMousePassThrough() }
        timer.tolerance = 0.02
        RunLoop.main.add(timer, forMode: .common)
        pointerTimer = timer
    }

    private func updateMousePassThrough() {
        guard let window, dragStart == nil, let isOpaqueAt, bounds.width > 0 else { return }
        let point = convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        let x = Int(floor((point.x - bounds.minX) * CGFloat(Art.width) / bounds.width))
        let y = Int(floor((bounds.maxY - point.y) * CGFloat(Art.height) / bounds.height))
        let ignore = !isOpaqueAt(x, y)
        if window.ignoresMouseEvents != ignore { window.ignoresMouseEvents = ignore }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        if event.modifierFlags.contains(.control) { rightMouseDown(with: event); return }
        dragStart = (NSEvent.mouseLocation, window.frame.origin)
    }
    override func mouseDragged(with event: NSEvent) {
        guard let window, let start = dragStart else { return }
        let mouse = NSEvent.mouseLocation
        window.setFrameOrigin(NSPoint(x: start.origin.x + mouse.x - start.mouse.x, y: start.origin.y + mouse.y - start.mouse.y))
    }
    override func mouseUp(with event: NSEvent) {
        guard let start = dragStart else { return }
        dragStart = nil
        let mouse = NSEvent.mouseLocation
        if abs(mouse.x - start.mouse.x) < 3, abs(mouse.y - start.mouse.y) < 3 { onClick?() } else { onMoveEnded?() }
    }
    override func rightMouseDown(with event: NSEvent) { onClick?() }
}
