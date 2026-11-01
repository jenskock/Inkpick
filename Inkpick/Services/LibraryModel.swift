import AppKit
import Foundation
import PDFKit
import UniformTypeIdentifiers

struct LibraryNode: Identifiable, Hashable {
    var item: RemarkableItem
    var children: [LibraryNode]?

    var id: String { item.id }
}

struct StatusBanner: Equatable {
    enum Style: Equatable {
        case error
        case info
    }

    var style: Style
    var text: String
}

enum ConnectionState: Equatable {
    case checking
    case connected
    case disconnected
}

enum TranscriptScope: String, CaseIterable, Identifiable {
    case page = "This page"
    case wholeNote = "Whole note"

    var id: String { rawValue }
}

@MainActor
@Observable
final class LibraryModel {
    private(set) var connection: ConnectionState = .checking
    private(set) var isRefreshing = false
    private(set) var rootNodes: [LibraryNode] = []
    private(set) var searchResults: [RemarkableItem]?
    var selectedDocumentID: String?
    var currentPageIndex = 0
    var transcriptScope: TranscriptScope = .page
    private(set) var pdfDocument: PDFDocument?
    private(set) var transcripts: [Int: String] = [:]
    private(set) var pageStamps: [PageStamp?] = []
    private(set) var transcriptRevision = 0
    private(set) var isLoadingDocument = false
    private(set) var isTranscribing = false
    private(set) var transcribeProgress: (completed: Int, total: Int)?
    private(set) var thumbnails: [String: NSImage] = [:]
    var banner: StatusBanner?

    private let client: RemarkableClient
    private var cache: DocumentCache
    private var loadedDocumentID: String?
    private var loadedItem: RemarkableItem?
    private var openGeneration = 0
    private var searchTask: Task<Void, Never>?
    private var lastQuery: String?
    private var transcribeTask: Task<Void, Never>?
    private var thumbnailTasks: [String: Task<Void, Never>] = [:]

    var pageCount: Int { pdfDocument?.pageCount ?? 0 }

    var currentPageStamp: PageStamp? {
        guard pageStamps.indices.contains(currentPageIndex) else { return nil }
        return pageStamps[currentPageIndex]
    }

    var selectedItem: RemarkableItem? {
        guard let selectedDocumentID else { return nil }
        return findItem(id: selectedDocumentID, in: rootNodes)
    }

    var pageTranscript: String {
        transcripts[currentPageIndex] ?? ""
    }

    var wholeNoteTranscript: String {
        guard pageCount > 0 else { return "" }
        return (0..<pageCount).map { index in
            let body = transcripts[index]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if pageCount == 1 {
                return body
            }
            return body.isEmpty ? "Page \(index + 1)" : "Page \(index + 1)\n\(body)"
        }
        .joined(separator: "\n\n")
    }

    var visibleTranscript: String {
        switch transcriptScope {
        case .page:
            return pageTranscript
        case .wholeNote:
            return wholeNoteTranscript
        }
    }

    init(client: RemarkableClient = .shared, cache: DocumentCache? = nil) {
        self.client = client
        if let cache {
            self.cache = cache
        } else if let support = try? DocumentCache.makeDefault() {
            self.cache = support
        } else {
            let temporary = FileManager.default.temporaryDirectory
                .appendingPathComponent("Inkpick", isDirectory: true)
            try? FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
            self.cache = DocumentCache(root: temporary)
        }
    }

    func refresh() async {
        await client.cancelOutstanding()
        isRefreshing = true
        defer { isRefreshing = false }
        if connection != .connected {
            connection = .checking
        }
        do {
            let root = try await client.list(folderID: nil)
            rootNodes = Self.nodes(from: root)
            connection = .connected
            banner = nil
            rootNodes = try await loadChildren(of: root)
            if let selectedDocumentID, findItem(id: selectedDocumentID, in: rootNodes) == nil {
                self.selectedDocumentID = nil
                clearOpenDocument()
            }
            if let lastQuery, !lastQuery.isEmpty {
                await performSearch(lastQuery)
            }
        } catch {
            if rootNodes.isEmpty {
                connection = .disconnected
            }
            banner = StatusBanner(style: .error, text: Self.message(for: error))
        }
    }

