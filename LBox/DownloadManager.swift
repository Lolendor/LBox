import Foundation
import SwiftUI
import Combine
import UserNotifications
#if canImport(ZIPFoundation)
import ZIPFoundation
#endif

// Make Equatable for UI comparisons
enum DownloadStatus: Equatable {
    case downloading(progress: Double, written: Int64, total: Int64)
    case paused
    case waitingForConnection
    case none
}

enum InstallAction {
    case installSeparate
    case updateExisting
    case cancel
}

struct PendingInstallation: Identifiable {
    let id = UUID()
    let appName: String
    let bundleID: String
    let tempPayloadURL: URL 
    let extractedAppURL: URL 
    let sourceArchiveURL: URL 
    let existingApp: LocalApp? 
}

struct AppBackup: Codable, Identifiable, Sendable {
    var id: String { bundleID }
    let bundleID: String
    let appName: String
    let version: String?
    let backupPath: String 
    let originalInstallPath: String 
    let date: Date
    let hadLCAppInfo: Bool 
}

@MainActor
class DownloadManager: NSObject, ObservableObject {
    @Published var activeDownloads: [URL: Double] = [:]
    @Published var pausedDownloads: Set<URL> = []
    
    // Files in the Download Folder
    @Published var fileList: [URL] = []
    
    // Installed Apps in the Apps Folder
    @Published var installedApps: [LocalApp] = []
    
    // Files currently being extracted
    @Published var extractingFiles: Set<URL> = []
    
    @Published var customDownloadFolder: URL? = nil
    @Published var customLiveContainerFolder: URL? = nil 
    
    // Pending Installation (Collision)
    @Published var pendingInstallation: PendingInstallation? = nil
    
    // Backups for Updates
    @Published var pendingBackups: [AppBackup] = []
    
