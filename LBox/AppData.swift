import Foundation
import Combine
import SwiftUI

// MARK: - Models

enum RepoFetchStatus: Equatable, Sendable, Hashable {
    case idle
    case waiting
    case loading
    case success
    case error(String)
}

// MARK: - Sorting Enums
enum AppSortOption: String, CaseIterable, Identifiable {
    case name = "Name"
    case date = "Date"
    case size = "Size"
    
    var id: String { rawValue }
}

enum RepoSortOption: String, CaseIterable, Identifiable {
    case standard = "Default"
    case name = "Name"
    
    var id: String { rawValue }
}

struct AppItem: Codable, Identifiable, Hashable, Sendable {
    // Modified ID to include sourceRepoName for uniqueness
    var id: String {
        if let repo = sourceRepoName {
            return "\(repo)|\(downloadURL)"
        }
        return downloadURL
    }
    let name: String
    let bundleIdentifier: String
    let version: String
    let versionDate: String?
    let size: Int64?
    let downloadURL: String
    let iconURL: String?
    let localizedDescription: String?
    let screenshotURLs: [String]
    
    var sourceRepoName: String? = nil
    
    enum CodingKeys: String, CodingKey {
        case name, bundleIdentifier, bundleID
        case version, versionDate, size, downloadURL
        case iconURL, icon
        case localizedDescription
        case screenshotURLs, screenshots
        case sourceRepoName
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        
        if let bid = try? container.decode(String.self, forKey: .bundleIdentifier) {
            bundleIdentifier = bid
        } else if let bid = try? container.decode(String.self, forKey: .bundleID) {
            bundleIdentifier = bid
        } else {
            bundleIdentifier = "unknown.bundle.id"
        }
        
        version = try container.decode(String.self, forKey: .version)
        versionDate = try container.decodeIfPresent(String.self, forKey: .versionDate)
        size = try container.decodeIfPresent(Int64.self, forKey: .size)
        downloadURL = try container.decode(String.self, forKey: .downloadURL)
        
        if let iUrl = try? container.decode(String.self, forKey: .iconURL) {
            iconURL = iUrl
        } else {
            iconURL = try container.decodeIfPresent(String.self, forKey: .icon)
        }
        
        localizedDescription = try container.decodeIfPresent(String.self, forKey: .localizedDescription)
        
        if let screens = try? container.decode([String].self, forKey: .screenshotURLs) {
            screenshotURLs = screens
        } else if let screens = try? container.decode([String].self, forKey: .screenshots) {
            screenshotURLs = screens
        } else {
            screenshotURLs = []
        }
        
        sourceRepoName = try container.decodeIfPresent(String.self, forKey: .sourceRepoName)
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(bundleIdentifier, forKey: .bundleIdentifier)
        try container.encode(version, forKey: .version)
        try container.encode(versionDate, forKey: .versionDate)
        try container.encode(size, forKey: .size)
        try container.encode(downloadURL, forKey: .downloadURL)
        try container.encode(iconURL, forKey: .iconURL)
        try container.encode(localizedDescription, forKey: .localizedDescription)
        try container.encode(screenshotURLs, forKey: .screenshotURLs)
        try container.encode(sourceRepoName, forKey: .sourceRepoName)
    }
}

// Represents an installed .app in the Applications folder
struct LocalApp: Identifiable, Hashable {
    var id: String { url.path }
    let name: String
    let bundleID: String
    let url: URL
    let iconURL: URL? // Local file URL to the icon if found
}

struct MetaData: Codable, Sendable {
    let repoName: String?
    let repoIcon: String?
}

struct RepoResponse: Codable, Sendable {
    let name: String
    let identifier: String?
    let iconURL: String?
    let META: MetaData?
    let apps: [AppItem]
    
    var bestIconURL: String? {
        return iconURL ?? META?.repoIcon
    }
}

struct ExportableRepo: Codable {
    let name: String
    let url: URL?
    let isEnabled: Bool?
    let children: [ExportableRepo]?
    
    init(_ repo: SavedRepo, onlyEnabled: Bool = false) {
        self.name = repo.name
        self.url = repo.url
        if onlyEnabled { self.isEnabled = nil } else { self.isEnabled = repo.isEnabled }
        if let kids = repo.children {
            let filtered = onlyEnabled ? kids.filter { $0.hasEnabledContent } : kids
            self.children = filtered.map { ExportableRepo($0, onlyEnabled: onlyEnabled) }
        } else { self.children = nil }
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try container.decode(String.self, forKey: .name)
        self.url = try container.decodeIfPresent(URL.self, forKey: .url)
        self.isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        self.children = try container.decodeIfPresent([ExportableRepo].self, forKey: .children)
    }
    
