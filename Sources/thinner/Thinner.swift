import ArgumentParser
import ThinnerCore

@main
struct Thinner: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "thinner",
        abstract: "Remove Intel (x86_64) slices from Universal Binary apps on Apple Silicon.",
        version: ThinnerCore.version
    )
}