    // Changed to Published for reactive UI updates
    @Published var isAutoUnzipEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isAutoUnzipEnabled, forKey: "kAutoUnzipEnabled")
        }
    }
    
    @Published var downloadStates: [URL: DownloadStatus] = [:]
    
    private var urlSession: URLSession!
    private var tasks: [URL: URLSessionDownloadTask] = [:]
    private var resumeDataMap: [URL: Data] = [:]
    var backgroundCompletionHandler: (() -> Void)?
    
    private let kCustomDownloadFolderKey = "kCustomDownloadFolderBookmark"
    private let kCustomLiveContainerFolderKey = "kCustomLiveContainerFolderBookmark"
    private let kBackgroundSessionID = "com.lbox.downloadSession"
    private let kResumeDataMapKey = "kResumeDataMapKey"
    
    private let kPendingBackupsKey = "kPendingBackupsKey"
    
    // URL String -> Filename in Caches
    private var diskResumeDataPaths: [String: String] = [:]
    
    override init() {
        self.isAutoUnzipEnabled = UserDefaults.standard.bool(forKey: "kAutoUnzipEnabled")
        super.init()
        let config = URLSessionConfiguration.background(withIdentifier: kBackgroundSessionID)
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        config.waitsForConnectivity = true
        config.timeoutIntervalForResource = 86400 
        config.timeoutIntervalForRequest = 600 
        
        self.urlSession = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        
        restoreFolders()
        restoreResumeDataMapping()
        loadPendingBackups()
        reconnectExistingTasks()
        refreshFileList()
        refreshInstalledApps()
    }
    
    func getStatus(for url: URL) -> DownloadStatus {
        return downloadStates[url] ?? .none
    }
    
    func getInstalledVersion(bundleID: String) -> String? {
        return installedApps.first(where: { $0.bundleID == bundleID })?.version
    }
    
    func getInstalledAppName(bundleID: String) -> String? {
        return installedApps.first(where: { $0.bundleID == bundleID })?.url.lastPathComponent
    }
    
    // MARK: - Notifications
    func sendNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
    
    // MARK: - Directories
    
    var currentDownloadFolder: URL {
        if let custom = customDownloadFolder { return custom }
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
    
    var currentAppsFolder: URL {
        if let root = customLiveContainerFolder {
            let appsSub = root.appendingPathComponent("Applications")
            if FileManager.default.fileExists(atPath: appsSub.path) { return appsSub }
            return root
        }
        return currentDownloadFolder
    }
    
    var currentDataApplicationFolder: URL? {
        if let root = customLiveContainerFolder {
            return root.appendingPathComponent("Data").appendingPathComponent("Application")
        }
        return nil
    }
    
    var backupDirectory: URL {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Backups")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    
    func getLocalFile(for url: URL) -> URL? {
        var name = url.lastPathComponent
        if url.pathExtension.isEmpty { name += ".ipa" }
        
        let dest = currentDownloadFolder.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: dest.path) { return dest }
        
        let destOriginal = currentDownloadFolder.appendingPathComponent(url.lastPathComponent)
        if FileManager.default.fileExists(atPath: destOriginal.path) { return destOriginal }
        
        let zipName = dest.deletingPathExtension().appendingPathExtension("zip").lastPathComponent
        let zipDest = currentDownloadFolder.appendingPathComponent(zipName)
        if FileManager.default.fileExists(atPath: zipDest.path) { return zipDest }
        
        return nil
    }
    
    func isAppInstalled(bundleID: String) -> Bool {
        return installedApps.contains { $0.bundleID == bundleID }
    }
    
    // MARK: - Backup Logic
    
    func loadPendingBackups() {
        if let data = UserDefaults.standard.data(forKey: kPendingBackupsKey),
           let list = try? JSONDecoder().decode([AppBackup].self, from: data) {
            self.pendingBackups = list
        }
    }
    
    func savePendingBackups() {
        if let data = try? JSONEncoder().encode(pendingBackups) {
            UserDefaults.standard.set(data, forKey: kPendingBackupsKey)
        }
    }
    
    func hasLCAppInfo(bundleID: String) -> Bool {
        guard let app = installedApps.first(where: { $0.bundleID == bundleID }) else { return false }
        let url = app.url.appendingPathComponent("LCAppInfo.plist")
        return FileManager.default.fileExists(atPath: url.path)
    }
    
    func checkUpdateStatus(for backup: AppBackup) -> Bool {
        refreshInstalledApps()
        
        let bundleID = backup.bundleID
        guard isAppInstalled(bundleID: bundleID) else { return false }
        
        if hasLCAppInfo(bundleID: bundleID) {
            if backup.hadLCAppInfo {
                finalizeUpdate(backup)
            } else {
                discardBackup(backup)
            }
            return true
        }
        return false
    }
    
    func finalizeUpdate(_ backup: AppBackup) {
        guard let app = installedApps.first(where: { $0.bundleID == backup.bundleID }) else {
            discardBackup(backup)
            return
        }
        
        let fileManager = FileManager.default
        let newInfoURL = app.url.appendingPathComponent("LCAppInfo.plist")
        let backupAppURL = backupDirectory.appendingPathComponent(backup.backupPath).appendingPathComponent(backup.originalInstallPath)
        let oldInfoURL = backupAppURL.appendingPathComponent("LCAppInfo.plist")
        
        if fileManager.fileExists(atPath: newInfoURL.path) && fileManager.fileExists(atPath: oldInfoURL.path) {
            do {
                let oldData = try Data(contentsOf: oldInfoURL)
                guard let oldPlist = try PropertyListSerialization.propertyList(from: oldData, format: nil) as? [String: Any] else {
                    discardBackup(backup)
                    return
                }
                
                let newData = try Data(contentsOf: newInfoURL)
                var newPlist = try PropertyListSerialization.propertyList(from: newData, format: nil) as? [String: Any] ?? [:]
                
                // NEW: Clean up newly created empty containers before restoring old ones
                if let newContainers = newPlist["LCContainers"] as? [[String: Any]],
                   let dataAppFolder = currentDataApplicationFolder {
                    for container in newContainers {
                        if let folderName = container["folderName"] as? String {
                            let folderURL = dataAppFolder.appendingPathComponent(folderName)
                            if fileManager.fileExists(atPath: folderURL.path) {
                                try? fileManager.removeItem(at: folderURL)
                                print("Deleted temporary container: \(folderName)")
                            }
                        }
                    }
                }
                
                // Patch new plist with old container/uuid data to preserve UserData
                if let oldContainers = oldPlist["LCContainers"] {
                    newPlist["LCContainers"] = oldContainers
                }
                if let oldUUID = oldPlist["LCDataUUID"] {
                    newPlist["LCDataUUID"] = oldUUID
                }
                
                let patchedData = try PropertyListSerialization.data(fromPropertyList: newPlist, format: .xml, options: 0)
                try patchedData.write(to: newInfoURL)
                print("Patched LCAppInfo for \(backup.bundleID) with old data.")
                
            } catch {
                print("Failed to patch LCAppInfo: \(error)")
            }
        }
        
        discardBackup(backup)
    }
    
    // ... [Remaining Backup, Restore, Task methods unchanged]
    func restoreBackup(_ backup: AppBackup) {
        let fileManager = FileManager.default
        let backupFolder = backupDirectory.appendingPathComponent(backup.backupPath)
        
        do {
            let contents = try fileManager.contentsOfDirectory(at: backupFolder, includingPropertiesForKeys: nil)
            guard let backedUpApp = contents.first(where: { $0.pathExtension == "app" }) else { return }
            
            let dest = currentAppsFolder.appendingPathComponent(backup.originalInstallPath)
            
            if fileManager.fileExists(atPath: dest.path) {
                try fileManager.removeItem(at: dest)
            }
            
            try fileManager.moveItem(at: backedUpApp, to: dest)
            
            discardBackup(backup)
            refreshInstalledApps()
        } catch {
            print("Restore failed: \(error)")
        }
    }
    
    func discardBackup(_ backup: AppBackup, deleteContainers: Bool = false) {
        let fileManager = FileManager.default
        let backupFolder = backupDirectory.appendingPathComponent(backup.backupPath)
        
        if deleteContainers {
            let backupAppURL = backupFolder.appendingPathComponent(backup.originalInstallPath)
            let lcInfoURL = backupAppURL.appendingPathComponent("LCAppInfo.plist")
            
            if fileManager.fileExists(atPath: lcInfoURL.path),
               let data = try? Data(contentsOf: lcInfoURL),
               let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
               let containers = plist["LCContainers"] as? [[String: Any]],
               let dataAppFolder = currentDataApplicationFolder {
                
                for container in containers {
                    if let folderName = container["folderName"] as? String {
                        let folderURL = dataAppFolder.appendingPathComponent(folderName)
                        try? fileManager.removeItem(at: folderURL)
                        print("Deleted backup container: \(folderName)")
                    }
                }
            }
        }
        
        try? fileManager.removeItem(at: backupFolder)
        
        if let index = pendingBackups.firstIndex(where: { $0.id == backup.id }) {
            pendingBackups.remove(at: index)
            savePendingBackups()
        }
    }
    
    private func restoreFolders() {
        restoreFolder(key: kCustomDownloadFolderKey) { self.customDownloadFolder = $0 }
        restoreFolder(key: kCustomLiveContainerFolderKey) { self.customLiveContainerFolder = $0 }
    }
    
    private func restoreFolder(key: String, assign: (URL) -> Void) {
        guard let data = UserDefaults.standard.data(forKey: key) else { return }
        do {
            var isStale = false
            let url = try URL(resolvingBookmarkData: data, bookmarkDataIsStale: &isStale)
            if isStale {
               _ = url.startAccessingSecurityScopedResource()
               let newData = try url.bookmarkData()
               UserDefaults.standard.set(newData, forKey: key)
               url.stopAccessingSecurityScopedResource()
            }
            if url.startAccessingSecurityScopedResource() {
                assign(url)
            }
        } catch { }
    }
    
    private func reconnectExistingTasks() {
        urlSession.getAllTasks { tasks in
            Task { @MainActor in
                for task in tasks {
                    guard let downloadTask = task as? URLSessionDownloadTask,
                          let url = downloadTask.originalRequest?.url else { continue }
                    
                    self.tasks[url] = downloadTask
                    
                    if downloadTask.state == .running {
                        let written = downloadTask.countOfBytesReceived
                        let expected = downloadTask.countOfBytesExpectedToReceive
                        let p = expected > 0 ? Double(written) / Double(expected) : 0.0
                        self.downloadStates[url] = .downloading(progress: p, written: written, total: expected)
                    } else if downloadTask.state == .suspended {
                        self.downloadStates[url] = .paused
                    }
                }
                
                for (urlStr, _) in self.diskResumeDataPaths {
                    if let url = URL(string: urlStr), self.tasks[url] == nil {
                        self.downloadStates[url] = .paused
                    }
                }
            }
        }
    }
    
    private func restoreResumeDataMapping() {
        if let map = UserDefaults.standard.dictionary(forKey: kResumeDataMapKey) as? [String: String] {
            self.diskResumeDataPaths = map
        }
    }
    
    private func saveResumeDataMapping() {
        UserDefaults.standard.set(diskResumeDataPaths, forKey: kResumeDataMapKey)
    }
    
    private func storeResumeData(_ data: Data, for url: URL) {
        let filename = UUID().uuidString
        let fileURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent(filename)
        do {
            try data.write(to: fileURL)
            diskResumeDataPaths[url.absoluteString] = filename
            saveResumeDataMapping()
            resumeDataMap[url] = data
        } catch {
            print("Failed to save resume data: \(error)")
        }
    }
    
    private func retrieveResumeData(for url: URL) -> Data? {
        if let data = resumeDataMap[url] { return data }
        if let filename = diskResumeDataPaths[url.absoluteString] {
            let fileURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent(filename)
            if let data = try? Data(contentsOf: fileURL) { return data }
        }
        return nil
    }
    
    private func clearResumeData(for url: URL) {
        resumeDataMap[url] = nil
        if let filename = diskResumeDataPaths.removeValue(forKey: url.absoluteString) {
            let fileURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent(filename)
            try? FileManager.default.removeItem(at: fileURL)
            saveResumeDataMapping()
        }
    }
    
    func setCustomFolder(_ url: URL, forApps: Bool) {
        do {
            guard url.startAccessingSecurityScopedResource() else { return }
            defer { url.stopAccessingSecurityScopedResource() }
            let bookmarkData = try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
            let key = forApps ? kCustomLiveContainerFolderKey : kCustomDownloadFolderKey
            UserDefaults.standard.set(bookmarkData, forKey: key)
            
            if forApps {
                self.customLiveContainerFolder = url
                self.isAutoUnzipEnabled = true // Auto-enable as requested
                refreshInstalledApps()
            } else {
                self.customDownloadFolder = url
                refreshFileList()
            }
        } catch {
            print("Failed to save bookmark: \(error)")
        }
    }
    
    func clearCustomFolder(forApps: Bool) {
        let key = forApps ? kCustomLiveContainerFolderKey : kCustomDownloadFolderKey
        UserDefaults.standard.removeObject(forKey: key)
        if forApps {
            self.customLiveContainerFolder = nil
            refreshInstalledApps()
        } else {
            self.customDownloadFolder = nil
            refreshFileList()
        }
    }
    
    func startDownload(url: URL) {
        if getLocalFile(for: url) != nil { return }
        if case .paused = getStatus(for: url) {
            resumeDownload(url: url)
            return
        }
        
        if tasks[url] == nil {
            if let data = retrieveResumeData(for: url) {
                let task = urlSession.downloadTask(withResumeData: data)
                tasks[url] = task
                task.resume()
                downloadStates[url] = .downloading(progress: 0.0, written: 0, total: -1)
            } else {
                let task = urlSession.downloadTask(with: url)
                tasks[url] = task
                task.resume()
                downloadStates[url] = .downloading(progress: 0.0, written: 0, total: -1)
            }
        } else {
            tasks[url]?.resume()
            downloadStates[url] = .downloading(progress: 0.0, written: 0, total: -1)
        }
    }
    
    func pauseDownload(url: URL) {
        guard let task = tasks[url] else { return }
        task.cancel { [weak self] data in
            guard let self = self else { return }
            Task { @MainActor in
                if let resumeData = data { self.storeResumeData(resumeData, for: url) }
                self.downloadStates[url] = .paused
                self.tasks[url] = nil
            }
        }
    }
    
    func resumeDownload(url: URL) {
        if let data = retrieveResumeData(for: url) {
            let task = urlSession.downloadTask(withResumeData: data)
            tasks[url] = task
            task.resume()
            downloadStates[url] = .downloading(progress: 0.0, written: 0, total: -1)
        } else {
            startDownload(url: url)
        }
    }
    
    func cancelDownload(url: URL) {
        tasks[url]?.cancel()
        tasks[url] = nil
        clearResumeData(for: url)
        downloadStates[url] = nil
    }
    
    func isDownloading(url: URL) -> Bool {
        if case .downloading = getStatus(for: url) { return true }
        return false
    }
    
    func isPaused(url: URL) -> Bool {
        if case .paused = getStatus(for: url) { return true }
        return false
    }
    
    func refreshFileList() {
        do {
            let files = try FileManager.default.contentsOfDirectory(at: currentDownloadFolder, includingPropertiesForKeys: nil)
            let filtered = files.filter { !$0.lastPathComponent.hasPrefix(".") && $0.pathExtension != "app" }
            self.fileList = filtered
        } catch { self.fileList = [] }
    }
    
    func refreshInstalledApps() {
        do {
            let files = try FileManager.default.contentsOfDirectory(at: currentAppsFolder, includingPropertiesForKeys: nil)
            var newApps: [LocalApp] = []
            for file in files where file.pathExtension == "app" {
                let plistURL = file.appendingPathComponent("Info.plist")
                var name = file.deletingPathExtension().lastPathComponent
                var bundleID = "unknown"
                var version: String? = nil
                var iconURL: URL? = nil
                
                if let plistData = try? Data(contentsOf: plistURL),
                   let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any] {
                    if let bid = plist["CFBundleIdentifier"] as? String {
                        bundleID = bid.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                    if let displayName = plist["CFBundleDisplayName"] as? String {
                        name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
                    } else if let bundleName = plist["CFBundleName"] as? String {
                        name = bundleName.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                    
                    if let ver = plist["CFBundleShortVersionString"] as? String {
                        version = ver
                    } else if let ver = plist["CFBundleVersion"] as? String {
                        version = ver
                    }
                    
                    var iconFiles: [String] = []
                    if let iconsDict = plist["CFBundleIcons"] as? [String: Any],
                       let primaryIcon = iconsDict["CFBundlePrimaryIcon"] as? [String: Any],
                       let files = primaryIcon["CFBundleIconFiles"] as? [String] {
                        iconFiles.append(contentsOf: files)
                    }
                    if let ipadIconsDict = plist["CFBundleIcons~ipad"] as? [String: Any],
                       let primaryIcon = ipadIconsDict["CFBundlePrimaryIcon"] as? [String: Any],
                       let files = primaryIcon["CFBundleIconFiles"] as? [String] {
                        iconFiles.append(contentsOf: files)
                    }
                    if let legacyFiles = plist["CFBundleIconFiles"] as? [String] {
                        iconFiles.append(contentsOf: legacyFiles)
                    }
                    
                    for iconName in iconFiles.reversed() {
                        if let found = findIconFile(in: file, name: iconName) { iconURL = found; break }
                    }
                    
                    if iconURL == nil {
                        iconURL = findIconFile(in: file, name: "AppIcon60x60") ?? findIconFile(in: file, name: "AppIcon")
                    }
                }
                newApps.append(LocalApp(name: name, bundleID: bundleID, version: version, url: file, iconURL: iconURL))
            }
            self.installedApps = newApps
        } catch { self.installedApps = [] }
    }
    
    private func findIconFile(in folder: URL, name: String) -> URL? {
        let extensions = ["png", "jpg"]
        let candidates = [name, "\(name)@2x", "\(name)@3x", "\(name)60x60@2x"]
        for c in candidates {
            for e in extensions {
                let f = folder.appendingPathComponent("\(c).\(e)")
                if FileManager.default.fileExists(atPath: f.path) { return f }
            }
        }
        return nil
    }
    
    func renameFile(_ fileURL: URL, newName: String) {
        let folder = fileURL.deletingLastPathComponent()
        let newURL = folder.appendingPathComponent(newName)
        do {
            if startAccessing(fileURL) { defer { fileURL.stopAccessingSecurityScopedResource() } }
            if FileManager.default.fileExists(atPath: newURL.path) {
                print("Error: File already exists")
                return
            }
            try FileManager.default.moveItem(at: fileURL, to: newURL)
            refreshFileList()
        } catch {
            print("Rename failed: \(error)")
        }
    }
    
    func deleteFile(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        refreshFileList()
    }
    
    func deleteApp(_ app: LocalApp) {
        let fileManager = FileManager.default
        let lcInfoURL = app.url.appendingPathComponent("LCAppInfo.plist")
        if fileManager.fileExists(atPath: lcInfoURL.path),
           let data = try? Data(contentsOf: lcInfoURL),
           let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
           let containers = plist["LCContainers"] as? [[String: Any]],
           let dataAppFolder = currentDataApplicationFolder {
            for container in containers {
                if let folderName = container["folderName"] as? String {
                    try? fileManager.removeItem(at: dataAppFolder.appendingPathComponent(folderName))
                }
            }
        }
        try? fileManager.removeItem(at: app.url)
        refreshInstalledApps()
    }
    
    func clearAllFiles() {
        try? FileManager.default.contentsOfDirectory(at: currentDownloadFolder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension != "app" }
            .forEach { try? FileManager.default.removeItem(at: $0) }
        refreshFileList()
    }
    
    func convertToApp(file: URL) {
        Task {
            _ = await MainActor.run { self.extractingFiles.insert(file) }
            
            do {
                var accessActive = false
                if file.startAccessingSecurityScopedResource() {
                    accessActive = true
                }
                
                try await extractApp(from: file)
                
                if accessActive {
                    file.stopAccessingSecurityScopedResource()
                    accessActive = false
                }
                
                if self.pendingInstallation == nil {
                    _ = await MainActor.run {
                        self.extractingFiles.remove(file)
                        self.refreshFileList()
                        self.refreshInstalledApps()
                    }
                } else {
                     _ = await MainActor.run { self.extractingFiles.remove(file) }
                }
            } catch {
                print("Convert error: \(error)")
                _ = await MainActor.run { self.extractingFiles.remove(file) }
            }
        }
    }
    
    func importFile(at source: URL) {
        let dest = currentDownloadFolder.appendingPathComponent(source.lastPathComponent)
        do {
            if source.startAccessingSecurityScopedResource() {
                let access = true
                
                if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.removeItem(at: dest) }
                try FileManager.default.copyItem(at: source, to: dest)
                refreshFileList()
                
                if access { source.stopAccessingSecurityScopedResource() }
            }
        } catch {
            print("Import failed: \(error)")
        }
    }
    
    private func extractApp(from sourceURL: URL) async throws {
        let fileManager = FileManager.default
        let folder = self.currentAppsFolder
        if !fileManager.fileExists(atPath: folder.path) {
            try? fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        
        #if canImport(ZIPFoundation)
        let tempUnzipDir = folder.appendingPathComponent("Temp_" + UUID().uuidString)
        try fileManager.createDirectory(at: tempUnzipDir, withIntermediateDirectories: true)
        try fileManager.unzipItem(at: sourceURL, to: tempUnzipDir)
        
        let payloadDir = tempUnzipDir.appendingPathComponent("Payload")
        if fileManager.fileExists(atPath: payloadDir.path) {
            let contents = try fileManager.contentsOfDirectory(at: payloadDir, includingPropertiesForKeys: nil)
            if let appBundle = contents.first(where: { $0.pathExtension == "app" }) {
                
                var targetName = appBundle.lastPathComponent
                var bundleID = "unknown"
                
                let plistURL = appBundle.appendingPathComponent("Info.plist")
                if let plistData = try? Data(contentsOf: plistURL),
                   let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any] {
                    if let bid = plist["CFBundleIdentifier"] as? String {
                        bundleID = bid.trimmingCharacters(in: .whitespacesAndNewlines)
                        targetName = bundleID + ".app"
                    }
                }
                
                if let existingApp = self.installedApps.first(where: { $0.bundleID == bundleID && bundleID != "unknown" }) {
                    _ = await MainActor.run {
                        self.pendingInstallation = PendingInstallation(
                            appName: existingApp.name, 
                            bundleID: bundleID,
                            tempPayloadURL: payloadDir, 
                            extractedAppURL: appBundle,
                            sourceArchiveURL: sourceURL,
                            existingApp: existingApp
                        )
                    }
                    return
                }
                
                var finalURL = folder.appendingPathComponent(targetName)
                if fileManager.fileExists(atPath: finalURL.path) {
                    let nameWithoutExt = finalURL.deletingPathExtension().lastPathComponent
                    var counter = 1
                    while fileManager.fileExists(atPath: finalURL.path) {
                        finalURL = folder.appendingPathComponent("\(nameWithoutExt)_\(counter).app")
                        counter += 1
                    }
                }
                
                try fileManager.moveItem(at: appBundle, to: finalURL)
                
                if sourceURL.path.contains(currentDownloadFolder.path) { try? fileManager.removeItem(at: sourceURL) }
                try? fileManager.removeItem(at: tempUnzipDir)
                
            } else { try? fileManager.removeItem(at: tempUnzipDir) }
        } else { try? fileManager.removeItem(at: tempUnzipDir) }
        #else
        if sourceURL.pathExtension.lowercased() == "ipa" {
            let zipURL = sourceURL.deletingPathExtension().appendingPathExtension("zip")
            if fileManager.fileExists(atPath: zipURL.path) { try fileManager.removeItem(at: zipURL) }
            try fileManager.moveItem(at: sourceURL, to: zipURL)
        }
        #endif
    }
    
    func finalizeInstallation(action: InstallAction) {
        guard let pending = pendingInstallation else { return }
        
        let fileManager = FileManager.default
        let folder = self.currentAppsFolder
        let downloadDir = self.currentDownloadFolder
        let backupDir = self.backupDirectory
        
        Task.detached(priority: .userInitiated) {
            do {
                switch action {
                case .installSeparate:
                    var targetName = pending.extractedAppURL.lastPathComponent
                    if !pending.bundleID.isEmpty && pending.bundleID != "unknown" {
                        targetName = pending.bundleID + ".app"
                    }
                    
                    var finalURL = folder.appendingPathComponent(targetName)
                    let nameWithoutExt = finalURL.deletingPathExtension().lastPathComponent
                    var counter = 1
                    while fileManager.fileExists(atPath: finalURL.path) {
                        finalURL = folder.appendingPathComponent("\(nameWithoutExt)_\(counter).app")
                        counter += 1
                    }
                    
                    try fileManager.moveItem(at: pending.extractedAppURL, to: finalURL)
                    
                case .updateExisting:
                    guard let existing = pending.existingApp else { break }
                    
                    let existingPath = existing.url
                    let lcInfoURL = existingPath.appendingPathComponent("LCAppInfo.plist")
                    let hadInfo = fileManager.fileExists(atPath: lcInfoURL.path)
                    
                    if !hadInfo {
                        if fileManager.fileExists(atPath: existingPath.path) {
                            try fileManager.removeItem(at: existingPath)
                        }
                        try fileManager.moveItem(at: pending.extractedAppURL, to: existingPath)
                    } else {
                        let backupUUID = UUID().uuidString
                        let destFolder = backupDir.appendingPathComponent(backupUUID)
                        try fileManager.createDirectory(at: destFolder, withIntermediateDirectories: true)
                        
                        let backupDest = destFolder.appendingPathComponent(existingPath.lastPathComponent)
                        
                        try fileManager.moveItem(at: existingPath, to: backupDest)
                        
                        let backupRecord = AppBackup(
                            bundleID: existing.bundleID,
                            appName: existing.name,
                            version: existing.version,
                            backupPath: backupUUID,
                            originalInstallPath: existingPath.lastPathComponent,
                            date: Date(),
                            hadLCAppInfo: hadInfo
                        )
                        
                        await MainActor.run {
                            self.pendingBackups.append(backupRecord)
                            self.savePendingBackups()
                        }
                        
                        try fileManager.moveItem(at: pending.extractedAppURL, to: existingPath)
                    }
                    
                case .cancel:
                    break
                }
            } catch {
                print("Finalize install error: \(error)")
            }
            
            let tempRoot = pending.tempPayloadURL.deletingLastPathComponent()
            try? fileManager.removeItem(at: tempRoot)
            
            if action != .cancel, pending.sourceArchiveURL.path.contains(downloadDir.path) {
                try? fileManager.removeItem(at: pending.sourceArchiveURL)
            }
            
            try? await Task.sleep(nanoseconds: 200_000_000)

            await MainActor.run {
                self.pendingInstallation = nil
                self.refreshFileList()
                self.refreshInstalledApps()
            }
        }
    }
    
    private func startAccessing(_ url: URL) -> Bool {
        return url.startAccessingSecurityScopedResource()
    }
}

