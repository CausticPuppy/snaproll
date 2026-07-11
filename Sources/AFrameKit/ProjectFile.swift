import Foundation

/// Reads and writes `.prj` files — the decoded 0x7F00 DSP_PROJECT image,
/// the same format legacy aFrameEdit uses.
public enum ProjectFile {
    public static func load(_ url: URL) throws -> DSPProject {
        try DSPProject.decode(try Data(contentsOf: url))
    }

    public static func save(_ project: DSPProject, to url: URL) throws {
        try project.encode().write(to: url)
    }
}
