import Foundation

/// 중·강·폭주 단계가 시작되는 속도. 분당 천 토큰 단위로 저장한다.
struct BurnThresholds: Equatable {
    static let titles = ["중", "강", "폭주"]
    static let range = 1...9999
    static let standard = BurnThresholds(perMinuteThousands: [8, 25, 70])!
    /// 에이전트 한두 개 / 여러 개(기본) / 열 개 넘게 돌릴 때에 맞춘 값.
    static let presets = [BurnThresholds(perMinuteThousands: [4, 12, 30])!, standard,
                          BurnThresholds(perMinuteThousands: [20, 60, 150])!]
    static let defaultsKey = "burnThresholds"
    let perMinuteThousands: [Int]

    init?(perMinuteThousands values: [Int]) {
        guard values.count == Self.titles.count, values.allSatisfy({ Self.range.contains($0) }),
              zip(values, values.dropFirst()).allSatisfy({ $0.0 <= $0.1 }) else { return nil }
        perMinuteThousands = values
    }
    /// 초당 토큰으로 바꾼 값.
    var perSecond: [Double] { perMinuteThousands.map { Double($0) * 1000 / 60 } }
    static func load(from defaults: UserDefaults = .standard) -> BurnThresholds {
        guard let values = defaults.array(forKey: defaultsKey) as? [Int],
              let value = BurnThresholds(perMinuteThousands: values) else { return .standard }
        return value
    }
    func save(to defaults: UserDefaults = .standard) { defaults.set(perMinuteThousands, forKey: Self.defaultsKey) }
}

/// 들어온 토큰을 한꺼번에 태우지 않고 몇 초에 걸쳐 풀어낸다. 풀려 나가는 속도가 불 단계를 정한다.
struct BurnModel {
    static let tierNames = ["대기", "약", "중", "강", "폭주"]
    /// 한 번에 들어온 양이 대략 이 시간에 걸쳐 탄다.
    static let drainSeconds = 15.0
    /// 남은 양이 적을 때의 최소 속도. 끝자락이 한없이 늘어지지 않게 한다.
    static let floorRate = 15.0

    /// 중·강·폭주가 시작되는 속도. 같은 값이면 더 높은 단계가 된다.
    var thresholds = BurnThresholds.standard
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
        for (index, start) in thresholds.perSecond.enumerated() where value >= start { tier = index + 2 }
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

/// 정해 둔 토큰 양. 화면 숫자가 "현재/목표"로 바뀌고, 다 채우면 금색이 되며 알림이 한 번 간다.
struct BurnGoal: Equatable {
    static let range = 1_000.0...999e12
    static let units: [(title: String, scale: Double)] = [("K", 1e3), ("M", 1e6), ("B", 1e9)]
    /// 구독 주간 한도 100%에 해당하는 입력+출력 토큰 어림.
    /// 2026-11 한 사용자의 기록에서 실제 사용률과 맞춰 잰 값이다(Codex는 주간 창 4개에서 ±15%, Claude는 한 시점).
    /// 요금제가 다르면 달라지므로 안내 문구에만 쓴다.
    static let weeklyEstimate: [(source: UsageSource, tokens: Double)] = [(.claude, 37e6), (.codex, 32e6)]
    /// 주간 어림을 7로 나눈 하루 몫에 가까운 값.
    static let suggested = 5e6

    let target: Double
    /// 날짜가 바뀌면 0부터 다시 센다.
    let daily: Bool

    init?(target: Double, daily: Bool) {
        guard Self.range.contains(target) else { return nil }
        self.target = target
        self.daily = daily
    }
    func reached(_ shown: Double) -> Bool { shown >= target }
    func text(shown: Double) -> String { BurnModel.format(shown) + "/" + Self.compact(target) }
    /// 목표 표기. 소수 한 자리로 반올림하고 ".0"은 뺀다: 5M, 2.5M, 800K.
    static func compact(_ value: Double) -> String {
        if value < 1000 { return String(Int(max(0, value))) }
        let units = ["K", "M", "B", "T"]
        var x = value / 1000, index = 0
        while index < units.count - 1 && (x * 10).rounded() / 10 >= 1000 { x /= 1000; index += 1 }
        let tenths = Int((x * 10).rounded())
        return (tenths % 10 == 0 ? String(tenths / 10) : "\(tenths / 10).\(tenths % 10)") + units[index]
    }
    /// 입력 칸에 다시 채울 값과 단위: 2_500_000 → (2.5, M).
    static func split(_ value: Double) -> (number: Double, unit: Int) {
        var unit = 0
        for (index, entry) in units.enumerated() where value >= entry.scale { unit = index }
        return (value / units[unit].scale, unit)
    }
    /// "Claude 주간 한도의 약 14% · Codex 약 16%"
    static func share(of target: Double) -> String {
        weeklyEstimate.enumerated().map { index, entry in
            let percent = target / entry.tokens * 100
            let text = percent >= 10 ? String(Int(percent.rounded())) : String(format: "%.1f", percent)
            return index == 0 ? "\(entry.source.title) 주간 한도의 약 \(text)%" : "\(entry.source.title) 약 \(text)%"
        }.joined(separator: " · ")
    }
    static func dayKey(_ date: Date = Date(), calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}