    func toSavedRepo() -> SavedRepo {
        let enabled = isEnabled ?? true
        if let children = children {
            let mappedChildren = children.map { $0.toSavedRepo() }
            var folder = SavedRepo(folderName: name, children: mappedChildren)
            folder.isEnabled = enabled
            return folder
        } else {
            return SavedRepo(url: url ?? URL(string: "about:blank")!, name: name, isEnabled: enabled)
        }
    }
}

struct SavedRepo: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var url: URL?
    var iconURL: String?
    var isEnabled: Bool
    var children: [SavedRepo]?
    var appCount: Int = 0 
    
    // Cache the apps to persist between launches
    var cachedApps: [AppItem]? = nil 
    
    var fetchStatus: RepoFetchStatus = .idle
    
    var isFolder: Bool { children != nil }
    
    var totalAppCount: Int {
        if let children = children {
            return children.reduce(0) { $0 + $1.totalAppCount }
        } else {
            return isEnabled ? appCount : 0
        }
    }
    
    var hasEnabledContent: Bool {
        if !isEnabled { return false }
        if let children = children { return children.contains { $0.hasEnabledContent } }
        return true
    }
    
    var hasDisabledContentRecursive: Bool {
        if !isEnabled { return true }
        if let children = children { return children.contains { $0.hasDisabledContentRecursive } }
        return false
    }
    
    func allURLs(onlyEnabled: Bool = false) -> String {
        if onlyEnabled && !isEnabled { return "" }
        if let children = children {
            return children.map { $0.allURLs(onlyEnabled: onlyEnabled) }.filter { !$0.isEmpty }.joined(separator: "\n")
        } else if let url = url {
            return url.absoluteString
        }
        return ""
    }

    enum CodingKeys: String, CodingKey {
        case id, name, url, iconURL, isEnabled, children, appCount, cachedApps
    }
    
    init(url: URL, name: String? = nil, iconURL: String? = nil, isEnabled: Bool = true, appCount: Int = 0) {
        self.id = url.absoluteString; self.url = url; self.name = name ?? "Unknown"; self.iconURL = iconURL; self.isEnabled = isEnabled; self.children = nil; self.appCount = appCount
        self.cachedApps = nil
    }
    
    init(folderName: String, children: [SavedRepo] = []) {
        self.id = UUID().uuidString; self.name = folderName; self.url = nil; self.iconURL = nil; self.isEnabled = true; self.children = children; self.appCount = 0
        self.cachedApps = nil
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let idVal = try? container.decode(String.self, forKey: .id) { self.id = idVal }
        else if let urlVal = try? container.decode(URL.self, forKey: .url) { self.id = urlVal.absoluteString }
        else { self.id = UUID().uuidString }
        
        self.url = try container.decodeIfPresent(URL.self, forKey: .url)
        self.name = try container.decodeIfPresent(String.self, forKey: .name) ?? "Unknown"
        self.iconURL = try container.decodeIfPresent(String.self, forKey: .iconURL)
        self.isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        self.children = try container.decodeIfPresent([SavedRepo].self, forKey: .children)
        self.appCount = try container.decodeIfPresent(Int.self, forKey: .appCount) ?? 0
        self.cachedApps = try container.decodeIfPresent([AppItem].self, forKey: .cachedApps)
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id); try container.encode(name, forKey: .name); try container.encode(url, forKey: .url)
        try container.encode(iconURL, forKey: .iconURL); try container.encode(isEnabled, forKey: .isEnabled)
        try container.encode(children, forKey: .children); try container.encode(appCount, forKey: .appCount)
        try container.encode(cachedApps, forKey: .cachedApps)
    }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(id); hasher.combine(name); hasher.combine(url); hasher.combine(iconURL)
        hasher.combine(isEnabled); hasher.combine(children); hasher.combine(appCount); hasher.combine(fetchStatus)
    }
    
    static func == (lhs: SavedRepo, rhs: SavedRepo) -> Bool {
        return lhs.id == rhs.id && lhs.name == rhs.name && lhs.url == rhs.url && lhs.iconURL == rhs.iconURL &&
               lhs.isEnabled == rhs.isEnabled && lhs.children == rhs.children && lhs.appCount == rhs.appCount && lhs.fetchStatus == rhs.fetchStatus
    }
}

