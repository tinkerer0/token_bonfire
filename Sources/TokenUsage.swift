import Foundation

/// 새로 쓴 토큰 수. fresh = 입력 + 출력(앱이 세는 양), cached = 캐시에 쓰거나 캐시에서 읽은 입력(세지 않고 --scan 출력에만 쓴다).
struct UsageDelta: Equatable {
    var fresh = 0
    var cached = 0
    static let zero = UsageDelta()
    static func + (a: UsageDelta, b: UsageDelta) -> UsageDelta {
        UsageDelta(fresh: a.fresh + b.fresh, cached: a.cached + b.cached)
    }
}

enum UsageSource: String, CaseIterable {
    case claude, codex
    var title: String { self == .claude ? "Claude Code" : "Codex" }
    /// 세션 기록이 쌓이는 폴더(홈 기준).
    var folder: String { self == .claude ? ".claude/projects" : ".codex/sessions" }
}

enum UsageTime {
    private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let plain = ISO8601DateFormatter()
    static func parse(_ text: String) -> Date? { fractional.date(from: text) ?? plain.date(from: text) }
}

private func number(_ value: Any?) -> Int { (value as? NSNumber)?.intValue ?? 0 }
private func stamp(_ object: [String: Any]) -> Date? { (object["timestamp"] as? String).flatMap(UsageTime.parse) }

/// Claude Code 기록 한 줄에서 사용량을 읽는다. 같은 응답(message.id)이 내용 조각마다 여러 줄로
/// 반복 기록되므로, 응답마다 이미 센 양을 기억해 늘어난 만큼만 돌려준다.
struct ClaudeUsageParser {
    private static let marker = Data("\"usage\"".utf8)
    private var counted: [String: UsageDelta] = [:]
    private var order: [String] = []
    private let capacity: Int
    init(capacity: Int = 20_000) { self.capacity = capacity }

    mutating func parse(line: Data, notBefore: Date) -> UsageDelta {
        guard line.range(of: Self.marker) != nil,
              let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let message = object["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any],
              let time = stamp(object), time >= notBefore else { return .zero }
        let key = (message["id"] as? String) ?? (object["uuid"] as? String) ?? UUID().uuidString
        let now = UsageDelta(
            fresh: number(usage["input_tokens"]) + number(usage["output_tokens"]),
            cached: number(usage["cache_creation_input_tokens"]) + number(usage["cache_read_input_tokens"]))
        let old = counted[key]
        let before = old ?? .zero
        let delta = UsageDelta(fresh: max(0, now.fresh - before.fresh), cached: max(0, now.cached - before.cached))
        counted[key] = UsageDelta(fresh: max(now.fresh, before.fresh), cached: max(now.cached, before.cached))
        if old == nil {
            order.append(key)
            if order.count > capacity {
                for stale in order.prefix(capacity / 4) { counted[stale] = nil }
                order.removeFirst(capacity / 4)
            }
        }
        return delta
    }
}

/// Codex 기록 한 줄에서 사용량을 읽는다(파일마다 하나). token_count 이벤트에는 세션 누적값이 들어 있어
/// 앞 이벤트와의 차이를 쓴다. 같은 누적값이 다시 기록되면 0이 된다. 첫 이벤트는 요청별 값(last_token_usage)을 쓴다.
struct CodexUsageParser {
    private static let marker = Data("token_count".utf8)
    private var previous: UsageDelta?

    mutating func parse(line: Data, notBefore: Date) -> UsageDelta {
        guard line.range(of: Self.marker) != nil,
              let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let payload = object["payload"] as? [String: Any], payload["type"] as? String == "token_count",
              let info = payload["info"] as? [String: Any],
              let total = info["total_token_usage"] as? [String: Any] else { return .zero }
        let current = Self.usage(total)
        defer { previous = current }
        let delta: UsageDelta
        if let previous {
            delta = UsageDelta(fresh: max(0, current.fresh - previous.fresh), cached: max(0, current.cached - previous.cached))
        } else {
            delta = (info["last_token_usage"] as? [String: Any]).map(Self.usage) ?? .zero
        }
        guard let time = stamp(object), time >= notBefore else { return .zero }
        return delta
    }

