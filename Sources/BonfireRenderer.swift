import CoreGraphics
import Foundation
import ImageIO

struct BonfireError: Error, CustomStringConvertible {
    let description: String
    init(_ text: String) { description = text }
}

/// 구운 그림의 규격. 값은 Resources/manifest.json(굽기 도구가 씀)과 같아야 한다.
enum Art {
    static let width = 160, height = 180, originX = 80.0, originY = 148.0
    static let fps = 30.0, frames = 90, levels = 11
    static let tierLevels: [Double] = [0, 2, 4, 6, 8]
    static let coinsPerSecond: [Double] = [0, 1, 3, 7, 16]
    static let coinSpread: [Double] = [14, 16, 18, 22, 26]
    static let coinSize = 16, coinFrames = 24
    static let coinStartY = -162.0, coinStartJitter = 30.0, coinLandY = -9.0, gravity = 320.0
    static let glyphWidth = 7, glyphHeight = 9, numberTop = 156
    static let flareBoost = 2.0
    static let space = CGColorSpace(name: CGColorSpace.sRGB)!
}

private func decode(_ url: URL, width: Int, height: Int) throws -> CGImage {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
          image.width == width, image.height == height,
          let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: Art.space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        throw BonfireError("그림을 열 수 없음: \(url.lastPathComponent)")
    }
    context.interpolationQuality = .none
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    guard let decoded = context.makeImage() else { throw BonfireError("그림을 풀 수 없음: \(url.lastPathComponent)") }
    return decoded
}

/// 구운 시트를 읽어 낱장을 내준다. 불 시트는 한 장이 풀면 10MB라 최근에 쓴 몇 단계만 들고 있는다.
final class AtlasStore {
    private struct Manifest: Decodable {
        struct Number: Decodable {
            struct Glyph: Decodable { let index: Int; let advance: Int }
            let glyphs: [String: Glyph]
        }
        let number: Number
    }
    private let resources: URL
    private var fire: [Int: CGImage] = [:]
    private var recent: [Int] = []
    private let keep: Int
    private let coins: [CGImage]
    private let glyphs: [Character: (image: CGImage, advance: Int)]
    private let goalGlyphs: [Character: CGImage]

    init(resources: URL, keep: Int = 4) throws {
        self.resources = resources
        self.keep = keep
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: resources.appendingPathComponent("manifest.json")))
        let coinSheet = try decode(resources.appendingPathComponent("coin-atlas.png"), width: Art.coinSize * Art.coinFrames, height: Art.coinSize)
        coins = try (0..<Art.coinFrames).map { index in
            guard let image = coinSheet.cropping(to: CGRect(x: index * Art.coinSize, y: 0, width: Art.coinSize, height: Art.coinSize)) else {
                throw BonfireError("동전 그림 오류")
            }
            return image
        }
        let count = manifest.number.glyphs.count
        let digitSheet = try decode(resources.appendingPathComponent("digits-atlas.png"), width: Art.glyphWidth * count, height: Art.glyphHeight)
        let goalSheet = try decode(resources.appendingPathComponent("digits-goal-atlas.png"), width: Art.glyphWidth * count, height: Art.glyphHeight)
        var table: [Character: (image: CGImage, advance: Int)] = [:]
        var goalTable: [Character: CGImage] = [:]
        for (text, glyph) in manifest.number.glyphs {
            guard let character = text.first, (0..<count).contains(glyph.index),
                  let image = digitSheet.cropping(to: CGRect(x: glyph.index * Art.glyphWidth, y: 0, width: Art.glyphWidth, height: Art.glyphHeight)) else {
                throw BonfireError("숫자 그림 오류")
            }
            table[character] = (image, glyph.advance)
            goalTable[character] = goalSheet.cropping(to: CGRect(x: glyph.index * Art.glyphWidth, y: 0, width: Art.glyphWidth, height: Art.glyphHeight))
        }
        glyphs = table
        goalGlyphs = goalTable
        _ = try fireSheet(0)
    }

    private func fireSheet(_ level: Int) throws -> CGImage {
        if let sheet = fire[level] {
            if recent.last != level { recent.removeAll { $0 == level }; recent.append(level) }
            return sheet
        }
        let name = String(format: "fire-%02d-atlas.png", level)
        let sheet = try decode(resources.appendingPathComponent(name), width: Art.width * Art.frames, height: Art.height)
        fire[level] = sheet
        recent.append(level)
        while recent.count > keep { fire[recent.removeFirst()] = nil }
        return sheet
    }

    func fireFrame(level: Int, frame: Int) -> CGImage? {
        (try? fireSheet(level))?.cropping(to: CGRect(x: frame * Art.width, y: 0, width: Art.width, height: Art.height))
    }
    func coin(_ index: Int) -> CGImage { coins[index] }
    /// gold: 목표를 채운 뒤에 쓰는 금색 글자.
    func glyph(_ character: Character, gold: Bool = false) -> (image: CGImage, advance: Int)? {
        guard let plain = glyphs[character] else { return nil }
        return gold ? goalGlyphs[character].map { ($0, plain.advance) } : plain
    }
    var loadedFireLevels: Int { fire.count }
}

