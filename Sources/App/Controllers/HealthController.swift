import Vapor

/// Handles `GET /health`.
///
/// Returns a JSON summary of server status suitable for an uptime monitor.
/// In Phase 1 this will be enriched with live branch and last-build data
/// from the database; for now it returns a static `ok` response.
struct HealthController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        routes.get("health", use: health)
    }

    @Sendable
    func health(_ req: Request) async throws -> HealthResponse {
        // Phase 1 will query the database for branches and last build.
        return HealthResponse(status: .ok)
    }
}
