import CoreData
import Foundation
import SwiftData

@Model
final class SwiftDataNote {
    var title: String
    init(title: String) { self.title = title }
}

func coreDataModel(version: Int) -> NSManagedObjectModel {
    let model = NSManagedObjectModel()
    model.versionIdentifiers = ["audit-v\(version)"]
    let entity = NSEntityDescription()
    entity.name = "Note"
    entity.managedObjectClassName = NSStringFromClass(NSManagedObject.self)
    let title = NSAttributeDescription()
    title.name = "title"
    title.attributeType = .stringAttributeType
    title.isOptional = false
    var properties: [NSPropertyDescription] = [title]
    if version == 2 {
        let rank = NSAttributeDescription()
        rank.name = "rank"
        rank.attributeType = .integer64AttributeType
        rank.isOptional = false
        rank.defaultValue = 0
        properties.append(rank)
    }
    entity.properties = properties
    model.entities = [entity]
    return model
}

func runCoreDataMigration() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ape-coredata-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let storeURL = directory.appendingPathComponent("Notes.sqlite")

    let v1 = coreDataModel(version: 1)
    var coordinator: NSPersistentStoreCoordinator? = NSPersistentStoreCoordinator(managedObjectModel: v1)
    let firstStore = try coordinator!.addPersistentStore(type: .sqlite, at: storeURL)
    let writer = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
    writer.persistentStoreCoordinator = coordinator
    let originalID: NSManagedObjectID = try writer.performAndWait {
        let note = NSEntityDescription.insertNewObject(forEntityName: "Note", into: writer)
        note.setValue("seeded-v1", forKey: "title")
        try writer.obtainPermanentIDs(for: [note])
        try writer.save()
        return note.objectID
    }
    try coordinator!.remove(firstStore)
    coordinator = nil

    let v2 = coreDataModel(version: 2)
    let migrated = NSPersistentStoreCoordinator(managedObjectModel: v2)
    _ = try migrated.addPersistentStore(
        type: .sqlite,
        at: storeURL,
        options: [
            NSMigratePersistentStoresAutomaticallyOption: true,
            NSInferMappingModelAutomaticallyOption: true,
        ]
    )
    let reader = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
    reader.persistentStoreCoordinator = migrated
    try reader.performAndWait {
        let object = try reader.existingObject(with: originalID)
        guard object.value(forKey: "title") as? String == "seeded-v1",
              object.value(forKey: "rank") as? Int64 == 0 else {
            throw NSError(domain: "Audit", code: 1, userInfo: [NSLocalizedDescriptionKey: "migrated values differ"])
        }
    }
    print("core_data_lightweight_migration=passed seeded=v1 reopened=v2 object_id_transfer=passed")
}

func runSwiftData() throws {
    let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
    let container = try ModelContainer(for: SwiftDataNote.self, configurations: configuration)
    let context = ModelContext(container)
    context.insert(SwiftDataNote(title: "swiftdata-note"))
    try context.save()
    let expected = "swiftdata-note"
    let descriptor = FetchDescriptor<SwiftDataNote>(predicate: #Predicate { $0.title == expected })
    let results = try context.fetch(descriptor)
    guard results.count == 1, results[0].title == expected else {
        throw NSError(domain: "Audit", code: 2, userInfo: [NSLocalizedDescriptionKey: "SwiftData round trip failed"])
    }
    print("swift_data_in_memory_roundtrip=passed count=\(results.count)")
}

@main
struct PersistenceAudit {
    static func main() throws {
        try runCoreDataMigration()
        try runSwiftData()
    }
}