/// 불·동전·숫자를 160x180 한 장으로 합친다. 동전의 낙하와 불 단계의 오르내림도 여기서 계산한다.
final class BonfireRenderer {
    struct Coin { var x, y, vy, angle, spin, tokens: Double }

    let atlas: AtlasStore
    var showNumber = true
    var random: () -> Double = { Double.random(in: 0..<1) }
    private(set) var coins: [Coin] = []
    private(set) var time = 0.0
    private(set) var level = 0.0
    private(set) var flare = 0.0
    private var coinDebt = 0.0
    private var bank = 0.0
    private let context: CGContext

    init(atlas: AtlasStore) throws {
        self.atlas = atlas
        guard let context = CGContext(data: nil, width: Art.width, height: Art.height, bitsPerComponent: 8,
                                      bytesPerRow: Art.width * 4, space: Art.space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw BonfireError("그리기 판을 만들 수 없음")
        }
        context.interpolationQuality = .none
        self.context = context
    }

    /// 지금 보여 줄 불 단계(0...10).
    var fireLevel: Int { min(Art.levels - 1, max(0, Int((level + Art.flareBoost * flare).rounded()))) }
    /// 아직 불에 들어가지 않은 동전과 대기분이 들고 있는 토큰.
    var tokensInFlight: Double { bank + coins.reduce(0) { $0 + $1.tokens } }

    private func spawn(tier: Int, tokens: Double) {
        coins.append(Coin(x: (random() - 0.5) * Art.coinSpread[tier], y: Art.coinStartY - random() * Art.coinStartJitter,
                          vy: 30 + random() * 40, angle: random() * 2 * .pi, spin: 7 + random() * 5, tokens: tokens))
    }

    /// dt초 진행한다. released: 이 사이 풀려 나온 토큰(동전에 실린다). 돌려주는 값은 불에 들어간 토큰.
    func step(dt: Double, tier: Int, released: Double) -> Double {
        time += dt
        bank += released
        let rate = Art.coinsPerSecond[tier]
        coinDebt += rate * dt * (0.5 + random())
        while coinDebt >= 1 {
            coinDebt -= 1
            spawn(tier: tier, tokens: bank)
            bank = 0
        }
        // 동전이 안 떨어지는 단계에 남은 몫이 있으면 마지막 동전 하나에 싣는다.
        if rate == 0, bank > 0 { spawn(tier: 1, tokens: bank); bank = 0 }
        var landed = 0.0
        for index in coins.indices {
            coins[index].vy += Art.gravity * dt
            coins[index].y += coins[index].vy * dt
            coins[index].angle += coins[index].spin * dt
            if coins[index].y >= Art.coinLandY {
                landed += coins[index].tokens
                flare = min(1, flare + 0.5)
            }
        }
        coins.removeAll { $0.y >= Art.coinLandY }
        flare *= exp(-4 * dt)
        level += (Art.tierLevels[tier] - level) * min(1, dt * 4)
        return landed
    }

    /// 떠 있는 동전과 대기분을 버린다(초기화).
    func clear() { coins.removeAll(); bank = 0; coinDebt = 0 }

    /// 그림 좌표(왼쪽 위 기준)를 CoreGraphics 좌표(왼쪽 아래 기준)로 옮겨 그린다.
    private func draw(_ image: CGImage, x: Int, y: Int) {
        context.draw(image, in: CGRect(x: x, y: Art.height - y - image.height, width: image.width, height: image.height))
    }

    func image(number: String, gold: Bool = false) -> CGImage? {
        context.clear(CGRect(x: 0, y: 0, width: Art.width, height: Art.height))
        let frame = Int(time * Art.fps) % Art.frames
        if let fire = atlas.fireFrame(level: fireLevel, frame: frame) { draw(fire, x: 0, y: 0) }
        let half = Double(Art.coinSize) / 2
        for coin in coins {
            let turn = coin.angle.truncatingRemainder(dividingBy: 2 * .pi) / (2 * .pi)
            let index = min(Art.coinFrames - 1, Int(turn * Double(Art.coinFrames)))
            draw(atlas.coin(index), x: Int((Art.originX + coin.x - half).rounded()), y: Int((Art.originY + coin.y - half).rounded()))
        }
        if showNumber {
            let parts = number.compactMap { atlas.glyph($0, gold: gold) }
            let width = parts.reduce(0) { $0 + $1.advance } - 1
            var x = Int((Art.originX - Double(width) / 2).rounded()) - 1
            for part in parts { draw(part.image, x: x, y: Art.numberTop); x += part.advance }
        }
        return context.makeImage()
    }

    /// 방금 그린 장에서 (x, y)(왼쪽 위 기준)가 불투명한지. 옅은 빛 번짐은 통과시킨다.
    func isOpaque(x: Int, y: Int) -> Bool {
        guard (0..<Art.width).contains(x), (0..<Art.height).contains(y), let data = context.data else { return false }
        return data.load(fromByteOffset: y * context.bytesPerRow + x * 4 + 3, as: UInt8.self) > 110
    }
}
