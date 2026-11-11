import Foundation

// 실행: scripts/test.sh. 인자 하나로 그림 폴더(Resources)를 받는다.
var failures = 0
func check(_ condition: Bool, _ message: String, line: Int = #line) {
    if !condition { failures += 1; print("FAIL(\(line)): \(message)") }
}
func data(_ text: String) -> Data { Data(text.utf8) }
let start = UsageTime.parse("2026-11-11T08:00:00.000Z")!

// 숫자 표기
for (value, text) in [(0.0, "0"), (999, "999"), (1000, "1.0K"), (128_400, "128.4K"), (999_999, "999.9K"), (1_000_000, "1.0M"),
                      (999.96e6, "999.9M"), (1e9, "1.0B"), (1e12, "1.0T"), (3.4e15, "3400.0T")] {
    check(BurnModel.format(value) == text, "format \(value) → \(BurnModel.format(value)), 기대 \(text)")
}

// Claude: 같은 응답이 여러 줄이면 늘어난 만큼만 센다
func claudeLine(id: String, time: String, input: Int, create: Int, read: Int, output: Int) -> Data {
    data(#"{"type":"assistant","timestamp":"\#(time)","message":{"id":"\#(id)","usage":{"input_tokens":\#(input),"cache_creation_input_tokens":\#(create),"cache_read_input_tokens":\#(read),"output_tokens":\#(output)}}}"#)
}
do {
    var parser = ClaudeUsageParser()
    let a = parser.parse(line: claudeLine(id: "m1", time: "2026-11-11T08:00:01.000Z", input: 2, create: 100, read: 5000, output: 10), notBefore: start)
    let b = parser.parse(line: claudeLine(id: "m1", time: "2026-11-11T08:00:02.000Z", input: 2, create: 100, read: 5000, output: 10), notBefore: start)
    let c = parser.parse(line: claudeLine(id: "m1", time: "2026-11-11T08:00:03.000Z", input: 2, create: 100, read: 5000, output: 250), notBefore: start)
    check(a == UsageDelta(fresh: 12, cached: 5100), "claude 첫 줄(캐시 쓰기·읽기는 세지 않는 쪽) \(a)")
    check(b == .zero, "claude 반복 줄은 0이어야 함 \(b)")
    check(c == UsageDelta(fresh: 240, cached: 0), "claude 늘어난 출력만 \(c)")
    let old = parser.parse(line: claudeLine(id: "m0", time: "2026-11-11T07:59:59.000Z", input: 9, create: 9, read: 9, output: 9), notBefore: start)
    check(old == .zero, "시작 전 기록은 0이어야 함")
    check(parser.parse(line: data(#"{"type":"user","timestamp":"2026-11-11T08:00:05.000Z","message":{"content":"\"usage\" 라는 글자"}}"#), notBefore: start) == .zero, "usage 없는 줄")
    check(parser.parse(line: data("{깨진 줄 \"usage\""), notBefore: start) == .zero, "깨진 줄")
}

// Codex: 누적값의 차이를 쓰고, 같은 누적값이 다시 오면 0
func codexLine(time: String, total: (Int, Int, Int), last: (Int, Int, Int)) -> Data {
    data(#"{"timestamp":"\#(time)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":\#(total.0),"cached_input_tokens":\#(total.1),"output_tokens":\#(total.2)},"last_token_usage":{"input_tokens":\#(last.0),"cached_input_tokens":\#(last.1),"output_tokens":\#(last.2)}}}}"#)
}
do {
    var parser = CodexUsageParser()
    let a = parser.parse(line: codexLine(time: "2026-11-11T08:00:01Z", total: (9000, 8000, 500), last: (1000, 900, 50)), notBefore: start)
    let b = parser.parse(line: codexLine(time: "2026-11-11T08:00:02Z", total: (9000, 8000, 500), last: (1000, 900, 50)), notBefore: start)
    let c = parser.parse(line: codexLine(time: "2026-11-11T08:00:09Z", total: (10200, 9100, 530), last: (1200, 1100, 30)), notBefore: start)
    check(a == UsageDelta(fresh: 150, cached: 900), "codex 첫 이벤트는 요청별 값 \(a)")
    check(b == .zero, "codex 같은 누적값 \(b)")
    check(c == UsageDelta(fresh: 130, cached: 1100), "codex 누적 차이 \(c)")
    check(parser.parse(line: data(#"{"timestamp":"2026-11-11T08:00:10Z","type":"event_msg","payload":{"type":"token_count","info":null}}"#), notBefore: start) == .zero, "info 없는 이벤트")
}

// 파일 따라 읽기: 시작 때 있던 내용은 건너뛰고, 덜 쓰인 줄은 다 쓰인 뒤에 센다
do {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("token-bonfire-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: home) }
    let project = home.appendingPathComponent(".claude/projects/p1")
    let codexDay = home.appendingPathComponent(".codex/sessions/2026/11/11")
    try FileManager.default.createDirectory(at: project.appendingPathComponent("s1/subagents"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: project.appendingPathComponent("s1/tool-results"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: codexDay, withIntermediateDirectories: true)
    func append(_ url: URL, _ content: Data) throws {
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: content)
    }
    let newline = data("\n")
    let session = project.appendingPathComponent("s1.jsonl")
    try append(session, claudeLine(id: "before", time: "2026-11-11T08:00:30.000Z", input: 1, create: 1, read: 1, output: 777) + newline)
    let tailer = UsageTailer(home: home, start: start)
    var now = start.addingTimeInterval(60)
    check(tailer.poll(now: now).isEmpty, "첫 훑기는 0이어야 함")
    check(tailer.trackedFiles == 1, "추적 파일 수 \(tailer.trackedFiles)")

    let full = claudeLine(id: "m2", time: "2026-11-11T08:01:10.000Z", input: 5, create: 20, read: 3000, output: 75) + newline
    let partial = claudeLine(id: "m3", time: "2026-11-11T08:01:12.000Z", input: 1, create: 0, read: 100, output: 9)
    try append(session, full + partial.prefix(40))
    now += 7
    var result = tailer.poll(now: now)
    check(result[.claude] == UsageDelta(fresh: 80, cached: 3020), "다 쓰인 줄만 세야 함 \(String(describing: result[.claude]))")
    try append(session, partial.dropFirst(40) + newline)
    now += 2
    result = tailer.poll(now: now)
    check(result[.claude] == UsageDelta(fresh: 10, cached: 100), "나머지가 쓰인 뒤 셈(자주 읽는 파일 경로) \(String(describing: result[.claude]))")

    // 시작 뒤에 생긴 파일: 서브에이전트 기록과 Codex 세션, 그리고 옛 시각만 든 파일
    try append(project.appendingPathComponent("s1/subagents/agent-a.jsonl"), claudeLine(id: "sub1", time: "2026-11-11T08:01:20.000Z", input: 0, create: 0, read: 0, output: 40) + newline)
    try append(project.appendingPathComponent("s1/tool-results/x.jsonl"), claudeLine(id: "tool", time: "2026-11-11T08:01:20.000Z", input: 0, create: 0, read: 0, output: 999) + newline)
    try append(project.appendingPathComponent("resumed.jsonl"), claudeLine(id: "oldcopy", time: "2026-11-10T08:01:20.000Z", input: 0, create: 0, read: 0, output: 555) + newline)
    try append(codexDay.appendingPathComponent("rollout.jsonl"), codexLine(time: "2026-11-11T08:01:21Z", total: (700, 600, 30), last: (700, 600, 30)) + newline)
    now += 7
    result = tailer.poll(now: now)
    check(result[.claude] == UsageDelta(fresh: 40, cached: 0), "서브에이전트만 세고 tool-results·옛 기록은 빼야 함 \(String(describing: result[.claude]))")
    check(result[.codex] == UsageDelta(fresh: 130, cached: 600), "새 Codex 파일 \(String(describing: result[.codex]))")

    // 초기화: 그 시각 뒤 기록만 센다
    tailer.notBefore = UsageTime.parse("2026-11-11T08:05:00.000Z")!
    try append(session, claudeLine(id: "m4", time: "2026-11-11T08:04:59.000Z", input: 0, create: 0, read: 0, output: 11) + newline
        + claudeLine(id: "m5", time: "2026-11-11T08:05:01.000Z", input: 0, create: 0, read: 0, output: 22) + newline)
    now += 2
    result = tailer.poll(now: now)
    check(result[.claude] == UsageDelta(fresh: 22, cached: 0), "초기화 뒤 기록만 \(String(describing: result[.claude]))")
} catch {
    check(false, "파일 시험 준비 실패: \(error)")
}

// 태우는 속도와 단계
do {
    var model = BurnModel()
    check(model.tier == 0 && model.rate == 0, "빈 상태는 대기")
    model.add(1500)
    check(model.tier == 1, "1500 토큰은 약 단계, 실제 \(model.tier)")
    model.add(60_000)
    check(model.tier == 4, "6만 토큰이 한꺼번에 오면 폭주, 실제 \(model.tier)")
    // 기준을 바꾸면 같은 양도 다른 단계가 된다
    var light = BurnModel()
    light.thresholds = BurnThresholds.presets[0]
    light.add(1500)
    check(light.tier == 2, "가벼운 기준에서는 1500 토큰(분당 6천 꼴)이 중 단계, 실제 \(light.tier)")
    check(BurnThresholds(perMinuteThousands: [8, 25, 70]) == .standard, "기본 기준")
    check(BurnThresholds(perMinuteThousands: [30, 20, 70]) == nil, "거꾸로 된 기준은 거부")
    check(BurnThresholds(perMinuteThousands: [0, 20, 70]) == nil && BurnThresholds(perMinuteThousands: [8, 25]) == nil, "범위·개수 검사")
    check(BurnThresholds(perMinuteThousands: [10, 10, 10]) != nil, "같은 값은 허용")
    var same = BurnModel()
    same.thresholds = BurnThresholds(perMinuteThousands: [10, 10, 10])!
    same.add(3000)
    check(same.tier == 4, "같은 값이면 더 높은 단계, 실제 \(same.tier)")
    var out = 0.0, steps = 0
    while model.pending > 0 && steps < 100_000 { out += model.drain(1.0 / 30); steps += 1 }
    check(abs(out - 61_500) < 1e-6, "풀려 나간 합 \(out)")
    check(Double(steps) / 30 < 120, "2분 안에 다 타야 함, 실제 \(Double(steps) / 30)초")
}

// 그림 합성: 들어온 토큰이 빠짐없이 숫자에 더해지는지
if CommandLine.arguments.count > 1 {
    do {
        let atlas = try AtlasStore(resources: URL(fileURLWithPath: CommandLine.arguments[1]))
        let renderer = try BonfireRenderer(atlas: atlas)
        var seed: UInt64 = 42
        renderer.random = { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Double(seed >> 11) / Double(1 << 53) }
        var model = BurnModel()
        model.add(50_000)
        var maxLevel = 0, maxCoins = 0
        // 40만 토큰은 다 타는 데 2분쯤 걸린다(15초 반감 꼴로 줄다가 끝자락은 일정 속도).
        for step in 0..<(30 * 240) {
            if step == 30 * 20 { model.add(400_000) }
            let released = model.drain(1.0 / 30)
            model.shown += renderer.step(dt: 1.0 / 30, tier: model.tier, released: released)
            maxLevel = max(maxLevel, renderer.fireLevel)
            maxCoins = max(maxCoins, renderer.coins.count)
            if step % 150 == 0 {
                let image = renderer.image(number: BurnModel.format(model.shown))
                check(image?.width == Art.width && image?.height == Art.height, "합친 그림 크기")
            }
        }
        check(abs(model.shown - 450_000) < 1e-6, "숫자 합 \(model.shown), 기대 450000")
        check(renderer.coins.isEmpty && renderer.tokensInFlight == 0, "끝나면 떠 있는 동전이 없어야 함")
        check(maxLevel >= 8 && maxLevel <= 10, "폭주에서 불 단계 \(maxLevel)")
        check(renderer.fireLevel == 0, "다 타면 대기 단계, 실제 \(renderer.fireLevel)")
        check(atlas.loadedFireLevels <= 4, "들고 있는 불 시트 \(atlas.loadedFireLevels)")
        _ = renderer.image(number: "0")
        check(renderer.isOpaque(x: 80, y: 146), "장작 자리는 불투명")
        check(!renderer.isOpaque(x: 2, y: 2), "구석은 투명")
        print("render: maxLevel \(maxLevel) maxCoins \(maxCoins)")
    } catch {
        check(false, "그림 시험 실패: \(error)")
    }
}

print(failures == 0 ? "OK" : "FAILED \(failures)")
exit(failures == 0 ? 0 : 1)
