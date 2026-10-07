import Foundation
import CryptoKit

struct ProviderRateLimit {
    let spacing: TimeInterval
    let count: Int
    let window: TimeInterval
    private(set) var starts: [TimeInterval] = []
    private var next = -Double.infinity
    private var blockedUntil = -Double.infinity

    init(spacing: TimeInterval, count: Int, window: TimeInterval) {
        self.spacing = spacing; self.count = count; self.window = window
    }

    mutating func delay(at now: TimeInterval) -> TimeInterval {
        starts.removeAll { $0 <= now - window }
        let quota = starts.count >= count ? (starts.first ?? now) + window : now
        return max(0, max(next, max(blockedUntil, quota)) - now)
    }
    mutating func started(at now: TimeInterval) { starts.append(now); next = now + spacing }
    mutating func deferRequests(for seconds: TimeInterval, at now: TimeInterval) { blockedUntil = max(blockedUntil, now + seconds) }
}

actor ProviderHTTP {
    private let transport: BoundedHTTPTransport
    private let cache: DiskCache
    private var cacheGeneration = UUID()
    private var limits: [String: ProviderRateLimit] = [
        "api.openf1.org": ProviderRateLimit(spacing: 2.1, count: 30, window: 60),
        "api.jolpi.ca": ProviderRateLimit(spacing: 0.3, count: 500, window: 3600),
        "livetiming.formula1.com": ProviderRateLimit(spacing: 0.5, count: 60, window: 60)
    ]

    init(configuration: URLSessionConfiguration? = nil, directory: URL? = nil, rateLimits: [String: ProviderRateLimit]? = nil) {
        if let rateLimits { limits = rateLimits }
        let configuration = configuration ?? URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 45
        configuration.timeoutIntervalForResource = 120
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpShouldSetCookies = false
        transport = BoundedHTTPTransport(configuration: configuration)
        let directory = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Paddock/Responses", isDirectory: true)
        cache = DiskCache(directory: directory, maximumBytes: 100 * 1024 * 1024, maximumEntries: 300, maximumEntryBytes: 64 * 1024 * 1024)
        cache.maintain()
    }

    func request(_ url: URL, maxAge: TimeInterval = 86400) async throws -> JSONValue {
        try await request(url, maxAge: maxAge, decode: { $0 })
    }

    func request<Value: Sendable>(_ url: URL, maxAge: TimeInterval = 86400,
                                  decode: @Sendable (JSONValue) throws -> Value) async throws -> Value {
        try await fetch(url, maxAge: maxAge, maximumBytes: 16 * 1024 * 1024, cacheResponse: true) { data in
            let json: JSONValue
            do { json = try JSONValue.decode(data) }
            catch { throw ProviderError.invalidData("The provider returned invalid JSON data.") }
            return try decode(json)
        }
    }

    func bytes(_ url: URL, maxAge: TimeInterval = 86400, maximumBytes: Int = 16 * 1024 * 1024, cacheResponse: Bool = true) async throws -> Data {
        try await fetch(url, maxAge: maxAge, maximumBytes: maximumBytes, cacheResponse: cacheResponse, decode: { $0 })
    }

    private func fetch<Value: Sendable>(_ url: URL, maxAge: TimeInterval, maximumBytes: Int, cacheResponse: Bool,
                                        decode: @Sendable (Data) throws -> Value) async throws -> Value {
        try Task.checkCancellation()
        guard Self.isProviderURL(url), let host = url.host, maximumBytes > 0, maximumBytes <= 64 * 1024 * 1024 else { throw ProviderError.invalidData("This data source URL is not supported.") }
        let name = SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined() + ".json"
        if cacheResponse, let data = cache.read(name, maxAge: maxAge), data.count <= maximumBytes {
            do {
                let value = try decode(data)
                try Task.checkCancellation()
                return value
            } catch {
                if Task.isCancelled || error is CancellationError { throw CancellationError() }
                try? cache.remove(name)
            }
        }
        let generation = cacheGeneration
        for attempt in 0..<3 {
            try await waitForSlot(host)
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
            request.setValue("Paddock/1.0 (personal race companion)", forHTTPHeaderField: "User-Agent")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            do {
                let (data, response) = try await transport.data(for: request, maximumBytes: maximumBytes)
                guard let finalURL = response.url, finalURL.host == url.host, Self.isProviderURL(finalURL) else {
                    throw ProviderError.invalidData("The provider returned an unreadable response.")
                }
                guard (200..<300).contains(response.statusCode) else {
                    if response.statusCode == 429 || response.statusCode == 503 {
                        let delay = Self.retryDelay(response.value(forHTTPHeaderField: "Retry-After"))
                        limits[host]?.deferRequests(for: delay, at: ProcessInfo.processInfo.systemUptime)
                        if attempt < 2 { continue }
                    }
                    if [408, 425, 500, 502, 504].contains(response.statusCode), attempt < 2 {
                        try await Task.sleep(for: .seconds(Double(attempt + 1)))
                        continue
                    }
                    throw ProviderError.response(response.statusCode)
                }
                try Task.checkCancellation()
                guard !data.isEmpty else { throw ProviderError.invalidData("The provider returned no data.") }
                let value = try decode(data)
                try Task.checkCancellation()
                if cacheResponse, generation == cacheGeneration { cache.write(data, name: name) }
                return value
            } catch {
                if Task.isCancelled || (error as? URLError)?.code == .cancelled { throw CancellationError() }
                if let error = error as? URLError,
                   [.timedOut, .networkConnectionLost, .cannotConnectToHost, .notConnectedToInternet].contains(error.code), attempt < 2 {
                    try await Task.sleep(for: .seconds(Double(attempt + 1)))
                    continue
                }
                throw error
            }
        }
        throw ProviderError.response(429)
    }

    func clear() { cacheGeneration = UUID(); try? cache.clear() }

    private func waitForSlot(_ host: String) async throws {
        while true {
            try Task.checkCancellation()
            let now = ProcessInfo.processInfo.systemUptime
            let delay = limits[host]?.delay(at: now) ?? 0
            if delay <= 0 { limits[host]?.started(at: now); return }
            try await Task.sleep(for: .seconds(delay))
        }
    }

    static func isProviderURL(_ url: URL) -> Bool {
        let permittedHost = ["api.openf1.org", "api.jolpi.ca"].contains(url.host ?? "")
            || (url.host == "livetiming.formula1.com" && url.path.hasPrefix("/static/") && !url.path.contains(".."))
        return url.scheme == "https" && permittedHost && url.user == nil && url.password == nil
            && (url.port == nil || url.port == 443)
    }

    static func retryDelay(_ value: String?, now: Date = Date()) -> TimeInterval {
        if let value, let seconds = Double(value), seconds.isFinite { return min(3600, max(1, seconds)) }
        if let value {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
            if let date = formatter.date(from: value) { return min(3600, max(1, date.timeIntervalSince(now))) }
        }
        return 10
    }
}
