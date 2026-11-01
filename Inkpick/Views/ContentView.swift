import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(LibraryModel.self) private var model
    @State private var isImporterPresented = false

    private var importTypes: [UTType] {
        var types: [UTType] = [.pdf]
        if let epub = UTType(filenameExtension: "epub") {
            types.append(epub)
        }
        return types
    }

    var body: some View {
        NavigationSplitView {
            LibrarySidebar()
        } content: {
            PagePreview()
                .navigationTitle(model.selectedItem?.visibleName ?? "Inkpick")
        } detail: {
            TranscriptPane()
        }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    Task { await model.refresh() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .help("Reload notes from the reMarkable")

                Button {
                    isImporterPresented = true
                } label: {
                    Label("Upload", systemImage: "square.and.arrow.up")
                }
                .disabled(model.connection != .connected)
                .help("Upload a PDF or EPUB")

                Button {
                    model.savePDF()
                } label: {
                    Label("Save PDF", systemImage: "square.and.arrow.down")
                }
                .disabled(model.pdfDocument == nil)
            }

            ToolbarItemGroup {
                Button {
                    model.copyCurrentPage()
                } label: {
                    Label("Copy Page", systemImage: "doc.on.doc")
                }
                .disabled(model.pdfDocument == nil)
                .help("Copy this page as an image and a PDF")

                Button {
                    model.copyVisibleTranscript()
                } label: {
                    Label("Copy Text", systemImage: "text.quote")
                }
                .disabled(model.visibleTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help("Copy the transcript")

                Button {
                    model.transcribeDocument()
                } label: {
                    Label("Transcribe", systemImage: "text.viewfinder")
                }
                .disabled(model.pdfDocument == nil || model.isTranscribing)
                .help("Turn handwriting on every page into text on this Mac")
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let banner = model.banner {
                bannerView(banner)
            }
        }
        .fileImporter(
            isPresented: $isImporterPresented,
            allowedContentTypes: importTypes,
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                Task { await model.importFile(from: url) }
            case .failure:
                model.banner = StatusBanner(style: .error, text: "Could not open that file.")
            }
        }
        .task {
            await model.refresh()
        }
    }

    private func bannerView(_ banner: StatusBanner) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Image(systemName: banner.style == .error ? "exclamationmark.triangle" : "checkmark.circle")
            Text(banner.text)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                model.banner = nil
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(banner.style == .error ? Color.orange.opacity(0.18) : Color.green.opacity(0.16))
    }
}
