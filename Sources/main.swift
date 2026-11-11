import AppKit
import UniformTypeIdentifiers

let arguments = Array(CommandLine.arguments.dropFirst())

func value(after flag: String) -> String? {
    guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
    return arguments[index + 1]
}

func resourcesURL() -> URL {
    value(after: "--resources").map { URL(fileURLWithPath: $0) } ?? Bundle.main.resourceURL ?? URL(fileURLWithPath: ".")
}

if arguments.contains("--scan") {
    // 실제 세션 기록을 몇 초 지켜보고 그 사이 잡힌 사용량을 출력한다. 화면은 띄우지 않는다.
    let seconds = Double(value(after: "--scan") ?? "") ?? 10
    let tailer = UsageTailer()
    _ = tailer.poll()
    var totals: [UsageSource: UsageDelta] = [:]
    let end = Date().addingTimeInterval(seconds)
    while Date() < end {
        Thread.sleep(forTimeInterval: 2)
        for (source, delta) in tailer.poll() { totals[source] = (totals[source] ?? .zero) + delta }
    }
    let report: [String: Any] = [
        "seconds": seconds, "trackedFiles": tailer.trackedFiles,
        "claude": ["fresh": totals[.claude]?.fresh ?? 0, "cached": totals[.claude]?.cached ?? 0],
        "codex": ["fresh": totals[.codex]?.fresh ?? 0, "cached": totals[.codex]?.cached ?? 0],
    ]
    let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
    print(String(decoding: data, as: UTF8.self))
} else if let output = value(after: "--render") {
    // 화면 없이 몇 초를 돌린 뒤 마지막 장을 2배 PNG로 저장한다: --render out.png --tier 3 --seconds 4 [--tokens 50000]
    let tier = min(4, max(0, Int(value(after: "--tier") ?? "") ?? 2))
    let seconds = Double(value(after: "--seconds") ?? "") ?? 4
    let renderer = try BonfireRenderer(atlas: AtlasStore(resources: resourcesURL()))
    renderer.atlas.color = FireColor(rawValue: value(after: "--color") ?? "") ?? .orange
    var model = BurnModel()
    let tokens = Double(value(after: "--tokens") ?? "")
    if let tokens { model.add(tokens) }
    var elapsed = 0.0
    while elapsed < seconds {
        let dt = 1 / Art.fps
        let released = model.drain(dt)
        model.shown += renderer.step(dt: dt, tier: tokens == nil ? tier : model.tier, released: released)
        elapsed += dt
    }
    // --goal N: 숫자를 현재/목표로 그린다.
    let goal = BurnGoal(target: Double(value(after: "--goal") ?? "") ?? 0, hours: nil)
    guard let image = renderer.image(number: goal?.text(shown: model.shown) ?? BurnModel.format(model.shown),
                                     gold: goal?.reached(model.shown) ?? false),
          let context = CGContext(data: nil, width: Art.width * 2, height: Art.height * 2, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: Art.space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { exit(1) }
    context.setFillColor(CGColor(red: 0.043, green: 0.043, blue: 0.051, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: Art.width * 2, height: Art.height * 2))
    context.interpolationQuality = .none
    context.draw(image, in: CGRect(x: 0, y: 0, width: Art.width * 2, height: Art.height * 2))
    guard let scaled = context.makeImage(),
          let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: output) as CFURL, UTType.png.identifier as CFString, 1, nil) else { exit(1) }
    CGImageDestinationAddImage(destination, scaled, nil)
    guard CGImageDestinationFinalize(destination) else { exit(1) }
    print("tier \(tokens == nil ? tier : model.tier) fireLevel \(renderer.fireLevel) coins \(renderer.coins.count) shown \(BurnModel.format(model.shown))")
} else if let folder = value(after: "--demo") {
    // 대기부터 폭주까지 단계마다 몇 초씩 돌려 낱장 PNG로 저장한다: --demo <폴더> [--seconds 2] [--zoom 3] [--english]
    let names = arguments.contains("--english") ? ["Idle", "Low", "Medium", "High", "Max"] : BurnModel.tierNames
    let perTier = Double(value(after: "--seconds") ?? "") ?? 2
    let zoom = min(6, max(1, Int(value(after: "--zoom") ?? "") ?? 3))
    let renderer = try BonfireRenderer(atlas: AtlasStore(resources: resourcesURL()))
    try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
    let width = Art.width * zoom, height = Art.height * zoom
    guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: Art.space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { exit(1) }
    context.interpolationQuality = .none
    let burnPerSecond: [Double] = [0, 60, 250, 700, 2000]
    var shown = 0.0, index = 0
    for tier in 0..<BurnModel.tierNames.count {
        for _ in 0..<Int(perTier * Art.fps) {
            let dt = 1 / Art.fps
            shown += renderer.step(dt: dt, tier: tier, released: burnPerSecond[tier] * dt)
            guard let image = renderer.image(number: BurnModel.format(shown)) else { exit(1) }
            context.setFillColor(CGColor(red: 0.043, green: 0.043, blue: 0.051, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            let label = NSAttributedString(string: names[tier], attributes: [
                .font: NSFont.systemFont(ofSize: CGFloat(7 * zoom), weight: .semibold),
                .foregroundColor: NSColor(white: 1, alpha: 0.72),
            ])
            label.draw(at: NSPoint(x: CGFloat(8 * zoom), y: CGFloat(height) - CGFloat(16 * zoom)))
            NSGraphicsContext.restoreGraphicsState()
            let url = URL(fileURLWithPath: folder).appendingPathComponent(String(format: "frame-%04d.png", index))
            guard let frame = context.makeImage(),
                  let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { exit(1) }
            CGImageDestinationAddImage(destination, frame, nil)
            guard CGImageDestinationFinalize(destination) else { exit(1) }
            index += 1
        }
    }
    print("frames \(index) size \(width)x\(height)")
} else if let folder = value(after: "--tour") {
    // 목표와 불 색을 차례로 보여 주는 낱장 PNG를 저장한다: --tour <폴더> [--zoom 6] [--english]
    let english = arguments.contains("--english")
    let zoom = min(6, max(1, Int(value(after: "--zoom") ?? "") ?? 6))
    let renderer = try BonfireRenderer(atlas: AtlasStore(resources: resourcesURL()))
    try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
    let width = Art.width * zoom, height = Art.height * zoom
    guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: Art.space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { exit(1) }
    context.interpolationQuality = .none
    var index = 0
    let dt = 1 / Art.fps
    func save(number: String, gold: Bool, title: String, detail: String) {
        guard let image = renderer.image(number: number, gold: gold) else { exit(1) }
        context.setFillColor(CGColor(red: 0.043, green: 0.043, blue: 0.051, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: CGFloat(8 * zoom), weight: .semibold),
            .foregroundColor: NSColor(white: 1, alpha: 0.9),
        ]).draw(at: NSPoint(x: CGFloat(8 * zoom), y: CGFloat(height) - CGFloat(17 * zoom)))
        NSAttributedString(string: detail, attributes: [
            .font: NSFont.systemFont(ofSize: CGFloat(5.5 * Double(zoom)), weight: .regular),
            .foregroundColor: NSColor(white: 1, alpha: 0.6),
        ]).draw(at: NSPoint(x: CGFloat(8 * zoom), y: CGFloat(height) - CGFloat(26 * zoom)))
        NSGraphicsContext.restoreGraphicsState()
        let url = URL(fileURLWithPath: folder).appendingPathComponent(String(format: "frame-%04d.png", index))
        guard let frame = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { exit(1) }
        CGImageDestinationAddImage(destination, frame, nil)
        guard CGImageDestinationFinalize(destination) else { exit(1) }
        index += 1
    }
    // 1) 목표: 현재/목표로 세다가 채운다
    let goal = BurnGoal(target: 5_000_000, hours: nil)!
    var shown = 4_550_000.0, frames = 0
    while !goal.reached(shown), frames < Int(8 * Art.fps) {
        shown += renderer.step(dt: dt, tier: 3, released: 110_000 * dt)
        save(number: goal.text(shown: min(shown, 4_999_999)), gold: false,
             title: english ? "Set a token goal" : "토큰 목표 설정",
             detail: english ? "The number reads current / goal" : "숫자가 현재 / 목표로 표시됩니다")
        frames += 1
    }
    shown = max(shown, goal.target)
    // 2) 달성: 불이 크게 타고 숫자가 깜빡인 뒤 금색
    for frame in 0..<Int(5.5 * Art.fps) {
        let time = Double(frame) * dt
        shown += renderer.step(dt: dt, tier: 4, released: 30_000 * dt)
        let hidden = BurnGoal.blinkHidden(since: time, burst: 2.5)
        save(number: hidden ? "" : goal.text(shown: shown), gold: true,
             title: english ? "Goal reached" : "목표 달성",
             detail: english ? "The fire flares, the number blinks in gold" : "불이 타오르고 숫자가 금색으로 깜빡입니다")
    }
    // 3) 불 색
    renderer.clear()
    shown = 128_400
    let colorNames: [FireColor: String] = [.orange: "Orange", .blue: "Blue", .green: "Green", .purple: "Purple"]
    for color in [FireColor.blue, .green, .purple, .orange] {
        renderer.atlas.color = color
        for _ in 0..<Int(1.8 * Art.fps) {
            shown += renderer.step(dt: dt, tier: 2, released: 600 * dt)
            save(number: BurnModel.format(shown), gold: false,
                 title: english ? "Fire color" : "불 색 선택",
                 detail: english ? colorNames[color]! : color.title)
        }
    }
    print("frames \(index) size \(width)x\(height)")
} else {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
