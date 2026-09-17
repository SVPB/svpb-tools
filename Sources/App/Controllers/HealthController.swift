import Fluent
import Vapor

/// Handles `GET /health`.
///
/// Returns a JSON summary of server status — branch list and most recent build —
/// queried live from SQLite.  Suitable for an uptime monitor or a status widget.
struct HealthController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        routes.get("health", use: health)
    }

    @Sendable
    func health(_ req: Request) async throws -> HealthResponse {
        // Branch names known to the server (populated after each successful build).
        let branches = try await Branch.query(on: req.db)
            .sort(\.$id, .ascending)
            .all()
            .map(\.name)

        // Most recent build across all branches.
        let lastBuild = try await Build.query(on: req.db)
            .sort(\.$triggered, .descending)
            .first()
            .map { build -> BuildSummary in
                BuildSummary(
                    id: build.id!,
                    branch: build.$branch.id,
                    triggered: build.triggered ?? Date(),
                    commitSha: build.commitSha,
                    status: build.status,
                    files: build.files
                )
            }

        return HealthResponse(
            status: .ok,
            branches: branches,
            lastBuild: lastBuild
        )
    }
}
