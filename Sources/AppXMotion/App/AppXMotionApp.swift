import SwiftUI

struct AppXMotionApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        Window("AppX Motion", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 1180, minHeight: 740)
                .onAppear { model.start() }
        }
        .defaultSize(width: 1440, height: 900)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Project") { model.newProject() }
                    .keyboardShortcut("n")
                Button("Open Project…") { model.openProject() }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                Divider()
                Button("Import Media…") { model.showImporter = true }
                    .keyboardShortcut("o")
            }
            CommandGroup(replacing: .saveItem) {
                Button("Save Project") { model.saveProject() }
                    .keyboardShortcut("s")
                Button("Save Project As…") { model.saveProjectAs() }
                    .keyboardShortcut("s", modifiers: [.command, .option])
            }
            CommandMenu("Capture") {
                Button(model.isRecordingAnything ? "Stop Recording" : (model.isWeb ? "Record Window" : "Record Phone Screen")) { model.toggleAnyRecording() }
                    .keyboardShortcut("r")
                Button(model.isWeb ? "Screenshot Window" : "Take Phone Screenshot") { model.captureAnyScreenshot() }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                Divider()
                Button("Switch to Android App") { model.switchPlatform(to: .android) }
                    .keyboardShortcut("1", modifiers: [.command, .option])
                Button("Switch to Web App") { model.switchPlatform(to: .web) }
                    .keyboardShortcut("2", modifiers: [.command, .option])
            }
            CommandMenu("Phone") {
                Button("Light + Dark Screenshots") { model.captureLightDarkScreenshots() }
                    .keyboardShortcut("l", modifiers: [.command, .shift])
                Button("Record Light + Dark Takes") { model.recordLightDarkPair() }
                Divider()
                Button("Grab Latest From Phone") { model.grabLatestFromPhone() }
                    .keyboardShortcut("g", modifiers: [.command, .shift])
                Button("Browse Phone Recordings…") { model.openPhoneGallery() }
                Divider()
                Button("Open Captures Folder") { model.openCapturesFolder() }
            }
            CommandMenu("Export") {
                Button("Export for X") { model.export() }
                    .keyboardShortcut("e")
                Button("Export Current Frame as Image") { model.exportCurrentFrame() }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                Divider()
                Button("Open Exports Folder") { model.openExportsFolder() }
            }
        }
    }
}
