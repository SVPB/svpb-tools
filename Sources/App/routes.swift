import Vapor

public func routes(_ app: Application) throws {
    try app.register(collection: HealthController())
    try app.register(collection: WebhookController())
}