    func scheduleSearch(_ query: String) {
        searchTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            lastQuery = nil
            searchResults = nil
            return
        }
        searchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            await self?.performSearch(trimmed)
        }
    }

    func open(id: String) async {
        guard let item = findItem(id: id, in: rootNodes), item.isDocument else { return }
        guard loadedDocumentID != id || pdfDocument == nil else { return }

        openGeneration += 1
        let generation = openGeneration
        for task in thumbnailTasks.values {
            task.cancel()
        }
        thumbnailTasks.removeAll()
        isLoadingDocument = true
        banner = nil
        pdfDocument = nil
        transcripts = [:]
        pageStamps = []
        currentPageIndex = 0

        do {
            let opened = try await ensurePDF(for: item)
            guard generation == openGeneration else { return }
            guard let document = PDFDocument(url: opened.url) else {
                throw RemarkableClientError.notAPDF
            }
            pageStamps = opened.stamps
            if Self.opensOnLastPage(item), document.pageCount > 0 {
                currentPageIndex = document.pageCount - 1
            } else {
                currentPageIndex = 0
            }
            pdfDocument = document
            loadedDocumentID = id
            loadedItem = item
            let saved = cache.loadTranscript(for: item)
            if saved.isEmpty {
                transcripts = opened.pageText
                if !transcripts.isEmpty {
                    persistTranscript()
                }
            } else {
                transcripts = saved
            }
            transcriptRevision += 1
        } catch {
            guard generation == openGeneration else { return }
            clearOpenDocument()
            banner = StatusBanner(style: .error, text: Self.message(for: error))
        }

        if generation == openGeneration {
            isLoadingDocument = false
        }
    }

    func loadThumbnail(id: String) {
        guard !isLoadingDocument else { return }
        guard thumbnails[id] == nil, thumbnailTasks[id] == nil else { return }
        thumbnailTasks[id] = Task { [weak self] in
            guard let self else { return }
            defer { self.thumbnailTasks[id] = nil }
            guard let data = try? await self.client.thumbnail(id: id),
                  let image = NSImage(data: data) else {
                return
            }
            self.thumbnails[id] = image
        }
    }

    func goToFirstPage() {
        currentPageIndex = 0
    }

    func goToPreviousPage() {
        currentPageIndex = max(0, currentPageIndex - 1)
    }

    func goToNextPage() {
        guard pageCount > 0 else { return }
        currentPageIndex = min(pageCount - 1, currentPageIndex + 1)
    }

    func goToLastPage() {
        guard pageCount > 0 else { return }
        currentPageIndex = pageCount - 1
    }

    func goToPage(_ index: Int) {
        guard pageCount > 0 else { return }
        currentPageIndex = min(max(0, index), pageCount - 1)
    }

    func setPageTranscript(_ text: String) {
        guard pdfDocument != nil else { return }
        guard (transcripts[currentPageIndex] ?? "") != text else { return }
        transcripts[currentPageIndex] = text
        persistTranscript()
    }

    func importFile(from url: URL) async {
        let accessing = url.startAccessingSecurityScopedResource()
        defer {
            if accessing {
                url.stopAccessingSecurityScopedResource()
            }
        }
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(url.pathExtension)
        do {
            try FileManager.default.copyItem(at: url, to: temporary)
        } catch {
            banner = StatusBanner(style: .error, text: "Could not read the selected file.")
            return
        }
        defer { try? FileManager.default.removeItem(at: temporary) }
        await upload(fileURL: temporary, displayName: url.deletingPathExtension().lastPathComponent)
    }

    func savePDF() {
        guard let item = loadedItem, let source = existingPDFURL(for: item) else {
            banner = StatusBanner(style: .error, text: "Open a note before saving a PDF.")
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = Self.filename(for: item.visibleName) + ".pdf"
        panel.begin { [weak self] response in
            Task { @MainActor in
                guard let self, response == .OK, let destination = panel.url else { return }
                do {
                    if FileManager.default.fileExists(atPath: destination.path) {
                        try FileManager.default.removeItem(at: destination)
                    }
                    try FileManager.default.copyItem(at: source, to: destination)
                    self.banner = StatusBanner(style: .info, text: "Saved \(destination.lastPathComponent).")
                } catch {
                    self.banner = StatusBanner(style: .error, text: "Could not save the PDF.")
                }
            }
        }
    }

    func copyCurrentPage() {
        guard let pdfDocument, let page = pdfDocument.page(at: currentPageIndex) else {
            banner = StatusBanner(style: .error, text: "Open a note before copying a page.")
            return
        }
        do {
            let image = try PageRenderer.image(of: page)
            ClipboardService.copyPage(image: image, pdfPage: page)
            banner = StatusBanner(style: .info, text: "Copied page \(currentPageIndex + 1).")
        } catch {
            banner = StatusBanner(style: .error, text: "Could not copy this page.")
        }
    }

    func copyVisibleTranscript() {
        let text = visibleTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            banner = StatusBanner(style: .error, text: "Transcribe the note before copying text.")
            return
        }
        ClipboardService.copyText(visibleTranscript)
        banner = StatusBanner(style: .info, text: "Copied text.")
    }

    func transcribeDocument() {
        guard pageCount > 0 else {
            banner = StatusBanner(style: .error, text: "Open a note before transcribing.")
            return
        }
        beginTranscription(pages: Array(0..<pageCount))
    }

    func transcribeCurrentPage() {
        guard pageCount > 0 else {
            banner = StatusBanner(style: .error, text: "Open a note before transcribing.")
            return
        }
        beginTranscription(pages: [currentPageIndex])
    }

    func cancelTranscription() {
        transcribeTask?.cancel()
        transcribeTask = nil
        isTranscribing = false
        transcribeProgress = nil
    }

    private func beginTranscription(pages: [Int]) {
        transcribeTask?.cancel()
        let languages = LanguagePreferences.resolved(
            stored: UserDefaults.standard.string(forKey: "recognitionLanguages") ?? ""
        )
        transcribeTask = Task { [weak self] in
            await self?.runTranscription(pages: pages, languages: languages)
        }
    }

    private func runTranscription(pages: [Int], languages: [String]) async {
        guard let pdfDocument else { return }
        isTranscribing = true
        banner = nil
        let total = pages.count
        for (offset, index) in pages.enumerated() {
            if Task.isCancelled { break }
            transcribeProgress = (offset, total)
            guard let page = pdfDocument.page(at: index) else { continue }
            do {
                let text: String
                if let layer = PageRenderer.textLayer(of: page) {
                    text = layer
                } else {
                    let image = try PageRenderer.image(of: page)
                    text = try await HandwritingRecognizer.recognize(image: image, languages: languages)
                }
                if Task.isCancelled { break }
                transcripts[index] = text
                transcriptRevision += 1
                persistTranscript()
            } catch {
                if Task.isCancelled { break }
                banner = StatusBanner(style: .error, text: "Could not read page \(index + 1).")
            }
        }
        isTranscribing = false
        transcribeProgress = nil
    }

    private func performSearch(_ query: String) async {
        lastQuery = query
        guard connection == .connected else {
            searchResults = nil
            return
        }
        var remote: [RemarkableItem] = []
        if let found = try? await client.search(keyword: query) {
            remote = found.filter(\.isDocument)
        }
        let local = flatten(rootNodes).filter { item in
            item.isDocument && item.visibleName.localizedStandardContains(query)
        }
        var seen = Set<String>()
        let combined = (remote + local).filter { seen.insert($0.id).inserted }
        searchResults = combined
    }

    private func upload(fileURL: URL, displayName: String) async {
        let folderID = uploadFolderID
        let before = Set(flatten(rootNodes).map(\.id))
        do {
            try await client.upload(fileURL: fileURL, listingFolderID: folderID)
            let root = try await client.list(folderID: nil)
            rootNodes = try await loadChildren(of: root)
            connection = .connected
            let created = flatten(rootNodes).filter { !before.contains($0.id) }
            banner = StatusBanner(
                style: .info,
                text: uploadMessage(created: created, folderID: folderID, displayName: displayName)
            )
        } catch {
            banner = StatusBanner(style: .error, text: Self.message(for: error))
        }
    }

    private var uploadFolderID: String? {
        guard let parent = selectedItem?.parent, !parent.isEmpty else { return nil }
        return parent
    }

    private func uploadMessage(
        created: [RemarkableItem],
        folderID: String?,
        displayName: String
    ) -> String {
        let target = folderID ?? ""
        guard let item = created.first(where: {
            $0.visibleName.compare(displayName, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }) ?? created.first else {
            return "The tablet accepted the file. It did not appear in the library yet."
        }
        let landed = item.parent
        if landed == target {
            return "Uploaded \(item.visibleName) to \(folderName(target))."
        }
        return "The tablet saved \(item.visibleName) in \(folderName(landed))."
    }

    private func folderName(_ id: String) -> String {
        if id.isEmpty { return "My files" }
        return findItem(id: id, in: rootNodes)?.visibleName ?? "another folder"
    }

    private func ensurePDF(for item: RemarkableItem) async throws -> (url: URL, pageText: [Int: String], stamps: [PageStamp?]) {
        let destination = cache.pdfURL(for: item)
        // A saved note opens from disk. Asking the tablet again wedges its web server.
        if FileManager.default.fileExists(atPath: destination.path) {
            let stamps = cache.hasPageStamps(for: item) ? cache.loadPageStamps(for: item) : []
            return (destination, [:], stamps)
        }
        let rendered = try await downloadNotebook(for: item, to: destination)
        return (destination, rendered.pageText, rendered.pageStamps)
    }

    private func downloadNotebook(for item: RemarkableItem, to destination: URL) async throws -> RenderedNote {
        let archive = destination.appendingPathExtension("rmdoc")
        defer { try? FileManager.default.removeItem(at: archive) }
        try await client.downloadNotebook(id: item.id, to: archive)
        let bytes = try Data(contentsOf: archive)
        let rendered: RenderedNote
        do {
            rendered = try await Task.detached(priority: .userInitiated) {
                try NoteArchive.render(archive: bytes)
            }.value
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw RemarkableClientError.unreadable
        }
        try rendered.pdfData.write(to: destination, options: .atomic)
        try? cache.savePageStamps(rendered.pageStamps, for: item)
        return rendered
    }

    private static func opensOnLastPage(_ item: RemarkableItem) -> Bool {
        item.fileType != "pdf" && item.fileType != "epub"
    }

    private func existingPDFURL(for item: RemarkableItem) -> URL? {
        let url = cache.pdfURL(for: item)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private func persistTranscript() {
        guard let loadedItem else { return }
        try? cache.saveTranscript(transcripts, for: loadedItem)
    }

    private func clearOpenDocument() {
        pdfDocument = nil
        transcripts = [:]
        pageStamps = []
        loadedDocumentID = nil
        loadedItem = nil
        currentPageIndex = 0
    }

    private func loadChildren(of items: [RemarkableItem]) async throws -> [LibraryNode] {
        var nodes: [LibraryNode] = []
        for item in items.sorted(by: Self.libraryOrder) {
            if item.isFolder {
                let children = (try? await client.list(folderID: item.id)) ?? []
                let childNodes = try await loadChildren(of: children)
                nodes.append(LibraryNode(item: item, children: childNodes))
            } else {
                nodes.append(LibraryNode(item: item, children: nil))
            }
        }
        return nodes
    }

    private func flatten(_ nodes: [LibraryNode]) -> [RemarkableItem] {
        nodes.flatMap { node in
            [node.item] + flatten(node.children ?? [])
        }
    }

    private func findItem(id: String, in nodes: [LibraryNode]) -> RemarkableItem? {
        for node in nodes {
            if node.item.id == id { return node.item }
            if let children = node.children, let found = findItem(id: id, in: children) {
                return found
            }
        }
        return nil
    }

    private static func nodes(from items: [RemarkableItem]) -> [LibraryNode] {
        items.sorted(by: libraryOrder).map { item in
            LibraryNode(item: item, children: item.isFolder ? [] : nil)
        }
    }

    private static func libraryOrder(_ lhs: RemarkableItem, _ rhs: RemarkableItem) -> Bool {
        if lhs.isFolder != rhs.isFolder {
            return lhs.isFolder
        }
        return lhs.visibleName.localizedCaseInsensitiveCompare(rhs.visibleName) == .orderedAscending
    }

    static func message(for error: Error) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut:
                return "The reMarkable did not respond. Wake it, unlock it, and leave the USB web interface on."
            case .cannotConnectToHost, .networkConnectionLost, .cannotFindHost, .notConnectedToInternet, .dnsLookupFailed, .cannotLoadFromNetwork:
                return "Cannot reach the reMarkable at 10.11.99.1. Plug in the USB cable and turn on Settings → Storage → USB web interface."
            default:
                break
            }
        }
        if let clientError = error as? RemarkableClientError {
            switch clientError {
            case .notAPDF, .unreadable:
                return "Inkpick could not read this note."
            case .notAnArchive:
                return "The tablet did not return this note. Turn the USB web interface off and on, then open it again."
            case .badStatus(408):
                return "The reMarkable was busy and did not send this note. Open it again. If this keeps happening, turn the USB web interface off and on."
            case .badStatus, .invalidResponse:
                return "The reMarkable rejected the request. Check that the USB web interface is on."
            }
        }
        return "Could not reach the reMarkable over USB. Plug in the cable and turn on the USB web interface."
    }

    private static func filename(for title: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let cleaned = title
            .components(separatedBy: invalid)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Note" : cleaned
    }
}