actor Semaphore {
    private var count: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []
    init(_ count: Int) { self.count = count }
    func wait() async { if count > 0 { count -= 1 } else { await withCheckedContinuation { waiters.append($0) } } }
    func signal() { if !waiters.isEmpty { waiters.removeFirst().resume() } else { count += 1 } }
}

@MainActor
class AppStoreViewModel: ObservableObject {
    @Published var savedRepos: [SavedRepo] = []
    @Published var displayApps: [AppItem] = [] 
    @Published var allAppsByVariant: [String: [AppItem]] = [:] 
    
    @Published var searchText: String = ""
    @Published var isLoading = false
    @Published var selectedRepoID: String? = nil
    
    // Sort Options
    @Published var appSortOrder: AppSortOption = .name {
        didSet {
            // Trigger async refresh when sort changes
            Task { await refreshDisplayApps() }
        }
    }
    @Published var repoSortOrder: RepoSortOption = .standard {
        didSet {
            UserDefaults.standard.set(repoSortOrder.rawValue, forKey: "kRepoSortOrder")
            sortRepos()
        }
    }
    
    // Track fetch progress
    @Published var fetchProgress: Int = 0
    @Published var fetchTotal: Int = 0
    
    @Published var filteredApps: [AppItem] = []
    private var cancellables = Set<AnyCancellable>()
    
    @Published var isAutoUnzipEnabled: Bool = false { didSet { UserDefaults.standard.set(isAutoUnzipEnabled, forKey: "kAutoUnzipEnabled") } }
    private let kSavedReposKey = "kSavedReposKey"
    
    init() {
        self.isAutoUnzipEnabled = UserDefaults.standard.bool(forKey: "kAutoUnzipEnabled")
        if let storedSort = UserDefaults.standard.string(forKey: "kRepoSortOrder"),
           let option = RepoSortOption(rawValue: storedSort) {
            self.repoSortOrder = option
        }
        
        loadRepos()
        setupSearchSubscription()
    }
    
