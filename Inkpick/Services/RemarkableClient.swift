import Foundation

enum RemarkableClientError: Error, Equatable {
    case badStatus(Int)
    case notAPDF
    case notAnArchive
    case unreadable
    case invalidResponse
}

struct RemarkableClient: Sendable {
    static let baseURL = URL(string: "http://10.11.99.1")!

    var session: URLSession
    private let gate = RequestGate()

    static let shared = RemarkableClient(
        session: URLSessionFactory.make(requestTimeout: 25, resourceTimeout: 180)
    )

    func cancelOutstanding() async {
        await cancelTasks(on: session)
    }

    func list(folderID: String?) async throws -> [RemarkableItem] {
        let path = folderID.map { "documents/\($0)" } ?? "documents/"
        let data = try await get(Self.url(for: path), highPriority: true)
        return try Self.decodeItems(from: data)
    }

    func thumbnail(id: String) async throws -> Data {
        try await get(Self.url(for: "thumbnail/\(id)"), highPriority: false)
    }

    func search(keyword: String) async throws -> [RemarkableItem] {
        try await gate.withPermit(highPriority: true) {
            var request = URLRequest(url: Self.searchURL(keyword: keyword))
            request.httpMethod = "POST"
            request.timeoutInterval = 20
            request.setValue("*/*", forHTTPHeaderField: "Accept")
            let (data, response) = try await self.send(request)
            try Self.validate(response)
            return try Self.decodeItems(from: data)
        }
    }

    /// Lists the destination folder first. The tablet uploads into the last folder it listed.
    func upload(fileURL: URL, listingFolderID: String?) async throws {
        _ = try await list(folderID: listingFolderID)
        try await postFile(fileURL)
    }

    /// The note archive already stored on the tablet. The tablet does not render it.
    func downloadNotebook(id: String, to destination: URL) async throws {
        try await download(
            Self.url(for: "download/\(id)/rmdoc"),
            to: destination,
            expecting: Data([0x50, 0x4B, 0x03, 0x04])
        )
    }

    static func url(for path: String) -> URL {
        URL(string: "http://10.11.99.1/\(path)")!
    }

    static func searchURL(keyword: String) -> URL {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/")
        let encoded = keyword.addingPercentEncoding(withAllowedCharacters: allowed) ?? keyword
        return url(for: "search/\(encoded)")
    }

    static func decodeItems(from data: Data) throws -> [RemarkableItem] {
        let trimmed = data.trimmingWhitespace()
        if trimmed.isEmpty || trimmed == Data("null".utf8) {
            return []
        }
        do {
            return try JSONDecoder().decode([RemarkableItem].self, from: trimmed)
        } catch {
            throw RemarkableClientError.invalidResponse
        }
    }

    private func get(_ url: URL, highPriority: Bool) async throws -> Data {
        try await gate.withPermit(highPriority: highPriority) {
            var request = URLRequest(url: url)
            request.timeoutInterval = 20
            request.setValue("*/*", forHTTPHeaderField: "Accept")
            let (data, response) = try await self.send(request)
            try Self.validate(response)
            return data
        }
    }

