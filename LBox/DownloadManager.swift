import Foundation
import SwiftUI
import Combine
import UserNotifications
#if canImport(ZIPFoundation)
import ZIPFoundation
#endif

// Make Equatable for UI comparisons
enum DownloadStatus: Equatable {
    // Changed to include byte counts
    case downloading(progress: Double, written: Int64, total: Int64)
    case paused
    case waitingForConnection
    case none
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
    
    var isAutoUnzipEnabled: Bool {
        return UserDefaults.standard.bool(forKey: "kAutoUnzipEnabled")
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
    
    // URL String -> Filename in Caches
    private var diskResumeDataPaths: [String: String] = [:]
    
    override init() {
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
        reconnectExistingTasks()
        refreshFileList()
        refreshInstalledApps()
    }
    
    func getStatus(for url: URL) -> DownloadStatus {
        return downloadStates[url] ?? .none
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
    
    func getLocalFile(for url: URL) -> URL? {
        // Enforce .ipa check logic alignment with download naming
        var name = url.lastPathComponent
        if url.pathExtension.isEmpty { name += ".ipa" }
        
        let dest = currentDownloadFolder.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: dest.path) { return dest }
        
        // Also check if original name was used
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
    
    // MARK: - Restoration
    
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
    
    // MARK: - Resume Data
    
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
    
    // MARK: - Folder Setters
    
    func setCustomFolder(_ url: URL, forApps: Bool) {
        do {
            guard url.startAccessingSecurityScopedResource() else { return }
            defer { url.stopAccessingSecurityScopedResource() }
            let bookmarkData = try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
            let key = forApps ? kCustomLiveContainerFolderKey : kCustomDownloadFolderKey
            UserDefaults.standard.set(bookmarkData, forKey: key)
            
            if forApps {
                self.customLiveContainerFolder = url
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
    
    // MARK: - Actions
    
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
    
    // MARK: - File Operations
    
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
                var iconURL: URL? = nil
                
                if let plistData = try? Data(contentsOf: plistURL),
                   let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any] {
                    if let bid = plist["CFBundleIdentifier"] as? String { bundleID = bid }
                    if let displayName = plist["CFBundleDisplayName"] as? String { name = displayName }
                    else if let bundleName = plist["CFBundleName"] as? String { name = bundleName }
                    
                    // Icon logic
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
                newApps.append(LocalApp(name: name, bundleID: bundleID, url: file, iconURL: iconURL))
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
            // If target exists, fail or overwrite (logic here fails)
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
            // Track extraction state
            await MainActor.run { self.extractingFiles.insert(file) }
            defer { Task { @MainActor in self.extractingFiles.remove(file) } }
            
            do {
                if file.startAccessingSecurityScopedResource() {
                    defer { file.stopAccessingSecurityScopedResource() }
                    try extractApp(from: file)
                } else {
                    try extractApp(from: file)
                }
                await MainActor.run {
                    self.refreshFileList()
                    self.refreshInstalledApps()
                }
            } catch {
                print("Convert error: \(error)")
            }
        }
    }
    
    // Explicitly import a file from file picker
    func importFile(at source: URL) {
        let dest = currentDownloadFolder.appendingPathComponent(source.lastPathComponent)
        do {
            if source.startAccessingSecurityScopedResource() {
                defer { source.stopAccessingSecurityScopedResource() }
                if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.removeItem(at: dest) }
                try FileManager.default.copyItem(at: source, to: dest)
                refreshFileList()
            }
        } catch {
            print("Import failed: \(error)")
        }
    }
    
    private func extractApp(from sourceURL: URL) throws {
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
                let plistURL = appBundle.appendingPathComponent("Info.plist")
                if let plistData = try? Data(contentsOf: plistURL),
                   let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any],
                   let bundleID = plist["CFBundleIdentifier"] as? String {
                    targetName = bundleID + ".app"
                }
                let targetAppURL = folder.appendingPathComponent(targetName)
                if fileManager.fileExists(atPath: targetAppURL.path) { try fileManager.removeItem(at: targetAppURL) }
                try fileManager.moveItem(at: appBundle, to: targetAppURL)
                
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
                
                // Determine Final Filename
                var finalName = sourceURL.lastPathComponent
                if sourceURL.pathExtension.isEmpty {
                    finalName += ".ipa" // Added constraint: Ensure .ipa if extension missing
                }
                
                let finalURL = folder.appendingPathComponent(finalName)
                if manager.fileExists(atPath: finalURL.path) { try manager.removeItem(at: finalURL) }
                try manager.moveItem(at: stagingURL, to: finalURL)
                
                self.sendNotification(title: "Download Complete", body: "\(finalName) has been downloaded.")
                
                if self.isAutoUnzipEnabled && finalURL.pathExtension.lowercased() == "ipa" {
                    // Extract with state tracking
                    self.extractingFiles.insert(finalURL)
                    try self.extractApp(from: finalURL)
                    self.extractingFiles.remove(finalURL)
                }
                
                self.downloadStates[sourceURL] = nil
                self.tasks[sourceURL] = nil
                self.clearResumeData(for: sourceURL)
                self.refreshFileList()
                self.refreshInstalledApps()
            } catch {
                self.downloadStates[sourceURL] = nil
                self.refreshFileList()
                // Ensure state is cleared if error occurs
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
