import Vapor

public func routes(_ app: Application) throws {
    app.get { req async throws -> View in
        struct IndexContext: Encodable {
            let appVersion: String
            let isAdmin: Bool
            let currentUser: String?
        }
        let user = await req.sessionUser()
        return try await req.view.render("index", IndexContext(
            appVersion: AppVersion.current,
            isAdmin: user?.role == .admin,
            currentUser: user.map { $0.displayName ?? $0.slackUserId }
        ))
    }

    try app.register(collection: HealthController())
    try app.register(collection: WebhookController())
    try app.register(collection: SlackEventsController())
    try app.register(collection: AuthController())
    try app.register(collection: AdminController())
    try app.register(collection: CatalogueController())
    try app.register(collection: BinderController())
}
