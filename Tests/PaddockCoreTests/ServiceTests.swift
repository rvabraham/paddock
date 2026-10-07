import Foundation
import Testing
@testable import PaddockCore

private final class HTTPStub: URLProtocol, @unchecked Sendable {
    struct Response {
        var status = 200
        var headers: [String: String] = [:]
        var chunks: [Data]
        var delay: TimeInterval = 0
    }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var responses: [String: Response] = [:]
    nonisolated(unsafe) private static var starts: [String: Int] = [:]
    nonisolated(unsafe) private static var responseTimes: [String: TimeInterval] = [:]
    nonisolated(unsafe) private static var startTimes: [String: TimeInterval] = [:]
    private var work: DispatchWorkItem?

    static func register(_ response: Response, url: URL) {
        lock.lock(); responses[url.absoluteString] = response; starts[url.absoluteString] = 0; lock.unlock()
    }
    static func count(_ url: URL) -> Int {
        lock.lock(); defer { lock.unlock() }; return starts[url.absoluteString] ?? 0
    }
    static func responseTime(_ url: URL) -> TimeInterval? {
        lock.lock(); defer { lock.unlock() }; return responseTimes[url.absoluteString]
    }
    static func startTime(_ url: URL) -> TimeInterval? {
        lock.lock(); defer { lock.unlock() }; return startTimes[url.absoluteString]
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        Self.lock.lock(); let response = Self.responses[url.absoluteString]; Self.starts[url.absoluteString, default: 0] += 1; Self.startTimes[url.absoluteString] = ProcessInfo.processInfo.systemUptime; Self.lock.unlock()
        guard let response else { client?.urlProtocol(self, didFailWithError: URLError(.fileDoesNotExist)); return }
        let work = DispatchWorkItem { [self] in
            guard let http = HTTPURLResponse(url: url, statusCode: response.status, httpVersion: "HTTP/1.1", headerFields: response.headers) else { return }
            Self.lock.lock(); Self.responseTimes[url.absoluteString] = ProcessInfo.processInfo.systemUptime; Self.lock.unlock()
            client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
            for chunk in response.chunks { client?.urlProtocol(self, didLoad: chunk) }
            client?.urlProtocolDidFinishLoading(self)
        }
        self.work = work
        DispatchQueue.global().asyncAfter(deadline: .now() + response.delay, execute: work)
    }
    override func stopLoading() { work?.cancel() }
}

