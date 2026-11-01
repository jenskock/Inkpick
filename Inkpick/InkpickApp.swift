import SwiftUI

@main
struct InkpickApp: App {
    @State private var model = LibraryModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
                .frame(minWidth: 860, minHeight: 560)
        }
        .defaultSize(width: 1120, height: 740)
        .commands {
            CommandGroup(after: .pasteboard) {
                Button("Copy Page") {
                    model.copyCurrentPage()
                }
                .keyboardShortcut("c", modifiers: [.command, .shift])

                Button("Copy Text") {
                    model.copyVisibleTranscript()
                }
                .keyboardShortcut("c", modifiers: [.command, .option])
            }
            CommandGroup(after: .sidebar) {
                Button("Refresh Library") {
                    Task { await model.refresh() }
                }
                .keyboardShortcut("r", modifiers: .command)

                Button("Transcribe Note") {
                    model.transcribeDocument()
                }
                .keyboardShortcut("t", modifiers: [.command, .shift])

                Divider()

                Button("First Page") {
                    model.goToFirstPage()
                }
                .keyboardShortcut(.upArrow, modifiers: .command)

                Button("Last Page") {
                    model.goToLastPage()
                }
                .keyboardShortcut(.downArrow, modifiers: .command)
            }
        }
    }
}
