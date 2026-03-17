import Vapor

// MARK: - BranchDTO

struct BranchDTO: Content {
    let name: String
    let lastBuilt: Date?
    let headSha: String?

    init(from branch: Branch) {
        self.name = branch.name
        self.lastBuilt = branch.lastBuilt
        self.headSha = branch.headSha
    }
}

// MARK: - PartDTO

struct PartDTO: Content {
    let id: UUID
    let name: String

    init(from part: Part) throws {
        self.id = try part.requireID()
        self.name = part.name
    }
}

// MARK: - TuneListItemDTO

struct TuneListItemDTO: Content {
    let id: UUID
    let slug: String
    let title: String?

    init(from tune: Tune) throws {
        self.id = try tune.requireID()
        self.slug = tune.slug
        self.title = tune.title
    }
}

// MARK: - TuneDetailDTO

struct TuneDetailDTO: Content {
    let id: UUID
    let slug: String
    let title: String?
    let abcPath: String?
    let parts: [PartDTO]

    init(from tune: Tune, parts: [Part]) throws {
        self.id = try tune.requireID()
        self.slug = tune.slug
        self.title = tune.title
        self.abcPath = tune.abcPath
        self.parts = try parts.map { try PartDTO(from: $0) }
    }
}

// MARK: - BinderStatusDTO

struct BinderStatusDTO: Content {
    let id: UUID
    let status: String
    let downloadURL: String?

    init(from request: BinderRequest, baseURL: String) throws {
        let id = try request.requireID()
        self.id = id
        self.status = request.pdfPath != nil ? "ready" : "pending"
        self.downloadURL = request.pdfPath != nil ? "\(baseURL)/binders/\(id)/download" : nil
    }
}