struct ServiceTests {
    private func directory() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("paddock-tests-" + UUID().uuidString, isDirectory: true) }
    private func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HTTPStub.self]
        return configuration
    }
    private func url() -> URL { URL(string: "https://api.jolpi.ca/test/" + UUID().uuidString)! }

    @Test func providerRefreshSkipsDiskAndURLSessionCache() async throws {
        let directory = directory(), url = url()
        defer { try? FileManager.default.removeItem(at: directory) }
        let provider = ProviderHTTP(configuration: configuration(), directory: directory)
        HTTPStub.register(.init(chunks: [Data("[1]".utf8)]), url: url)
        #expect(try await provider.request(url).array.first?.int == 1)
        #expect(try await provider.request(url).array.first?.int == 1)
        #expect(HTTPStub.count(url) == 1)
        HTTPStub.register(.init(chunks: [Data("[2]".utf8)]), url: url)
        #expect(try await provider.request(url, maxAge: 0).array.first?.int == 2)
        #expect(HTTPStub.count(url) == 1)
    }

    @Test func clearingCacheDuringRequestCannotRestoreOldResponse() async throws {
        let directory = directory(), url = url()
        defer { try? FileManager.default.removeItem(at: directory) }
        let provider = ProviderHTTP(configuration: configuration(), directory: directory)
        HTTPStub.register(.init(chunks: [Data("[1]".utf8)], delay: 0.1), url: url)
        let request = Task { try await provider.request(url) }
        while HTTPStub.count(url) == 0 { await Task.yield() }
        await provider.clear()
        #expect(try await request.value.array.first?.int == 1)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @Test func cancellationStopsPendingNetworkRequest() async throws {
        let url = url(), directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let provider = ProviderHTTP(configuration: configuration(), directory: directory)
        HTTPStub.register(.init(chunks: [Data("[]".utf8)], delay: 30), url: url)
        let task = Task { try await provider.request(url) }
        while HTTPStub.count(url) == 0 { await Task.yield() }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @Test func boundedTransportRejectsOversizedBodyWithoutContentLength() async throws {
        let url = url()
        HTTPStub.register(.init(chunks: [Data(repeating: 1, count: 500), Data(repeating: 2, count: 600)]), url: url)
        let transport = BoundedHTTPTransport(configuration: configuration())
        await #expect(throws: ProviderError.self) { try await transport.data(for: URLRequest(url: url), maximumBytes: 1000) }
    }

    @Test func boundedTransportRejectsOversizedDeclaredBody() async throws {
        let url = url()
        HTTPStub.register(.init(headers: ["Content-Length": "1001"], chunks: []), url: url)
        let transport = BoundedHTTPTransport(configuration: configuration())
        await #expect(throws: ProviderError.self) { try await transport.data(for: URLRequest(url: url), maximumBytes: 1000) }
    }

    @Test func chunkedTransportPreservesLargeResponse() async throws {
        let url = url(), chunk = Data(repeating: 65, count: 65536)
        HTTPStub.register(.init(chunks: Array(repeating: chunk, count: 128)), url: url)
        let transport = BoundedHTTPTransport(configuration: configuration())
        let (data, response) = try await transport.data(for: URLRequest(url: url), maximumBytes: 8 * 1024 * 1024)
        #expect(response.statusCode == 200)
        #expect(data.count == 8 * 1024 * 1024)
        #expect(data.first == 65 && data.last == 65)
    }

    @Test func providerRejectsUnsupportedOrCredentialedURLs() {
        for string in ["http://api.openf1.org/v1/laps", "https://api.openf1.org.evil.test/", "https://user:pass@api.openf1.org/", "file:///tmp/example", "https://api.jolpi.ca:8000/", "https://livetiming.formula1.com/signalrcore", "https://livetiming.formula1.com/static/../signalrcore"] {
            #expect(!ProviderHTTP.isProviderURL(URL(string: string)!))
        }
        #expect(ProviderHTTP.isProviderURL(URL(string: "https://api.openf1.org/v1/laps?session_key=1")!))
        let original = URL(string: "https://api.jolpi.ca/endpoint")!
        for string in ["https://api.openf1.org/", "https://user:pass@api.jolpi.ca/", "https://api.jolpi.ca:8000/", "http://api.jolpi.ca/"] {
            #expect(!BoundedHTTPTransport.allowsRedirect(from: original, to: URL(string: string)))
        }
        #expect(BoundedHTTPTransport.allowsRedirect(from: original, to: URL(string: "https://api.jolpi.ca/endpoint/")))
        let archive = URL(string: "https://livetiming.formula1.com/static/2019/Index.json")!
        #expect(ProviderHTTP.isProviderURL(archive))
        #expect(!BoundedHTTPTransport.allowsRedirect(from: archive, to: URL(string: "https://livetiming.formula1.com/signalrcore")))
    }

    @Test func transientFailureRetriesAndMalformedJSONDoesNotPoisonCache() async throws {
        let directory = directory(), url = url()
        defer { try? FileManager.default.removeItem(at: directory) }
        let provider = ProviderHTTP(configuration: configuration(), directory: directory)
        HTTPStub.register(.init(status: 500, chunks: []), url: url)
        let request = Task { try await provider.request(url) }
        while HTTPStub.count(url) == 0 { await Task.yield() }
        HTTPStub.register(.init(chunks: [Data("[2]".utf8)]), url: url)
        #expect(try await request.value.array.first?.int == 2)
        HTTPStub.register(.init(chunks: [Data("malformed".utf8)]), url: url)
        await #expect(throws: ProviderError.self) { try await provider.request(url, maxAge: 0) }
        HTTPStub.register(.init(chunks: [Data("[3]".utf8)]), url: url)
        #expect(try await provider.request(url).array.first?.int == 2)
        #expect(HTTPStub.count(url) == 0)
        #expect(try await provider.request(url, maxAge: 0).array.first?.int == 3)
        #expect(HTTPStub.count(url) == 1)
    }

    @Test func quotaTracksStartsAndSharedBackoff() {
        var limit = ProviderRateLimit(spacing: 0.3, count: 4, window: 10)
        let initialDelay = limit.delay(at: 0)
        #expect(initialDelay == 0)
        limit.started(at: 0)
        let spacingDelay = limit.delay(at: 0.1)
        #expect(abs(spacingDelay - 0.2) < 0.001)
        for value in [1.0, 2.0, 3.0] { limit.started(at: value) }
        let quotaDelay = limit.delay(at: 4), expiredDelay = limit.delay(at: 10)
        #expect(quotaDelay == 6)
        #expect(expiredDelay == 0)
        limit.deferRequests(for: 12, at: 10)
        let backoffDelay = limit.delay(at: 11)
        #expect(backoffDelay == 11)
    }

    @Test func retryAfterHandlesHTTPDatesAndNonfiniteValues() {
        let now = Date(timeIntervalSince1970: 0)
        #expect(ProviderHTTP.retryDelay("Thu, 01 Jan 1970 00:00:30 GMT", now: now) == 30)
        #expect(ProviderHTTP.retryDelay("inf") == 10)
        #expect(ProviderHTTP.retryDelay("NaN") == 10)
        #expect(ProviderHTTP.retryDelay("-10") == 1)
        #expect(ProviderHTTP.retryDelay("9000") == 3600)
    }

    @Test func finalThrottledAttemptDefersTheNextRequest() async throws {
        let url = url(), directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let provider = ProviderHTTP(configuration: configuration(), directory: directory)
        HTTPStub.register(.init(status: 429, headers: ["Retry-After": "1"], chunks: []), url: url)
        await #expect(throws: ProviderError.self) { try await provider.request(url) }
        #expect(HTTPStub.count(url) == 3)
        let throttleTime = try #require(HTTPStub.responseTime(url))
        HTTPStub.register(.init(chunks: [Data("[]".utf8)]), url: url)
        _ = try await provider.request(url)
        let nextStart = try #require(HTTPStub.startTime(url))
        #expect(nextStart - throttleTime >= 0.95)
    }

    @Test func diskCacheBoundsOldAndOversizedFiles() throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 150).write(to: directory.appendingPathComponent("oversized.json"))
        let cache = DiskCache(directory: directory, maximumBytes: 150, maximumEntries: 2, maximumEntryBytes: 100)
        cache.maintain()
        #expect(cache.entries().isEmpty)
        #expect(cache.write(Data(repeating: 1, count: 80), name: "first.json"))
        #expect(cache.write(Data(repeating: 2, count: 80), name: "second.json"))
        #expect(cache.entries().count == 1)
        #expect(cache.read("second.json")?.count == 80)
        #expect(!cache.write(Data([1]), name: "../escape.json"))
    }

    @Test func diskCacheRejectsSymlinkEntriesAndDirectories() throws {
        let directory = directory(), outside = self.directory()
        defer { try? FileManager.default.removeItem(at: directory); try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("[]".utf8).write(to: outside.appendingPathComponent("source.json"))
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("link.json"), withDestinationURL: outside.appendingPathComponent("source.json"))
        let cache = DiskCache(directory: directory, maximumBytes: 100, maximumEntries: 2, maximumEntryBytes: 100)
        #expect(cache.read("link.json") == nil)
        #expect(cache.entries().isEmpty)
        let link = directory.appendingPathComponent("linked-directory", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let linkedCache = DiskCache(directory: link, maximumBytes: 100, maximumEntries: 2, maximumEntryBytes: 100)
        #expect(!linkedCache.write(Data("[]".utf8), name: "new.json"))
        #expect(throws: ProviderError.self) { try linkedCache.clear() }
        #expect(throws: ProviderError.self) { try cache.remove("link.json") }
        #expect(try Data(contentsOf: outside.appendingPathComponent("source.json")) == Data("[]".utf8))
        #expect(!FileManager.default.fileExists(atPath: outside.appendingPathComponent("new.json").path))
    }

    @Test func lapAndCalendarDecodersRejectMalformedMeasurements() throws {
        for text in ["1:bad:03.2", "1::2", "inf", "NaN", "-1", "1:61", "1:2:3:4"] { #expect(ProviderDecoders.lapTime(.string(text)) == nil) }
        #expect(ProviderDecoders.lapTime(.string("1:23.456")) == 83.456)
        #expect(ProviderDecoders.combinedDate(.object(["date": .string("2026-02-30")])) == nil)
        #expect(ProviderDecoders.combinedDate(.object(["date": .string("2026--02-20")])) == nil)
        #expect(ProviderDecoders.combinedDate(.object(["date": .string("2026-02-extra-20")])) == nil)
    }

    @Test func calendarRejectsWrongSeasonsAndDuplicateRounds() throws {
        let row = #"{"season":"2026","round":"1","raceName":"Test Grand Prix","date":"2026-10-04"}"#
        let valid = try JSONValue.decode(Data("{\"MRData\":{\"RaceTable\":{\"season\":\"2026\",\"Races\":[\(row)]}}}".utf8))
        #expect(try ProviderDecoders.calendar(valid, year: 2026).count == 1)
        #expect(throws: ProviderError.self) { try ProviderDecoders.calendar(valid, year: 2025) }
        let duplicate = try JSONValue.decode(Data("{\"MRData\":{\"RaceTable\":{\"season\":\"2026\",\"Races\":[\(row),\(row)]}}}".utf8))
        #expect(throws: ProviderError.self) { try ProviderDecoders.calendar(duplicate, year: 2026) }
        let wrongRow = try JSONValue.decode(Data(#"{"MRData":{"RaceTable":{"season":"2026","Races":[{"season":"2025","round":"1","raceName":"Test Grand Prix","date":"2025-10-04"}]}}}"#.utf8))
        #expect(throws: ProviderError.self) { try ProviderDecoders.calendar(wrongRow, year: 2026) }
        let wrongDate = try JSONValue.decode(Data("{\"MRData\":{\"RaceTable\":{\"season\":\"2026\",\"Races\":[\(row.replacingOccurrences(of: "2026-10-04", with: "2025-10-04"))]}}}".utf8))
        #expect(throws: ProviderError.self) { try ProviderDecoders.calendar(wrongDate, year: 2026) }
    }

    @Test func sessionCatalogKeepsUniqueIdentifiersAndRejectsWrongSeasons() async throws {
        let responses = directory(), replays = directory(), year = 2089
        defer { try? FileManager.default.removeItem(at: responses); try? FileManager.default.removeItem(at: replays) }
        let http = ProviderHTTP(configuration: configuration(), directory: responses, rateLimits: [:])
        let provider = RaceProvider(replayDirectory: replays, http: http)
        let sessionsURL = URL(string: "https://api.openf1.org/v1/sessions?year=\(year)")!
        let meetingsURL = URL(string: "https://api.openf1.org/v1/meetings?year=\(year)")!
        HTTPStub.register(.init(chunks: [Data("[]".utf8)]), url: meetingsURL)
        let row = #"{"session_key":1,"year":2089,"date_start":"2089-10-04T13:00:00Z","session_name":"Race"}"#
        HTTPStub.register(.init(chunks: [Data("[\(row),\(row)]".utf8)]), url: sessionsURL)
        let unique = try await provider.sessions(year: year)
        #expect(unique.map(\.key) == [1])
        for invalid in [row.replacingOccurrences(of: "\"year\":2089", with: "\"year\":2090"),
                        row.replacingOccurrences(of: "\"year\":2089", with: "\"year\":2089.5"),
                        row.replacingOccurrences(of: "\"year\":2089", with: "\"year\":\"invalid\""),
                        row.replacingOccurrences(of: "\"year\":2089", with: "\"year\":null"),
                        row.replacingOccurrences(of: "\"session_key\":1", with: "\"session_key\":0"),
                        row.replacingOccurrences(of: "2089-10-04T13:00:00Z", with: "invalid")] {
            HTTPStub.register(.init(chunks: [Data("[\(invalid)]".utf8)]), url: sessionsURL)
            await #expect(throws: ProviderError.self) { try await provider.sessions(year: year, force: true) }
        }
        let withoutYear = row.replacingOccurrences(of: "\"year\":2089,", with: "")
        HTTPStub.register(.init(chunks: [Data("[\(withoutYear)]".utf8)]), url: sessionsURL)
        #expect(try await provider.sessions(year: year, force: true).first?.year == year)
        HTTPStub.register(.init(chunks: [Data("[]".utf8)]), url: sessionsURL)
        #expect(try await provider.sessions(year: year, force: true).isEmpty)
    }

    @Test func validEmptyJolpicaResponsesRemainUnavailableData() throws {
        let calendar = try JSONValue.decode(Data(#"{"MRData":{"RaceTable":{"season":"2026","Races":[]}}}"#.utf8))
        #expect(try ProviderDecoders.calendar(calendar, year: 2026).isEmpty)
        let standings = try JSONValue.decode(Data(#"{"MRData":{"StandingsTable":{"season":"2026","StandingsLists":[]}}}"#.utf8))
        let decoded = try ProviderDecoders.standings(standings, constructors: false, year: 2026)
        #expect(decoded.rows.isEmpty && decoded.round == nil)
        for value in [JSONValue.null, .object(["error": .string("unavailable")])] {
            #expect(throws: ProviderError.self) { try ProviderDecoders.calendar(value, year: 2026) }
            #expect(throws: ProviderError.self) { try ProviderDecoders.standings(value, constructors: false, year: 2026) }
        }
    }

    @Test func standingsRejectInvalidIdentityAndMeasuredValues() throws {
        let row = #"{"position":"1","points":"25","wins":"1","Driver":{"driverId":"test","givenName":"Test","familyName":"Driver"},"Constructors":[{"name":"Test Team"}]}"#
        func snapshot(_ rows: String, season: Int = 2026, round: Int = 1, constructors: Bool = false) throws -> JSONValue {
            let kind = constructors ? "ConstructorStandings" : "DriverStandings"
            return try JSONValue.decode(Data("{\"MRData\":{\"StandingsTable\":{\"season\":\"2026\",\"round\":\"1\",\"StandingsLists\":[{\"season\":\"\(season)\",\"round\":\"\(round)\",\"\(kind)\":[\(rows)]}]}}}".utf8))
        }
        let valid = try ProviderDecoders.standings(snapshot(row), constructors: false, year: 2026)
        #expect(valid.rows.count == 1 && valid.round == 1)
        #expect(throws: ProviderError.self) { try ProviderDecoders.standings(snapshot(row, season: 2025), constructors: false, year: 2026) }
        #expect(throws: ProviderError.self) { try ProviderDecoders.standings(snapshot(row, round: 2), constructors: false, year: 2026) }
        #expect(throws: ProviderError.self) { try ProviderDecoders.standings(snapshot(row + "," + row), constructors: false, year: 2026) }
        for invalid in [row.replacingOccurrences(of: "\"25\"", with: "\"NaN\""),
                        row.replacingOccurrences(of: "\"25\"", with: "\"bad\""),
                        row.replacingOccurrences(of: "\"driverId\":\"test\"", with: "\"driverId\":\"\"")] {
            #expect(throws: ProviderError.self) { try ProviderDecoders.standings(snapshot(invalid), constructors: false, year: 2026) }
        }
        let constructor = #"{"position":"1","points":"25","wins":"1","Constructor":{"constructorId":"test","name":"Test Team"}}"#
        #expect(try ProviderDecoders.standings(snapshot(constructor, constructors: true), constructors: true, year: 2026).rows.count == 1)
        for invalid in [constructor.replacingOccurrences(of: "\"25\"", with: "\"NaN\""),
                        constructor.replacingOccurrences(of: "\"constructorId\":\"test\"", with: "\"constructorId\":\"\"")] {
            #expect(throws: ProviderError.self) { try ProviderDecoders.standings(snapshot(invalid, constructors: true), constructors: true, year: 2026) }
        }
        let penalty = try ProviderDecoders.standings(snapshot(row.replacingOccurrences(of: "\"25\"", with: "\"-1\"")), constructors: false, year: 2026)
        #expect(penalty.rows.first?.points == -1)
    }

    @MainActor @Test func malformedStandingsRefreshPreservesDisplayedAndPersistedSnapshots() async throws {
        let responses = directory(), replays = directory(), year = 2088
        defer { try? FileManager.default.removeItem(at: responses); try? FileManager.default.removeItem(at: replays) }
        let http = ProviderHTTP(configuration: configuration(), directory: responses, rateLimits: [:])
        let provider = RaceProvider(replayDirectory: replays, http: http)
        let store = RaceStore(provider: provider)
        let driverURL = URL(string: "https://api.jolpi.ca/ergast/f1/\(year)/driverStandings.json?limit=100")!
        let constructorURL = URL(string: "https://api.jolpi.ca/ergast/f1/\(year)/constructorStandings.json?limit=100")!
        let driver = #""DriverStandings":[{"position":"1","points":"25","wins":"1","Driver":{"driverId":"test","givenName":"Test","familyName":"Driver"},"Constructors":[{"name":"Test Team"}]}]"#
        let constructor = #""ConstructorStandings":[{"position":"1","points":"25","wins":"1","Constructor":{"constructorId":"test","name":"Test Team"}}]"#
        for (url, rows) in [(driverURL, driver), (constructorURL, constructor)] {
            let payload = "{\"MRData\":{\"StandingsTable\":{\"season\":\"\(year)\",\"round\":\"1\",\"StandingsLists\":[{\"season\":\"\(year)\",\"round\":\"1\",\(rows)}]}}}"
            HTTPStub.register(.init(chunks: [Data(payload.utf8)]), url: url)
        }
        await store.refreshStandings(year: year)
        #expect(store.driverStandings.count == 1 && store.constructorStandings.count == 1)
        #expect(store.standingsRound == 1 && store.standingsError == nil)
        for url in [driverURL, constructorURL] {
            HTTPStub.register(.init(chunks: [Data(#"{"error":"unavailable"}"#.utf8)]), url: url)
        }
        await store.refreshStandings(year: year, force: true)
        #expect(store.driverStandings.count == 1 && store.constructorStandings.count == 1)
        #expect(store.standingsRound == 1 && store.standingsError != nil)
        for url in [driverURL, constructorURL] {
            HTTPStub.register(.init(status: 403, chunks: []), url: url)
        }
        let restartedHTTP = ProviderHTTP(configuration: configuration(), directory: responses, rateLimits: [:])
        let restarted = RaceProvider(replayDirectory: replays, http: restartedHTTP)
        let savedDrivers = try await restarted.standings(year: year, constructors: false)
        let savedConstructors = try await restarted.standings(year: year, constructors: true)
        #expect(savedDrivers.rows.first?.id == "test" && savedDrivers.round == 1)
        #expect(savedConstructors.rows.first?.id == "test" && savedConstructors.round == 1)
        #expect(HTTPStub.count(driverURL) == 0 && HTTPStub.count(constructorURL) == 0)
    }

    @Test func invalidCachedResponseRecoversThroughTypedDecoder() async throws {
        let responses = directory(), url = url()
        defer { try? FileManager.default.removeItem(at: responses) }
        let provider = ProviderHTTP(configuration: configuration(), directory: responses, rateLimits: [:])
        HTTPStub.register(.init(chunks: [Data(#"{"error":"unavailable"}"#.utf8)]), url: url)
        _ = try await provider.request(url)
        let calendar = #"{"MRData":{"RaceTable":{"season":"2026","Races":[{"season":"2026","round":"1","raceName":"Test Grand Prix","date":"2026-10-04"}]}}}"#
        HTTPStub.register(.init(chunks: [Data(calendar.utf8)]), url: url)
        let recovered = try await provider.request(url) { try ProviderDecoders.calendar($0, year: 2026) }
        #expect(recovered.count == 1 && HTTPStub.count(url) == 1)
        let restarted = ProviderHTTP(configuration: configuration(), directory: responses, rateLimits: [:])
        let saved = try await restarted.request(url) { try ProviderDecoders.calendar($0, year: 2026) }
        #expect(saved.count == 1 && HTTPStub.count(url) == 1)
    }

    @Test func cancellationAfterDecodingCannotReplaceValidatedResponseCache() async throws {
        let responses = directory(), url = url()
        defer { try? FileManager.default.removeItem(at: responses) }
        let provider = ProviderHTTP(configuration: configuration(), directory: responses, rateLimits: [:])
        HTTPStub.register(.init(chunks: [Data("[1]".utf8)]), url: url)
        _ = try await provider.request(url)
        HTTPStub.register(.init(chunks: [Data("[2]".utf8)]), url: url)
        let refresh = Task {
            try await provider.request(url, maxAge: 0) { value in
                withUnsafeCurrentTask { $0?.cancel() }
                return value
            }
        }
        await #expect(throws: CancellationError.self) { try await refresh.value }
        let restarted = ProviderHTTP(configuration: configuration(), directory: responses, rateLimits: [:])
        #expect(try await restarted.request(url).array.first?.int == 1)
        #expect(HTTPStub.count(url) == 1)
    }
}
