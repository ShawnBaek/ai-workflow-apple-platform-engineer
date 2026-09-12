import AppIntents
import Foundation

struct AuditItem: AppEntity, Hashable {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Audit Item"
    static let defaultQuery = AuditItemQuery()
    let id: String
    let name: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

struct AuditItemQuery: EntityQuery {
    static let current = [AuditItem(id: "current", name: "Current")]
    func entities(for identifiers: [String]) async throws -> [AuditItem] {
        Self.current.filter { identifiers.contains($0.id) }
    }
    func suggestedEntities() async throws -> [AuditItem] { Self.current }
}

actor AuditDomain {
    static let shared = AuditDomain()
    private var marked = Set<String>()
    func mark(_ id: String) throws -> String {
        guard AuditItemQuery.current.contains(where: { $0.id == id }) else {
            throw NSError(domain: "Audit", code: 1, userInfo: [NSLocalizedDescriptionKey: "item is deleted or inaccessible"])
        }
        return marked.insert(id).inserted ? "marked" : "already-marked"
    }
    func contains(_ id: String) -> Bool { marked.contains(id) }
}

struct MarkAuditItemIntent: AppIntent {
    static let title: LocalizedStringResource = "Mark Audit Item"
    static let description = IntentDescription("Marks one currently accessible item.")
    static let openAppWhenRun = false

    @Parameter(title: "Item") var item: AuditItem

    init() {}
    init(item: AuditItem) { self.item = item }

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let outcome = try await AuditDomain.shared.mark(item.id)
        return .result(value: outcome)
    }
}

@main
struct AppIntentsAudit {
    static func main() async throws {
        let query = AuditItemQuery()
        let resolved = try await query.entities(for: ["current", "deleted"])
        guard resolved.map(\.id) == ["current"] else { throw NSError(domain: "Audit", code: 2) }
        _ = try await MarkAuditItemIntent(item: resolved[0]).perform()
        guard await AuditDomain.shared.contains(resolved[0].id) else { throw NSError(domain: "Audit", code: 4) }
        let second = try await AuditDomain.shared.mark(resolved[0].id)
        guard second == "already-marked" else {
            throw NSError(domain: "Audit", code: 5, userInfo: [NSLocalizedDescriptionKey: "repeat mutation was not idempotent"])
        }
        do {
            _ = try await AuditDomain.shared.mark("deleted")
            throw NSError(domain: "Audit", code: 3)
        } catch let error as NSError where error.domain == "Audit" && error.code == 1 {}
        print("app_entity_resolution=passed deleted_filtered=true intent_perform=passed domain_retry=\(second)")
    }
}
