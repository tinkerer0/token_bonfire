import Foundation

/// 들어온 토큰을 한꺼번에 태우지 않고 몇 초에 걸쳐 풀어낸다. 풀려 나가는 속도가 불 단계를 정한다.
struct BurnModel {
    static let tierNames = ["대기", "약", "중", "강", "폭주"]
    /// 한 번에 들어온 양이 대략 이 시간에 걸쳐 탄다.
    static let drainSeconds = 15.0
    /// 단계가 시작되는 속도(초당 토큰). 분당 8천·2.5만·7만.
    static let tierRates: [Double] = [0, 0, 8000.0 / 60, 25000.0 / 60, 70000.0 / 60]
    /// 남은 양이 적을 때의 최소 속도. 끝자락이 한없이 늘어지지 않게 한다.
    static let floorRate = 15.0

    private(set) var pending = 0.0
    /// 화면 숫자. 동전이 불에 들어갈 때 오른다.
    var shown = 0.0

    mutating func add(_ tokens: Double) { pending += max(0, tokens) }
    /// 지금 타고 있는 속도(초당 토큰).
    var rate: Double { pending <= 0 ? 0 : max(pending / Self.drainSeconds, Self.floorRate) }
    var tier: Int {
        let value = rate
        guard value > 0 else { return 0 }
        var tier = 1
        for index in 2..<Self.tierRates.count where value >= Self.tierRates[index] { tier = index }
        return tier
    }
    /// dt초 동안 풀려 나간 토큰.
    mutating func drain(_ dt: Double) -> Double {
        let out = min(pending, rate * dt)
        pending -= out
        return out
    }
    /// 남은 양을 연출 없이 숫자에 바로 더한다(화면이 꺼져 있던 동안의 몫).
    mutating func flush() { shown += pending; pending = 0 }
    mutating func reset() { pending = 0; shown = 0 }

    /// 1000 미만은 정수, 그 위는 소수 한 자리(내림)에 K·M·B·T.
    static func format(_ value: Double) -> String {
        if value < 1000 { return String(Int(max(0, value))) }
        let units = ["K", "M", "B", "T"]
        var x = value / 1000, index = 0
        while index < units.count - 1 && x >= 1000 { x /= 1000; index += 1 }
        return String(format: "%.1f", floor(x * 10) / 10) + units[index]
    }
}