    private func download(_ url: URL, to destination: URL, expecting magic: Data) async throws {
        try await gate.withPermit(highPriority: true) {
            var request = URLRequest(url: url)
            request.timeoutInterval = 120
            request.setValue("*/*", forHTTPHeaderField: "Accept")
            request.setValue("http://10.11.99.1/", forHTTPHeaderField: "Referer")
            // Same session as every other call, so a thumbnail cannot run beside this download.
            let (temporary, response) = try await self.sendOnce(request)
            do {
                try Self.validate(response)
                guard Self.fileStarts(temporary, with: magic) else {
                    throw RemarkableClientError.notAnArchive
                }
                let directory = destination.deletingLastPathComponent()
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.moveItem(at: temporary, to: destination)
            } catch {
                try? FileManager.default.removeItem(at: temporary)
                throw error
            }
        }
    }

    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw RemarkableClientError.invalidResponse
        }
        return (data, http)
    }

    /// One attempt. A retry after the tablet says it is busy is what leaves the web server stuck.
    private func sendOnce(_ request: URLRequest) async throws -> (URL, HTTPURLResponse) {
        let (temporary, response) = try await session.download(for: request)
        guard let http = response as? HTTPURLResponse else {
            try? FileManager.default.removeItem(at: temporary)
            throw RemarkableClientError.invalidResponse
        }
        return (temporary, http)
    }

    private func postFile(_ fileURL: URL) async throws {
        let filename = fileURL.lastPathComponent.replacingOccurrences(of: "\"", with: "")
        let mimeType = fileURL.pathExtension.lowercased() == "epub"
            ? "application/epub+zip"
            : "application/pdf"
        let fileData = try Data(contentsOf: fileURL)
        let boundary = "Inkpick\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"

        var body = Data()
        body.appendUTF8("--\(boundary)\r\n")
        body.appendUTF8(
            "Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n"
        )
        body.appendUTF8("Content-Type: \(mimeType)\r\n\r\n")
        body.append(fileData)
        body.appendUTF8("\r\n--\(boundary)--\r\n")

        var request = URLRequest(url: Self.url(for: "upload"))
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("http://10.11.99.1", forHTTPHeaderField: "Origin")
        request.setValue("http://10.11.99.1/", forHTTPHeaderField: "Referer")
        request.httpBody = body

        let uploadRequest = request
        let (_, response) = try await gate.withPermit(highPriority: true) {
            try await self.send(uploadRequest)
        }
        try Self.validate(response)
    }

    private func cancelTasks(on session: URLSession) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            session.getAllTasks { tasks in
                for task in tasks {
                    task.cancel()
                }
                continuation.resume()
            }
        }
    }

    private static func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw RemarkableClientError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw RemarkableClientError.badStatus(http.statusCode)
        }
    }

    private static func fileStarts(_ url: URL, with magic: Data) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let header = (try? handle.read(upToCount: magic.count)) ?? Data()
        return header.starts(with: magic)
    }
}

enum URLSessionFactory {
    static func make(requestTimeout: TimeInterval, resourceTimeout: TimeInterval) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = resourceTimeout
        configuration.waitsForConnectivity = false
        configuration.httpMaximumConnectionsPerHost = 1
        return URLSession(configuration: configuration)
    }
}

private final class RequestGate: @unchecked Sendable {
    private let lock = NSLock()
    private var busy = false
    private var high: [CheckedContinuation<Void, Error>] = []
    private var low: [CheckedContinuation<Void, Error>] = []

    func withPermit<T: Sendable>(
        highPriority: Bool,
        _ operation: @Sendable () async throws -> T
    ) async throws -> T {
        try await acquire(highPriority: highPriority)
        do {
            let value = try await operation()
            release()
            return value
        } catch {
            release()
            throw error
        }
    }

    private func acquire(highPriority: Bool) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            lock.lock()
            if !busy {
                busy = true
                lock.unlock()
                continuation.resume()
            } else if highPriority {
                high.append(continuation)
                lock.unlock()
            } else {
                low.append(continuation)
                lock.unlock()
            }
        }
    }

    private func release() {
        lock.lock()
        if !high.isEmpty {
            let next = high.removeFirst()
            lock.unlock()
            next.resume()
        } else if !low.isEmpty {
            let next = low.removeFirst()
            lock.unlock()
            next.resume()
        } else {
            busy = false
            lock.unlock()
        }
    }
}

private extension Data {
    func trimmingWhitespace() -> Data {
        var bytes = self
        let whitespace = Set(" \n\r\t".utf8)
        while let first = bytes.first, whitespace.contains(first) {
            bytes.removeFirst()
        }
        while let last = bytes.last, whitespace.contains(last) {
            bytes.removeLast()
        }
        return bytes
    }

    mutating func appendUTF8(_ string: String) {
        append(Data(string.utf8))
    }
}