    private func setupSearchSubscription() {
        Publishers.CombineLatest3(
            $searchText.debounce(for: .milliseconds(300), scheduler: DispatchQueue.main),
            $displayApps,
            $selectedRepoID
        )
        .receive(on: DispatchQueue.global(qos: .userInitiated))
        .map { (text, apps, repoID) -> [AppItem] in
            let appsFromRepo = (repoID == nil) ? apps : apps.filter { $0.sourceRepoName == repoID }
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return appsFromRepo
            } else {
                return appsFromRepo.filter {
                    $0.name.localizedCaseInsensitiveContains(text) ||
                    $0.bundleIdentifier.localizedCaseInsensitiveContains(text)
                }
            }
        }
        .receive(on: DispatchQueue.main)
        .assign(to: &$filteredApps)
    }
    
    func loadRepos() {
        if let data = UserDefaults.standard.data(forKey: kSavedReposKey),
           let decoded = try? JSONDecoder().decode([SavedRepo].self, from: data) {
            savedRepos = decoded
            sortRepos()
        } else { resetReposToDefault() }
    }
    
    func getEnabledLeafRepos() -> [SavedRepo] {
        func flatten(_ nodes: [SavedRepo]) -> [SavedRepo] {
            var result: [SavedRepo] = []
            for node in nodes {
                if !node.isEnabled { continue }
                if let children = node.children { result.append(contentsOf: flatten(children)) }
                else { result.append(node) }
            }
            return result
        }
        let leaves = flatten(savedRepos)
        if repoSortOrder == .name {
            return leaves.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
        return leaves
    }
    
    func repoExists(_ id: String) -> Bool {
        func check(_ nodes: [SavedRepo]) -> Bool {
            for node in nodes {
                if node.id == id { return true }
                if let children = node.children { if check(children) { return true } }
            }
            return false
        }
        return check(savedRepos)
    }
    
    func getRepo(_ id: String) -> SavedRepo? {
        func find(_ nodes: [SavedRepo]) -> SavedRepo? {
            for node in nodes {
                if node.id == id { return node }
                if let children = node.children { if let found = find(children) { return found } }
            }
            return nil
        }
        return find(savedRepos)
    }
    
    func getRepos(in parentID: String?) -> [SavedRepo] {
        if let parentID = parentID {
            let kids = getRepo(parentID)?.children ?? []
            return sortNodes(kids)
        } else {
            return sortNodes(savedRepos)
        }
    }
    
    private func sortNodes(_ nodes: [SavedRepo]) -> [SavedRepo] {
        var sorted = nodes
        if repoSortOrder == .name {
            sorted.sort { (lhs, rhs) -> Bool in
                if lhs.isFolder && !rhs.isFolder { return true }
                if !lhs.isFolder && rhs.isFolder { return false }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
        }
        return sorted
    }
    
    func updateNode(_ node: SavedRepo) {
        func update(_ nodes: inout [SavedRepo]) {
            for i in 0..<nodes.count {
                if nodes[i].id == node.id { nodes[i] = node; return }
                if nodes[i].isFolder { update(&nodes[i].children!) }
            }
        }
        update(&savedRepos)
    }
    
    func updateRepoStatus(id: String, status: RepoFetchStatus) {
        func update(_ nodes: inout [SavedRepo]) -> Bool {
            for i in 0..<nodes.count {
                if nodes[i].id == id { nodes[i].fetchStatus = status; return true }
                if nodes[i].isFolder { if update(&nodes[i].children!) { return true } }
            }
            return false
        }
        _ = update(&savedRepos)
    }
    
    func setRepoEnabled(id: String, enabled: Bool) {
        func update(_ nodes: inout [SavedRepo]) {
            for i in 0..<nodes.count {
                if nodes[i].id == id { nodes[i].isEnabled = enabled; return }
                if nodes[i].isFolder { update(&nodes[i].children!) }
            }
        }
        update(&savedRepos); saveRepos()
        if enabled { Task { await fetchRepo(id: id); await refreshDisplayApps() } }
        else { Task { await refreshDisplayApps() } }
    }
    
    func addRepo(url: URL, parentID: String? = nil) {
        let id = url.absoluteString
        if repoExists(id) { return }
        let newRepo = SavedRepo(url: url)
        if let pid = parentID {
            func insert(_ nodes: inout [SavedRepo]) -> Bool {
                for i in 0..<nodes.count {
                    if nodes[i].id == pid {
                       if nodes[i].children == nil { nodes[i].children = [] }
                       nodes[i].children?.append(newRepo)
                       return true
                    }
                    if nodes[i].isFolder { if insert(&nodes[i].children!) { return true } }
                }
                return false
            }
            _ = insert(&savedRepos)
        } else { savedRepos.append(newRepo) }
        saveRepos()
        Task { await fetchRepo(id: id); await refreshDisplayApps() }
    }
    
    func addFolder(name: String, parentID: String?) {
        let folder = SavedRepo(folderName: name)
        if let pid = parentID {
            func insert(_ nodes: inout [SavedRepo]) -> Bool {
                for i in 0..<nodes.count {
                    if nodes[i].id == pid {
                       if nodes[i].children == nil { nodes[i].children = [] }
                       nodes[i].children?.append(folder)
                       return true
                    }
                    if nodes[i].isFolder { if insert(&nodes[i].children!) { return true } }
                }
                return false
            }
            _ = insert(&savedRepos)
        } else { savedRepos.append(folder) }
        saveRepos()
    }
    
    func renameRepo(id: String, newName: String) {
        func update(_ nodes: inout [SavedRepo]) {
            for i in 0..<nodes.count {
                if nodes[i].id == id { nodes[i].name = newName; return }
                if nodes[i].isFolder { update(&nodes[i].children!) }
            }
        }
        update(&savedRepos); saveRepos()
    }
    
    func deleteRepo(id: String) {
        func remove(_ nodes: inout [SavedRepo]) {
            nodes.removeAll(where: { $0.id == id })
            for i in 0..<nodes.count {
                if nodes[i].isFolder { remove(&nodes[i].children!) }
            }
        }
        remove(&savedRepos); saveRepos()
        Task { await refreshDisplayApps() }
    }
    
    func moveRepo(id: String, toParentId: String?) {
        if let target = toParentId, isDescendant(childId: target, parentId: id) { return }
        var itemToMove: SavedRepo?
        func remove(_ nodes: inout [SavedRepo]) -> Bool {
            for i in 0..<nodes.count {
                if nodes[i].id == id { itemToMove = nodes.remove(at: i); return true }
                if nodes[i].isFolder { if remove(&nodes[i].children!) { return true } }
            }
            return false
        }
        guard remove(&savedRepos), let item = itemToMove else { return }
        if let targetId = toParentId {
            func insert(_ nodes: inout [SavedRepo]) -> Bool {
                for i in 0..<nodes.count {
                    if nodes[i].id == targetId {
                        if nodes[i].children == nil { nodes[i].children = [] }
                        nodes[i].children?.append(item)
                        return true
                    }
                    if nodes[i].isFolder { if insert(&nodes[i].children!) { return true } }
                }
                return false
            }
            if !insert(&savedRepos) { savedRepos.append(item) }
        } else { savedRepos.append(item) }
        saveRepos()
    }
    
    private func isDescendant(childId: String, parentId: String) -> Bool {
        if childId == parentId { return true }
        var parentNode: SavedRepo?
        func find(_ nodes: [SavedRepo]) {
            for node in nodes {
                if node.id == parentId { parentNode = node; return }
                if let children = node.children { find(children) }
            }
        }
        find(savedRepos)
        if let p = parentNode {
            func has(_ nodes: [SavedRepo]) -> Bool {
                for node in nodes {
                    if node.id == childId { return true }
                    if let children = node.children { if has(children) { return true } }
                }
                return false
            }
            return p.children?.contains(where: { has([$0]) }) ?? false
        }
        return false
    }
    
    func getFolderTargets(excludingId: String) -> [SavedRepo] {
        func collect(_ nodes: [SavedRepo]) -> [SavedRepo] {
            var res: [SavedRepo] = []
            for node in nodes {
                if node.id == excludingId { continue } // Can't move into itself
                if node.isFolder {
                    res.append(node)
                    if let children = node.children { res.append(contentsOf: collect(children)) }
                }
            }
            return res
        }
        return collect(savedRepos)
    }

    func sortRepos() {
        func sort(_ nodes: inout [SavedRepo]) {
            nodes.sort { (lhs, rhs) -> Bool in
                if lhs.isFolder && !rhs.isFolder { return true }
                if !lhs.isFolder && rhs.isFolder { return false }
                
                // If sort order is name, we sort purely by name
                if repoSortOrder == .name {
                    return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                }
                
                // Default: allow manual ordering / insertion order (stable)
                return false 
            }
            for i in 0..<nodes.count { if nodes[i].isFolder { sort(&nodes[i].children!) } }
        }
        sort(&savedRepos)
    }
    
    func saveRepos() {
        sortRepos()
        let snapshot = savedRepos
        // Use a detached task for encoding to avoid blocking main thread
        Task.detached(priority: .background) {
            if let encoded = try? JSONEncoder().encode(snapshot) {
                 UserDefaults.standard.set(encoded, forKey: "kSavedReposKey")
            }
        }
    }
    
    func exportReposJSON(onlyEnabled: Bool = false) -> String? {
        let exportable = savedRepos.map { ExportableRepo($0, onlyEnabled: onlyEnabled) }
        guard let data = try? JSONEncoder().encode(exportable) else { return nil }
        return String(data: data, encoding: .utf8)
    }
    
    func exportSingleRepoJSON(_ repo: SavedRepo, onlyEnabled: Bool = false) -> String? {
        let exportable = ExportableRepo(repo, onlyEnabled: onlyEnabled)
        guard let data = try? JSONEncoder().encode(exportable) else { return nil }
        return String(data: data, encoding: .utf8)
    }
    
    func exportReposURLList(onlyEnabled: Bool = false) -> String {
        return savedRepos.map { $0.allURLs(onlyEnabled: onlyEnabled) }.filter { !$0.isEmpty }.joined(separator: "\n")
    }
    
    func importReposJSON(_ json: String) {
        guard let data = json.data(using: .utf8) else { return }
        if let exported = try? JSONDecoder().decode([ExportableRepo].self, from: data) {
            let imported = exported.map { $0.toSavedRepo() }
            if savedRepos.isEmpty { savedRepos = imported } else { savedRepos.append(contentsOf: imported) }
        } else if let single = try? JSONDecoder().decode(ExportableRepo.self, from: data) {
            savedRepos.append(single.toSavedRepo())
        } else if let full = try? JSONDecoder().decode([SavedRepo].self, from: data) {
            if savedRepos.isEmpty { savedRepos = full } else { savedRepos.append(contentsOf: full) }
        }
        saveRepos()
        Task { await fetchAllRepos() }
    }
    
    func resetReposToDefault() {
        // Updated default repo to a known consistent source for testing or example
        if let url = URL(string: "https://repository.apptesters.org/") {
            let def = SavedRepo(url: url, name: "AppTesters", iconURL: "https://apptesters.org/wp-content/uploads/2024/04/AppTesters-Logo-Site-Icon.webp", isEnabled: true)
            savedRepos = [def]
            saveRepos()
            Task { await fetchAllRepos() }
        }
    }
    
    func fetchRepo(id: String, saveAfter: Bool = true) async {
        guard let repo = getRepo(id), let url = repo.url else { return }
        updateRepoStatus(id: id, status: .loading)
        
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            
            // Offload decoding to background thread
            let (decoded, apps) = try await Task.detached {
                let decoded = try JSONDecoder().decode(RepoResponse.self, from: data)
                let apps = decoded.apps.map { var app = $0; app.sourceRepoName = decoded.name; return app }
                return (decoded, apps)
            }.value
            
            var updatedRepo = repo
            updatedRepo.name = decoded.name
            if let bestIcon = decoded.bestIconURL { updatedRepo.iconURL = bestIcon }
            updatedRepo.appCount = decoded.apps.count
            updatedRepo.fetchStatus = .success
            updatedRepo.cachedApps = apps
            updateNode(updatedRepo)
        } catch {
            print("Failed to fetch \(url): \(error)")
            var failed = repo; failed.isEnabled = false; failed.fetchStatus = .error(error.localizedDescription)
            updateNode(failed)
        }
        
        // Conditionally save
        if saveAfter {
            saveRepos()
        }
    }
    
    func fetchAllRepos() async {
        isLoading = true
        let leafRepos = getEnabledLeafRepos()
        
        fetchTotal = leafRepos.count
        fetchProgress = 0
        
        for repo in leafRepos { updateRepoStatus(id: repo.id, status: .waiting) }
        let semaphore = Semaphore(3)
        await withTaskGroup(of: Void.self) { group in
            for repo in leafRepos {
                group.addTask {
                    await semaphore.wait()
                    defer { Task { await semaphore.signal() } }
                    await self.fetchRepo(id: repo.id, saveAfter: false)
                    await MainActor.run { self.fetchProgress += 1 }
                }
            }
        }
        
        // Save once at the end
        saveRepos()
        
        await refreshDisplayApps()
        isLoading = false
    }
    
    func refreshDisplayApps() async {
        let enabled = getEnabledLeafRepos()
        var allApps: [AppItem] = []
        for repo in enabled { if let cache = repo.cachedApps { allApps.append(contentsOf: cache) } }
        await processApps(allApps)
    }
    
    private func processApps(_ apps: [AppItem]) async {
        let sortOrder = self.appSortOrder
        
        // Offload heavy sorting/filtering to background
        let (grouped, displayList) = await Task.detached(priority: .userInitiated) {
            let grouped = Dictionary(grouping: apps) { "\($0.bundleIdentifier)|\($0.name)|\($0.sourceRepoName ?? "")" }
            
            var representatives: [AppItem] = []
            for (_, versions) in grouped {
                if let latest = versions.sorted(by: { ($0.versionDate ?? "") > ($1.versionDate ?? "") }).first {
                    representatives.append(latest)
                }
            }
            
            let sorted = representatives.sorted { lhs, rhs in
                switch sortOrder {
                case .name:
                    return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                case .date:
                    let lDate = lhs.versionDate ?? ""
                    let rDate = rhs.versionDate ?? ""
                    return lDate > rDate
                case .size:
                    let lSize = lhs.size ?? 0
                    let rSize = rhs.size ?? 0
                    return lSize > rSize
                }
            }
            return (grouped, sorted)
        }.value
        
        self.allAppsByVariant = grouped
        self.displayApps = displayList
    }
    
    // **Renamed method to avoid keyword conflict**
    func getVersions(for app: AppItem) -> [AppItem] {
        let key = "\(app.bundleIdentifier)|\(app.name)|\(app.sourceRepoName ?? "")"
        return allAppsByVariant[key]?.sorted(by: { ($0.versionDate ?? "") > ($1.versionDate ?? "") }) ?? []
    }
}
