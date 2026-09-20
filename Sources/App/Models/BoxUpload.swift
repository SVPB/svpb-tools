import Crypto
import Fluent
import Foundation
import Vapor

/// What has and has not reached Box, per binder, per branch.
///
/// O6 asks for artefacts to be retained locally and re-uploaded on the next build when
/// Box is unreachable. That is not implementable from the build log alone: after a failed
/// build nothing records *which* binders are outstanding, so the only options are
/// re-uploading everything or nothing. This is that record.
///
/// One row per `(branch, filename)`, carried across builds. It is deliberately not a
/// column on `BinderDefinition`: those rows are deleted and recreated wholesale by every
/// build (`BinderDefinitionLoader.replaceDefinitions`), so upload state kept there would
/// be erased by the very build that needs to read it.
final class BoxUpload: Model, @unchecked Sendable {

    static let schema = "box_uploads"

    // MARK: - Fields

    @ID(key: .id)
    var id: UUID?

    /// FK → Branch.name. The year folder in Box this binder belongs to.
    @Parent(key: "branch_name")
    var branch: Branch

    /// The binder's `output:` filename, which is also its name in Box.
    @Field(key: "filename")
    var filename: String

    /// Where the assembled binder was written on this server.
    @Field(key: "local_path")
    var localPath: String

    /// SHA-256 of the file as assembled, so a retry can tell whether the bytes on disk
    /// are still the ones this row is about.
    @Field(key: "content_hash")
    var contentHash: String

    /// When this binder reached Box. `nil` means outstanding.
    @OptionalField(key: "uploaded_at")
    var uploadedAt: Date?

    /// Why the last attempt failed, for the operator reading the dashboard.
    @OptionalField(key: "last_error")
    var lastError: String?

    /// Upload attempts since the file was last assembled.
    @Field(key: "attempts")
    var attempts: Int

    // MARK: - Lifecycle

    init() {}

    init(branch: String, filename: String, localPath: String, contentHash: String) {
        self.$branch.id = branch
        self.filename = filename
        self.localPath = localPath
        self.contentHash = contentHash
        self.attempts = 0
    }

    // MARK: - Convenience

    /// The SHA-256 of a file, as lowercase hex.
    static func hash(of url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    /// The row for this binder, reset to "assembled, not yet uploaded".
    ///
    /// Called once per binder per build, so the row always describes the file that is
    /// on disk now rather than one an earlier build wrote.
    static func record(
        branch: String, filename: String, url: URL, on db: any Database
    ) async throws -> BoxUpload {
        let contentHash = try hash(of: url)
        if let existing = try await BoxUpload.query(on: db)
            .filter(\.$branch.$id == branch)
            .filter(\.$filename == filename)
            .first() {
            existing.localPath = url.path
            existing.contentHash = contentHash
            existing.uploadedAt = nil
            existing.lastError = nil
            existing.attempts = 0
            try await existing.save(on: db)
            return existing
        }
        let fresh = BoxUpload(branch: branch, filename: filename,
                              localPath: url.path, contentHash: contentHash)
        try await fresh.create(on: db)
        return fresh
    }

    /// Every binder of `branch` that has not reached Box, oldest first.
    static func outstanding(for branch: String, on db: any Database) async throws -> [BoxUpload] {
        try await BoxUpload.query(on: db)
            .filter(\.$branch.$id == branch)
            .filter(\.$uploadedAt == nil)
            .sort(\.$filename)
            .all()
    }
}
