import AppKit

// `AppX Motion render …` runs the export pipeline headlessly (handy for scripting and testing).
if HeadlessCLI.handles(CommandLine.arguments) {
    exit(HeadlessCLI.run(CommandLine.arguments))
}

Migration.run()
AppXMotionApp.main()
