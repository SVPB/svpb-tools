import Vapor

public func routes(_ app: Application) throws {
    try app.register(collection: HealthController())
    try app.register(collection: WebhookController())
    try app.register(collection: SlackEventsController())
    try app.register(collection: AuthController())
    try app.register(collection: AdminController())
}
