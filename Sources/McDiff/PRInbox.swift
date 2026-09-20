import CoreData
import McDiffCore

/// A logical, server-sized inbox with only the viewport and its neighbours materialized.
@MainActor
final class PRInbox {
    typealias Loader = @Sendable (String, Int) async throws -> PRPage
    var onChange: (() -> Void)?
    var onAuthenticationRequired: (() -> Void)?
    private(set) var count = 0
    private(set) var isLoading = false
    private(set) var error: String?

    private let loader: Loader
    private let store = InboxStore()
    private var query = ""
    private var generation = UUID()
    private var request = UUID()
    private var task: Task<Void, Never>?
    private var visible = 0..<PRPage.pageSize
    private var projection: [Int: PRSummary] = [:]
    private var initialized = false
    private var pendingReset = true
    private var debouncing = false

    init(loader: @escaping Loader) { self.loader = loader }
    deinit { task?.cancel() }

    func item(at index: Int) -> PRSummary? { projection[index] }

    func search(_ query: String) {
        guard query != self.query || !initialized else { return }
        self.query = query
        reset(debounce: true)
    }

    func refresh() {
        guard !isLoading else { return }
        generation = UUID()
        initialized = true
        pendingReset = true
        load(debounce: false)
    }

    func retry() {
        guard !isLoading else { return }
        initialized = true
        load(debounce: false)
    }

    func clear() {
        let previousTask = task
        previousTask?.cancel()
        generation = UUID()
        request = UUID()
        count = 0
        visible = 0..<PRPage.pageSize
        projection.removeAll()
        initialized = false
        pendingReset = true
        debouncing = false
        isLoading = false
        error = nil
        let generation = generation
        let request = request
        task = Task { [weak self, store] in
            do {
                await previousTask?.value
                try Task.checkCancellation()
                try await store.reset(generation)
                guard let self, self.request == request else { return }
                self.task = nil
            }
            catch {
                guard let self, self.request == request else { return }
                self.task = nil
                self.error = error.localizedDescription
                self.onChange?()
            }
        }
        onChange?()
    }

    func show(_ visible: Range<Int>) {
        guard !visible.isEmpty else { return }
        let start = max(0, min(visible.lowerBound, max(0, count - 1)))
        let bounded = start..<min(start + 90, max(start + 1, visible.upperBound))
        guard bounded != self.visible else { return }
        let previousPages = pages
        self.visible = bounded
        guard initialized, !debouncing, pages != previousPages else { return }
        load(debounce: false)
    }

    private func reset(debounce: Bool) {
        generation = UUID()
        count = 0
        visible = 0..<PRPage.pageSize
        projection.removeAll()
        initialized = true
        pendingReset = true
        load(debounce: debounce)
    }

    private var window: Range<Int> {
        let lower = max(0, visible.lowerBound - PRPage.pageSize)
        return lower..<max(lower, min(count, visible.upperBound + PRPage.pageSize))
    }

    private var pages: [Int] {
        let window = window
        guard !window.isEmpty else { return [] }
        return Array((window.lowerBound / PRPage.pageSize + 1)...((window.upperBound - 1) / PRPage.pageSize + 1))
    }

    private func accept(_ page: PRPage) throws {
        guard (0...1_000).contains(page.totalCount), page.items.count <= PRPage.pageSize else {
            throw GitHubError.invalidResponse
        }
        count = page.totalCount
        if count == 0 {
            visible = 0..<PRPage.pageSize
        } else if visible.lowerBound >= count {
            let start = (count - 1) / PRPage.pageSize * PRPage.pageSize
            visible = start..<min(count, start + visible.count)
        } else {
            visible = visible.lowerBound..<min(count, visible.upperBound)
        }
        projection = projection.filter { window.contains($0.key) }
    }

    private func load(debounce: Bool) {
        let previousTask = task
        previousTask?.cancel()
        let request = UUID()
        self.request = request
        let generation = generation
        let query = query
        let needsReset = pendingReset
        debouncing = debounce
        isLoading = true
        error = nil
        projection = projection.filter { window.contains($0.key) }
        task = Task { [weak self, loader, store] in
            do {
                if debounce { try await Task.sleep(for: .milliseconds(300)) }
                // Wait for cancellation to finish before issuing another REST request.
                // This also bounds work for a loader that does not cancel immediately.
                await previousTask?.value
                try Task.checkCancellation()
                if needsReset { try await store.reset(generation) }
                guard let self, self.request == request else { return }
                self.pendingReset = false
                self.debouncing = false
                if self.count == 0 {
                    let page = try await loader(query, 1)
                    try Task.checkCancellation()
                    guard self.request == request else { return }
                    try self.accept(page)
                    try await store.save(page, number: 1, generation: generation)
                }
                while true {
                    try Task.checkCancellation()
                    guard self.request == request else { return }
                    let window = self.window
                    let cached = try await store.read(window, generation: generation)
                    guard self.request == request else { return }
                    self.projection = self.projection.filter { window.contains($0.key) }
                    self.projection.merge(cached) { _, new in new }
                    self.onChange?()
                    try Task.checkCancellation()
                    guard self.request == request else { return }
                    let visible = self.visible
                    let prioritized = self.pages.sorted {
                        let left = (($0 - 1) * PRPage.pageSize)..<($0 * PRPage.pageSize)
                        let right = (($1 - 1) * PRPage.pageSize)..<($1 * PRPage.pageSize)
                        return left.overlaps(visible) && !right.overlaps(visible)
                    }
                    var missing: Int?
                    for number in prioritized {
                        let cached = try await store.contains(number, generation: generation)
                        if !cached {
                            missing = number
                            break
                        }
                    }
                    try Task.checkCancellation()
                    guard let number = missing else { break }
                    let page = try await loader(query, number)
                    try Task.checkCancellation()
                    guard self.request == request else { return }
                    try self.accept(page)
                    try await store.save(page, number: number, generation: generation)
                }
                guard self.request == request else { return }
                self.isLoading = false
                self.task = nil
                self.onChange?()
            } catch {
                guard let self, self.request == request else { return }
                self.isLoading = false
                self.debouncing = false
                self.task = nil
                self.error = error.localizedDescription
                self.onChange?()
                if let github = error as? GitHubError, case .unauthenticated = github {
                    self.onAuthenticationRequired?()
                }
            }
        }
        onChange?()
    }
}

