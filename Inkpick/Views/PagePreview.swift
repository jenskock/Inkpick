import PDFKit
import SwiftUI

struct PagePreview: View {
    @Environment(LibraryModel.self) private var model
    @State private var pageDraft = ""
    @FocusState private var pageFieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            preview
            if model.pdfDocument != nil {
                pageBar
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private var preview: some View {
        if model.isLoadingDocument, model.pdfDocument == nil {
            ProgressView("Opening note…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let document = model.pdfDocument {
            PDFKitView(document: document, pageIndex: model.currentPageIndex)
                .focusable()
                .onKeyPress(.leftArrow) {
                    model.goToPreviousPage()
                    return .handled
                }
                .onKeyPress(.rightArrow) {
                    model.goToNextPage()
                    return .handled
                }
                .onChange(of: model.currentPageIndex) { _, _ in
                    syncPageDraft()
                }
        } else if model.connection == .disconnected {
            disconnected
        } else if model.selectedDocumentID != nil, model.banner?.style == .error {
            failedOpen
        } else if model.selectedDocumentID != nil {
            ProgressView("Opening note…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.connection == .checking {
            ProgressView("Looking for the reMarkable…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView(
                "Select a note",
                systemImage: "note.text",
                description: Text("Choose a notebook or document in the sidebar.")
            )
        }
    }

    private var disconnected: some View {
        ContentUnavailableView {
            Label("Plug in the reMarkable", systemImage: "cable.connector")
        } description: {
            Text("Connect the USB cable. On the tablet, open Settings, Storage, and turn on USB web interface. The tablet needs to be awake and unlocked. Turn the web interface off when you are finished.")
        } actions: {
            Button("Try again") {
                Task { await model.refresh() }
            }
        }
    }

    private var failedOpen: some View {
        ContentUnavailableView {
            Label("This note did not open", systemImage: "exclamationmark.triangle")
        } description: {
            Text(model.banner?.text ?? "The reMarkable did not send the page.")
        } actions: {
            Button("Try again") {
                guard let id = model.selectedDocumentID else { return }
                Task { await model.open(id: id) }
            }
        }
    }

    private var pageBar: some View {
        HStack(spacing: 10) {
            Button {
                model.goToFirstPage()
            } label: {
                Image(systemName: "backward.end")
            }
            .disabled(model.currentPageIndex == 0)
            .help("First page")
            .accessibilityLabel("First page")

            Button {
                model.goToPreviousPage()
            } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(model.currentPageIndex == 0)
            .help("Previous page")
            .accessibilityLabel("Previous page")

            HStack(spacing: 6) {
                TextField("Page", text: $pageDraft)
                    .focused($pageFieldFocused)
                    .frame(width: 44)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(commitPageDraft)
                Text("of \(model.pageCount)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            Button {
                model.goToNextPage()
            } label: {
                Image(systemName: "chevron.right")
            }
            .disabled(model.currentPageIndex >= model.pageCount - 1)
            .help("Next page")
            .accessibilityLabel("Next page")

            Button {
                model.goToLastPage()
            } label: {
                Image(systemName: "forward.end")
            }
            .disabled(model.currentPageIndex >= model.pageCount - 1)
            .help("Last page")
            .accessibilityLabel("Last page")

            if let stamp = model.currentPageStamp {
                Text(stamp.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(.bar)
        .onAppear(perform: syncPageDraft)
    }

    private func syncPageDraft() {
        guard !pageFieldFocused else { return }
        pageDraft = model.pageCount == 0 ? "" : "\(model.currentPageIndex + 1)"
    }

    private func commitPageDraft() {
        guard let number = Int(pageDraft.trimmingCharacters(in: .whitespaces)) else {
            syncPageDraft()
            return
        }
        model.goToPage(number - 1)
        pageDraft = "\(model.currentPageIndex + 1)"
    }
}

private struct PDFKitView: NSViewRepresentable {
    var document: PDFDocument
    var pageIndex: Int

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePage
        view.displaysPageBreaks = false
        view.backgroundColor = .windowBackgroundColor
        view.document = document
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        if view.document !== document {
            view.document = document
        }
        guard let page = document.page(at: pageIndex), view.currentPage != page else { return }
        view.go(to: page)
    }
}
