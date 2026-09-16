import Fluent
import Foundation
import Yams

// MARK: - BinderDefinitionLoader

/// Reads `binders.yaml` from a branch checkout, checks it, and stores its binders
/// as `BinderDefinition` records.
///
/// Split out of `BuildService` so it can be tested without a git checkout, Box,
/// or Slack. The build calls it after conversion, once the catalogue it
/// validates against is current.
enum BinderDefinitionLoader {

    /// The file's name, at the root of the branch.
    static let fileName = "binders.yaml"

    /// A problem that makes `binders.yaml` unusable as a whole.
    struct LoadError: Error, CustomStringConvertible {
        let description: String
    }

    /// An entry naming a tune the branch's catalogue does not contain.
    struct UnresolvedEntry: Equatable, Sendable {
        let binder: String
        let section: String
        let tune: String
    }

    // MARK: - Reading

    /// Reads and checks `binders.yaml` in `branchDirectory`.
    ///
    /// - Returns: The decoded file, or `nil` when the branch has none — a branch
    ///   that has not been migrated to `binders.yaml` simply has no official binders.
    /// - Throws: `LoadError` when the file exists but cannot be read, is not valid
    ///   YAML, does not have the expected shape, or declares unusable binders.
    static func load(from branchDirectory: URL) throws -> BindersFile? {
        let url = branchDirectory.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }

        let yaml: String
        do {
            yaml = try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw LoadError(description: "could not read \(fileName): \(error.localizedDescription)")
        }
        return try decode(yaml)
    }

    /// Decodes and checks the text of a `binders.yaml` file.
    static func decode(_ yaml: String) throws -> BindersFile {
        let file: BindersFile
        do {
            file = try YAMLDecoder().decode(BindersFile.self, from: yaml)
        } catch let error as DecodingError {
            throw LoadError(description: describe(error))
        } catch {
            throw LoadError(description: "\(error)")
        }

        let problems = problems(in: file)
        guard problems.isEmpty else {
            throw LoadError(description: problems.joined(separator: "; "))
        }
        return file
    }

    /// Everything wrong with a structurally valid file that would stop its binders
    /// being built: blank names, output filenames that are not a bare `.pdf`
    /// filename, and outputs shared by two binders.
    static func problems(in file: BindersFile) -> [String] {
        var problems: [String] = []
        var seenOutputs: Set<String> = []

        for (index, binder) in file.binders.enumerated() {
            let label = "binders[\(index)]"
            if binder.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                problems.append("\(label) has a blank name")
            }
            if !isBareFilename(binder.output) || !binder.output.lowercased().hasSuffix(".pdf") {
                problems.append("\(label) output '\(binder.output)' must be a plain filename ending in .pdf")
            }
            // Box compares filenames case-insensitively, so `A.pdf` and `a.pdf` collide there.
            if !seenOutputs.insert(binder.output.lowercased()).inserted {
                problems.append("\(label) output '\(binder.output)' is already used by an earlier binder")
            }
        }
        return problems
    }

    /// True when `name` names a file directly, with no directory component that
    /// could place the output outside the branch's output folder.
    private static func isBareFilename(_ name: String) -> Bool {
        !name.isEmpty
            && name != "." && name != ".."
            && !name.hasPrefix(".")
            && !name.contains("/") && !name.contains("\\")
    }

    /// Renders a decoding failure as the key path the pipe major needs to fix,
    /// e.g. `binders[0].sections[1].entries[2]: missing key 'tune'`.
    private static func describe(_ error: DecodingError) -> String {
        func path(_ codingPath: [any CodingKey]) -> String {
            let rendered = codingPath.reduce("") { result, key in
                if let index = key.intValue { return result + "[\(index)]" }
                return result.isEmpty ? key.stringValue : result + "." + key.stringValue
            }
            return rendered.isEmpty ? "file" : rendered
        }

        switch error {
        case .keyNotFound(let key, let context):
            return "\(path(context.codingPath)): missing key '\(key.stringValue)'"
        case .typeMismatch(_, let context), .valueNotFound(_, let context):
            return "\(path(context.codingPath)): \(context.debugDescription)"
        case .dataCorrupted(let context):
            // YAML syntax errors arrive here, with the parser's own error — which
            // carries the line and column — as the underlying error.
            if let underlying = context.underlyingError {
                return "\(underlying)"
            }
            return "\(path(context.codingPath)): \(context.debugDescription)"
        @unknown default:
            return "\(error)"
        }
    }

    // MARK: - Validation against the catalogue

    /// Every entry, in file order, whose tune is not among `catalogueSlugs`.
    ///
    /// A typo in a slug must not silently drop a tune from a printed binder, so
    /// the build logs each of these.
    static func unresolvedEntries(in file: BindersFile, catalogueSlugs: Set<String>) -> [UnresolvedEntry] {
        file.binders.flatMap { binder in
            binder.sections.flatMap { section in
                section.entries
                    .filter { !catalogueSlugs.contains($0.tune) }
                    .map { UnresolvedEntry(binder: binder.name, section: section.title, tune: $0.tune) }
            }
        }
    }

    // MARK: - Persistence

    /// Replaces every stored binder definition for `branch` with `binders`, in
    /// one transaction so readers never see a half-replaced set.
    static func replaceDefinitions(for branch: String, with binders: [OfficialBinder], on db: any Database) async throws {
        try await db.transaction { tx in
            try await BinderDefinition.query(on: tx)
                .filter(\.$branch.$id == branch)
                .delete()
            for (position, binder) in binders.enumerated() {
                try await BinderDefinition(branch: branch, position: position, binder: binder).create(on: tx)
            }
        }
    }
}
