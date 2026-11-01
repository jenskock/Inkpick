import SwiftUI

struct TranscriptPane: View {
    @Environment(LibraryModel.self) private var model
    @AppStorage("recognitionLanguages") private var storedLanguages = ""
    @State private var draft = ""

    private static let supportedLanguages = LanguagePreferences.supportedRecognitionLanguages()

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 10) {
            Picker("Transcript", selection: $model.transcriptScope) {
                ForEach(TranscriptScope.allCases) { scope in
                    Text(scope.rawValue).tag(scope)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            languageMenu

            if model.isTranscribing, let progress = model.transcribeProgress {
                HStack {
                    ProgressView()
                        .controlSize(.small)
                    Text("Reading page \(progress.completed + 1) of \(progress.total)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Stop") {
                        model.cancelTranscription()
                    }
                    .controlSize(.small)
                }
            }

            Group {
                if model.transcriptScope == .page {
                    TextEditor(text: $draft)
                        .font(.body)
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .background(Color(nsColor: .textBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    ScrollView {
                        Text(model.wholeNoteTranscript.isEmpty ? "Transcribe the note to read every page." : model.wholeNoteTranscript)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .padding(8)
                    }
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Button("Transcribe this page") {
                model.transcribeCurrentPage()
            }
            .disabled(model.pdfDocument == nil || model.isTranscribing)
        }
        .padding(12)
        .navigationSplitViewColumnWidth(min: 260, ideal: 320, max: 440)
        .onAppear { reloadDraft() }
        .onChange(of: model.currentPageIndex) { _, _ in reloadDraft() }
        .onChange(of: model.transcriptRevision) { _, _ in reloadDraft() }
        .onChange(of: model.transcriptScope) { _, _ in reloadDraft() }
        .onChange(of: draft) { _, newValue in
            guard model.transcriptScope == .page else { return }
            model.setPageTranscript(newValue)
        }
    }

    private var languageMenu: some View {
        let supported = Self.supportedLanguages
        let selected = Set(LanguagePreferences.resolved(stored: storedLanguages))
        return Menu {
            ForEach(supported, id: \.self) { code in
                Button {
                    toggle(code)
                } label: {
                    if selected.contains(code) {
                        Label(displayName(code), systemImage: "checkmark")
                    } else {
                        Text(displayName(code))
                    }
                }
            }
        } label: {
            Label(languageSummary(selected: selected), systemImage: "character.book.closed")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private func toggle(_ code: String) {
        var selected = storedLanguages
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if selected.isEmpty {
            selected = LanguagePreferences.resolved(stored: "")
        }
        if let index = selected.firstIndex(of: code) {
            selected.remove(at: index)
        } else {
            selected.append(code)
        }
        storedLanguages = selected.joined(separator: ",")
    }

    private func languageSummary(selected: Set<String>) -> String {
        let names = selected.sorted().map(displayName)
        if names.isEmpty { return "Languages" }
        if names.count <= 2 { return names.joined(separator: ", ") }
        return "\(names.count) languages"
    }

    private func displayName(_ code: String) -> String {
        Locale.current.localizedString(forIdentifier: code) ?? code
    }

    private func reloadDraft() {
        let updated = model.pageTranscript
        if draft != updated {
            draft = updated
        }
    }
}
