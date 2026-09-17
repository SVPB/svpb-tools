import Vapor

/// What `DELETE /admin/branches/:branch` removed, reported back to the dashboard.
struct BranchRemovalSummary: Content, Equatable {
    let branch: String
    let tunes: Int
    let parts: Int
    let builds: Int
    let binderDefinitions: Int
    /// Workspace-relative directories that existed and were deleted.
    let directories: [String]
    /// Total size of the regular files in those directories.
    let bytes: Int64

    enum CodingKeys: String, CodingKey {
        case branch, tunes, parts, builds, directories, bytes
        case binderDefinitions = "binder_definitions"
    }
}
