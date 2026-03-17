import Fluent
import Vapor

/// Provides read-only access to the tune catalogue: branches, tunes, and parts.
///
/// All routes are unauthenticated — the catalogue is public so that band
/// members can browse tunes without logging in.
struct CatalogueController: RouteCollection {

    func boot(routes: any RoutesBuilder) throws {
        let branches = routes.grouped("branches")
        branches.get(use: listBranches)
        branches.get(":branch", "tunes", use: listTunes)
        branches.get(":branch", "tunes", ":slug", use: tuneDetail)
    }

    // MARK: - Handlers

    /// `GET /branches` — list all known branches (years).
    @Sendable
    func listBranches(req: Request) async throws -> [BranchDTO] {
        let branches = try await Branch.query(on: req.db)
            .sort(\.$id, .descending)
            .all()
        return branches.map { BranchDTO(from: $0) }
    }

    /// `GET /branches/:branch/tunes` — list all tunes in a branch.
    @Sendable
    func listTunes(req: Request) async throws -> [TuneListItemDTO] {
        guard let branchName = req.parameters.get("branch") else {
            throw Abort(.badRequest)
        }
        let tunes = try await Tune.query(on: req.db)
            .filter(\.$branch.$id == branchName)
            .sort(\.$slug)
            .all()
        return try tunes.map { try TuneListItemDTO(from: $0) }
    }

    /// `GET /branches/:branch/tunes/:slug` — tune detail including its parts.
    @Sendable
    func tuneDetail(req: Request) async throws -> TuneDetailDTO {
        guard let branchName = req.parameters.get("branch"),
              let slug = req.parameters.get("slug") else {
            throw Abort(.badRequest)
        }
        guard let tune = try await Tune.query(on: req.db)
            .filter(\.$branch.$id == branchName)
            .filter(\.$slug == slug)
            .with(\.$parts)
            .first() else {
            throw Abort(.notFound)
        }
        return try TuneDetailDTO(from: tune, parts: tune.parts)
    }
}