extension DownloadManager: URLSessionDownloadDelegate {
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let sourceURL = downloadTask.originalRequest?.url else { return }
        let fileManager = FileManager.default
        let stagingURL = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension(sourceURL.pathExtension)
        
        do {
            if fileManager.fileExists(atPath: stagingURL.path) { try fileManager.removeItem(at: stagingURL) }
            try fileManager.moveItem(at: location, to: stagingURL)
        } catch {
            Task { @MainActor in self.downloadStates[sourceURL] = nil }
            return
        }
        
        Task { @MainActor in
            do {
                let manager = FileManager.default
                let folder = self.currentDownloadFolder
                if !manager.fileExists(atPath: folder.path) {
                    try manager.createDirectory(at: folder, withIntermediateDirectories: true)
                }
                
                var finalName = sourceURL.lastPathComponent
                if sourceURL.pathExtension.isEmpty {
                    finalName += ".ipa"
                }
                
                let finalURL = folder.appendingPathComponent(finalName)
                if manager.fileExists(atPath: finalURL.path) { try manager.removeItem(at: finalURL) }
                try manager.moveItem(at: stagingURL, to: finalURL)
                
                self.sendNotification(title: "Download Complete", body: "\(finalName) has been downloaded.")
                
                if self.isAutoUnzipEnabled && finalURL.pathExtension.lowercased() == "ipa" {
                    self.extractingFiles.insert(finalURL)
                    try await self.extractApp(from: finalURL)
                    if self.pendingInstallation == nil {
                        self.extractingFiles.remove(finalURL)
                    }
                }
                
                self.downloadStates[sourceURL] = nil
                self.tasks[sourceURL] = nil
                self.clearResumeData(for: sourceURL)
                self.refreshFileList()
                self.refreshInstalledApps()
            } catch {
                self.downloadStates[sourceURL] = nil
                self.refreshFileList()
                if let fname = sourceURL.lastPathComponent as String?, let furl = self.currentDownloadFolder.appendingPathComponent(fname) as URL? {
                    self.extractingFiles.remove(furl)
                }
            }
        }
    }
    
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let sourceURL = downloadTask.originalRequest?.url else { return }
        let progress = totalBytesExpectedToWrite > 0 ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) : 0.0
        Task { @MainActor in 
            self.downloadStates[sourceURL] = .downloading(progress: progress, written: totalBytesWritten, total: totalBytesExpectedToWrite)
        }
    }
    
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let sourceURL = task.originalRequest?.url else { return }
        if let error = error as NSError? {
            if error.code == NSURLErrorCancelled {
                if let resumeData = error.userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
                    Task { @MainActor in
                        self.storeResumeData(resumeData, for: sourceURL)
                        self.downloadStates[sourceURL] = .paused
                    }
                } else {
                    Task { @MainActor in self.downloadStates[sourceURL] = nil }
                }
                return
            }
            if let resumeData = error.userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
                Task { @MainActor in
                    self.storeResumeData(resumeData, for: sourceURL)
                    self.downloadStates[sourceURL] = .paused
                }
            } else {
                Task { @MainActor in self.downloadStates[sourceURL] = nil }
            }
        }
    }
    
    nonisolated func urlSession(_ session: URLSession, taskIsWaitingForConnectivity task: URLSessionTask) {
        if let url = task.originalRequest?.url {
            Task { @MainActor in self.downloadStates[url] = .waitingForConnection }
        }
    }
    
    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in
            if let handler = self.backgroundCompletionHandler {
                self.backgroundCompletionHandler = nil
                handler()
            }
        }
    }
}

