import Foundation

final class BoundedHTTPTransport: @unchecked Sendable {
    private let delegate = ResponseDelegate()
    private let session: URLSession

    init(configuration: URLSessionConfiguration) {
        session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }
    deinit { session.invalidateAndCancel() }
    func cancel() { session.invalidateAndCancel() }

    static func allowsRedirect(from original: URL?, to proposed: URL?) -> Bool {
        guard let original, let proposed else { return false }
        return proposed.scheme == "https" && proposed.host == original.host && proposed.user == nil
            && proposed.password == nil && (proposed.port == nil || proposed.port == 443)
            && (original.host != "livetiming.formula1.com" || ProviderHTTP.isProviderURL(proposed))
    }

    func data(for request: URLRequest, maximumBytes: Int) async throws -> (Data, HTTPURLResponse) {
        try Task.checkCancellation()
        let transfer = Transfer(maximumBytes: maximumBytes)
        let result = try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                let task = session.dataTask(with: request)
                delegate.register(transfer, for: task)
                if transfer.start(task, continuation: continuation) { task.resume() }
                else { delegate.remove(task); task.cancel() }
            }
        }, onCancel: { transfer.cancel() })
        try Task.checkCancellation()
        return result
    }

    private final class ResponseDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private var transfers: [Int: Transfer] = [:]

        func register(_ transfer: Transfer, for task: URLSessionTask) {
            lock.lock(); transfers[task.taskIdentifier] = transfer; lock.unlock()
        }
        func remove(_ task: URLSessionTask) {
            lock.lock(); transfers[task.taskIdentifier] = nil; lock.unlock()
        }
        private func transfer(_ task: URLSessionTask) -> Transfer? {
            lock.lock(); defer { lock.unlock() }; return transfers[task.taskIdentifier]
        }
        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            completionHandler(transfer(dataTask)?.receive(response) == true ? .allow : .cancel)
        }
        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            transfer(dataTask)?.append(data)
        }
        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            transfer(task)?.complete(error); remove(task)
        }
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            let allowed = BoundedHTTPTransport.allowsRedirect(from: task.originalRequest?.url, to: request.url)
            completionHandler(allowed ? request : nil)
        }
    }

    private final class Transfer: @unchecked Sendable {
        private let lock = NSLock()
        private let maximumBytes: Int
        private var continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>?
        private var task: URLSessionTask?
        private var response: HTTPURLResponse?
        private var bytes = Data()
        private var cancelled = false

        init(maximumBytes: Int) { self.maximumBytes = maximumBytes }
        func start(_ task: URLSessionTask, continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>) -> Bool {
            lock.lock()
            if cancelled { lock.unlock(); continuation.resume(throwing: CancellationError()); return false }
            self.task = task; self.continuation = continuation
            lock.unlock(); return true
        }
        func cancel() {
            lock.lock(); cancelled = true; let task = task; lock.unlock()
            finish(.failure(CancellationError())); task?.cancel()
        }
        func receive(_ value: URLResponse) -> Bool {
            guard let value = value as? HTTPURLResponse else {
                finish(.failure(ProviderError.invalidData("The provider returned an unreadable response."))); return false
            }
            lock.lock(); response = value; let active = continuation != nil; lock.unlock()
            guard active else { return false }
            if !(200..<300).contains(value.statusCode) { finish(.success((Data(), value))); return false }
            guard value.expectedContentLength <= maximumBytes else { finish(.failure(oversized)); return false }
            return true
        }
        func append(_ data: Data) {
            lock.lock()
            guard continuation != nil else { lock.unlock(); return }
            if data.count > maximumBytes - bytes.count {
                let task = task; lock.unlock(); finish(.failure(oversized)); task?.cancel(); return
            }
            bytes.append(data); lock.unlock()
        }
        func complete(_ error: Error?) {
            lock.lock(); let response = response, bytes = bytes; lock.unlock()
            if let error { finish(.failure(error)) }
            else if let response { finish(.success((bytes, response))) }
            else { finish(.failure(ProviderError.invalidData("The provider returned an unreadable response."))) }
        }
        private var oversized: ProviderError { .invalidData("The provider response is too large. Try a smaller time range.") }
        private func finish(_ result: Result<(Data, HTTPURLResponse), Error>) {
            lock.lock(); let continuation = continuation; self.continuation = nil; bytes = Data(); lock.unlock()
            continuation?.resume(with: result)
        }
    }
}