/// SQLite is scratch storage, never an authority for account or user-authored data.
private actor InboxStore {
    private var context: NSManagedObjectContext?
    private var directory: URL?
    private var generation: UUID?

    deinit {
        if let directory {
            do { try FileManager.default.removeItem(at: directory) }
            catch { NSLog("Could not remove PR inbox scratch cache: %@", error.localizedDescription) }
        }
    }

    private func database() throws -> NSManagedObjectContext {
        if let context { return context }
        let model = NSManagedObjectModel()
        func entity(_ name: String, fields: [(String, NSAttributeType)]) -> NSEntityDescription {
            let entity = NSEntityDescription()
            entity.name = name
            entity.managedObjectClassName = "NSManagedObject"
            entity.properties = fields.map { name, type in
                let attribute = NSAttributeDescription()
                attribute.name = name
                attribute.attributeType = type
                return attribute
            }
            return entity
        }
        model.entities = [
            entity("Row", fields: [("position", .integer64AttributeType), ("url", .stringAttributeType),
                                  ("title", .stringAttributeType), ("created", .dateAttributeType),
                                  ("draft", .booleanAttributeType)]),
            entity("Page", fields: [("number", .integer64AttributeType)])
        ]
        for entity in model.entities {
            let key = entity.name == "Row" ? "position" : "number"
            let attribute = entity.attributesByName[key]!
            entity.indexes = [NSFetchIndexDescription(name: "\(key)Index", elements: [
                NSFetchIndexElementDescription(property: attribute, collationType: .binary)
            ])]
            entity.uniquenessConstraints = [[key]]
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("McDiff-Inbox-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.directory = directory
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
        try coordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil,
                                           at: directory.appendingPathComponent("inbox.sqlite"))
        let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
        context.undoManager = nil
        self.context = context
        return context
    }

    func reset(_ generation: UUID) throws {
        let context = try database()
        try context.performAndWait {
            defer { context.reset() }
            for name in ["Row", "Page"] {
                try context.execute(NSBatchDeleteRequest(fetchRequest: NSFetchRequest<NSFetchRequestResult>(entityName: name)))
            }
        }
        self.generation = generation
    }

    func contains(_ number: Int, generation: UUID) throws -> Bool {
        guard self.generation == generation else { throw CancellationError() }
        let context = try database()
        return try context.performAndWait {
            defer { context.reset() }
            let request = NSFetchRequest<NSFetchRequestResult>(entityName: "Page")
            request.predicate = NSPredicate(format: "number == %d", number)
            request.fetchLimit = 1
            return try context.count(for: request) != 0
        }
    }

    func save(_ page: PRPage, number: Int, generation: UUID) throws {
        guard self.generation == generation else { throw CancellationError() }
        let context = try database()
        try context.performAndWait {
            defer { context.reset() }
            for (offset, item) in page.items.enumerated() {
                let position = (number - 1) * PRPage.pageSize + offset
                guard position < 1_000 else { break }
                let row = NSEntityDescription.insertNewObject(forEntityName: "Row", into: context)
                row.setValue(position, forKey: "position")
                row.setValue(item.pr.url, forKey: "url")
                row.setValue(item.title, forKey: "title")
                row.setValue(item.createdAt, forKey: "created")
                row.setValue(item.isDraft, forKey: "draft")
            }
            let record = NSEntityDescription.insertNewObject(forEntityName: "Page", into: context)
            record.setValue(number, forKey: "number")
            try context.save()
        }
    }

    func read(_ range: Range<Int>, generation: UUID) throws -> [Int: PRSummary] {
        guard self.generation == generation else { throw CancellationError() }
        let context = try database()
        return try context.performAndWait {
            defer { context.reset() }
            let request = NSFetchRequest<NSManagedObject>(entityName: "Row")
            request.predicate = NSPredicate(format: "position >= %d AND position < %d", range.lowerBound, range.upperBound)
            request.fetchLimit = 150
            request.fetchBatchSize = PRPage.pageSize
            request.sortDescriptors = [NSSortDescriptor(key: "position", ascending: true)]
            return try Dictionary(uniqueKeysWithValues: context.fetch(request).map { row in
                let position = (row.value(forKey: "position") as! NSNumber).intValue
                let pr = try GitHubPR.parse(row.value(forKey: "url") as! String)
                return (position, PRSummary(pr: pr, title: row.value(forKey: "title") as! String,
                                            createdAt: row.value(forKey: "created") as! Date,
                                            isDraft: row.value(forKey: "draft") as! Bool))
            })
        }
    }
}