    private static func usage(_ values: [String: Any]) -> UsageDelta {
        let input = number(values["input_tokens"]), cached = number(values["cached_input_tokens"])
        return UsageDelta(fresh: max(0, input - cached) + number(values["output_tokens"]), cached: cached)
    }
}

/// 세션 기록 파일에 새로 붙은 부분만 읽어 사용량을 모은다. 시작할 때 있던 내용은 건너뛴다.
/// 한 큐에서만 부른다.
final class UsageTailer {
    private struct Tracked {
        let source: UsageSource
        var offset: UInt64
        var lastChange: Date
        var codex = CodexUsageParser()
    }
    private static let discoveryInterval: TimeInterval = 6
    private static let hotWindow: TimeInterval = 300
    private static let readLimit = 16 << 20

    private let roots: [(UsageSource, URL)]
    private var files: [String: Tracked] = [:]
    private var claude = ClaudeUsageParser()
    private var baselineDone = false
    private var lastDiscovery = Date.distantPast
    /// 이 시각보다 앞선 기록은 세지 않는다(시작·초기화 시각).
    var notBefore: Date

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser, start: Date = Date()) {
        roots = UsageSource.allCases.map { ($0, home.appendingPathComponent($0.folder)) }
        notBefore = start
    }

    var trackedFiles: Int { files.count }

    func poll(now: Date = Date()) -> [UsageSource: UsageDelta] {
        var result: [UsageSource: UsageDelta] = [:]
        func add(_ source: UsageSource, _ delta: UsageDelta) { result[source] = (result[source] ?? .zero) + delta }
        if !baselineDone || now.timeIntervalSince(lastDiscovery) >= Self.discoveryInterval {
            for (source, root) in roots {
                let keys: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey]
                guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys) else { continue }
                for case let url as URL in walker {
                    if url.lastPathComponent == "tool-results" { walker.skipDescendants(); continue }
                    guard url.pathExtension == "jsonl", let values = try? url.resourceValues(forKeys: Set(keys)),
                          values.isRegularFile == true, let size = values.fileSize else { continue }
                    let path = url.path
                    if var tracked = files[path] {
                        if UInt64(size) != tracked.offset {
                            add(source, read(path: path, tracked: &tracked, size: UInt64(size), now: now))
                            files[path] = tracked
                        }
                    } else if !baselineDone {
                        files[path] = Tracked(source: source, offset: UInt64(size), lastChange: .distantPast)
                    } else {
                        var tracked = Tracked(source: source, offset: 0, lastChange: now)
                        add(source, read(path: path, tracked: &tracked, size: UInt64(size), now: now))
                        files[path] = tracked
                    }
                }
            }
            baselineDone = true
            lastDiscovery = now
        } else {
            for (path, var tracked) in files where now.timeIntervalSince(tracked.lastChange) < Self.hotWindow {
                guard let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.uint64Value,
                      size != tracked.offset else { continue }
                add(tracked.source, read(path: path, tracked: &tracked, size: size, now: now))
                files[path] = tracked
            }
        }
        return result
    }

    private func read(path: String, tracked: inout Tracked, size: UInt64, now: Date) -> UsageDelta {
        if size < tracked.offset { tracked.offset = size; return .zero }
        guard let handle = FileHandle(forReadingAtPath: path) else { return .zero }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: tracked.offset)) != nil,
              let chunk = try? handle.read(upToCount: Self.readLimit), !chunk.isEmpty else { return .zero }
        tracked.lastChange = now
        // 마지막 줄바꿈까지만 처리하고, 덜 쓰인 줄은 다음에 다시 읽는다.
        guard let lastBreak = chunk.lastIndex(of: 0x0A) else {
            if chunk.count >= Self.readLimit { tracked.offset += UInt64(chunk.count) }
            return .zero
        }
        var total = UsageDelta.zero
        for line in chunk[chunk.startIndex..<lastBreak].split(separator: 0x0A) {
            let data = Data(line)
            switch tracked.source {
            case .claude: total = total + claude.parse(line: data, notBefore: notBefore)
            case .codex: total = total + tracked.codex.parse(line: data, notBefore: notBefore)
            }
        }
        tracked.offset += UInt64(lastBreak - chunk.startIndex + 1)
        return total
    }
}
