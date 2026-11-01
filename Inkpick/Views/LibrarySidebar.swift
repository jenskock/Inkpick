import SwiftUI

struct LibrarySidebar: View {
    @Environment(LibraryModel.self) private var model
    @State private var query = ""

    var body: some View {
        VStack(spacing: 0) {
            connectionHeader
            searchField
            list
        }
        .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 380)
    }

    private var connectionHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle()
                .fill(connectionColor)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(connectionTitle)
                    .font(.headline)
                Text("10.11.99.1")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if model.isRefreshing {
                ProgressView()
                    .controlSize(.small)
            } else {
                Button {
                    Task { await model.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Look for the reMarkable again")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var searchField: some View {
        TextField("Search notes", text: $query)
            .textFieldStyle(.roundedBorder)
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
            .onChange(of: query) { _, newValue in
                model.scheduleSearch(newValue)
            }
    }

    @ViewBuilder
    private var list: some View {
        if let results = model.searchResults {
            if results.isEmpty {
                ContentUnavailableView(
                    "No matches",
                    systemImage: "magnifyingglass",
                    description: Text("No note title contains that search.")
                )
            } else {
                List(results, selection: selectedID) { item in
                    DocumentRow(item: item)
                        .tag(item.id)
                }
            }
        } else if model.rootNodes.isEmpty, model.connection == .connected {
            ContentUnavailableView(
                "No notes",
                systemImage: "tray",
                description: Text("This reMarkable has no documents yet. Upload a PDF or EPUB to add one.")
            )
        } else {
            List(selection: selectedID) {
                OutlineGroup(model.rootNodes, children: \.children) { node in
                    if node.item.isDocument {
                        DocumentRow(item: node.item)
                            .tag(node.item.id)
                    } else {
                        Label(node.item.visibleName, systemImage: "folder")
                    }
                }
            }
        }
    }

    private var selectedID: Binding<String?> {
        Binding(
            get: { model.selectedDocumentID },
            set: { newValue in
                model.selectedDocumentID = newValue
                guard let newValue else { return }
                Task { await model.open(id: newValue) }
            }
        )
    }

    private var connectionTitle: String {
        switch model.connection {
        case .checking:
            return "Looking for reMarkable"
        case .connected:
            return "USB connected"
        case .disconnected:
            return "USB not connected"
        }
    }

    private var connectionColor: Color {
        switch model.connection {
        case .checking:
            return .secondary
        case .connected:
            return .green
        case .disconnected:
            return .orange
        }
    }
}

private struct DocumentRow: View {
    @Environment(LibraryModel.self) private var model
    var item: RemarkableItem

    var body: some View {
        HStack(spacing: 8) {
            thumbnail
            VStack(alignment: .leading, spacing: 2) {
                Text(item.visibleName)
                    .lineLimit(1)
                Text(item.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let image = model.thumbnails[item.id] {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 28, height: 36)
                .clipShape(RoundedRectangle(cornerRadius: 3))
        } else {
            Image(systemName: item.symbolName)
                .frame(width: 28, height: 36)
                .foregroundStyle(.secondary)
        }
    }
}
