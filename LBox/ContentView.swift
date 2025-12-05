import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var viewModel = AppStoreViewModel()
    @StateObject private var downloadManager = DownloadManager()
    
    // First Launch / Setup State
    @State private var showSetupAlert = false
    @State private var showSetupPicker = false
    @AppStorage("kHasAskedForLiveContainerSetup") private var hasAskedForSetup = false
    
    var body: some View {
        TabView {
            StoreView(viewModel: viewModel)
                .tabItem { Label("Store", systemImage: "bag") }
            
            InstalledAppsView()
                .tabItem { Label("Apps", systemImage: "square.grid.2x2") }
            
            DirectDownloadView(viewModel: viewModel)
                .tabItem { Label("Download", systemImage: "arrow.down.circle") }
            
            SettingsView(viewModel: viewModel)
                .tabItem { Label("Settings", systemImage: "gear") }
        }
        .environmentObject(downloadManager)
        .task {
            if viewModel.displayApps.isEmpty { await viewModel.fetchAllRepos() }
            downloadManager.refreshFileList()
            downloadManager.refreshInstalledApps()
            
            // Slight delay to ensure UI is ready
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            
            // Check if we need to prompt for LiveContainer folder
            if !hasAskedForSetup && downloadManager.customLiveContainerFolder == nil {
                showSetupAlert = true
            }
        }
        .alert("Setup LiveContainer", isPresented: $showSetupAlert) {
            Button("Select Folder") {
                hasAskedForSetup = true
                showSetupPicker = true
            }
            Button("Later", role: .cancel) {
                hasAskedForSetup = true
            }
        } message: {
            Text("To enable auto-installation and launching, please select your LiveContainer storage directory.")
        }
        .fileImporter(isPresented: $showSetupPicker, allowedContentTypes: [.folder]) { res in
            if case .success(let url) = res {
                downloadManager.setCustomFolder(url, forApps: true)
            }
        }
    }
}

// MARK: - Store View
struct StoreView: View {
    @ObservedObject var viewModel: AppStoreViewModel
    var body: some View {
        NavigationStack {
            List {
                // Progress indicator for repo fetching
                if viewModel.isLoading && viewModel.fetchTotal > 0 {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Updating Repositories...")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        ProgressView(value: Double(viewModel.fetchProgress), total: Double(viewModel.fetchTotal))
                            .progressViewStyle(.linear)
                        HStack {
                            Spacer()
                            Text("\(viewModel.fetchProgress)/\(viewModel.fetchTotal)")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }
                
                if !viewModel.savedRepos.isEmpty {
                    Picker("Source", selection: $viewModel.selectedRepoID) {
                        Text("All Sources").tag(String?.none)
                        ForEach(viewModel.getEnabledLeafRepos()) { repo in
                            Text(repo.name).tag(repo.name as String?)
                        }
                    }
                    .pickerStyle(.menu).listRowBackground(Color.clear).padding(.bottom, 5)
                }
                ForEach(viewModel.filteredApps) { app in
                    NavigationLink(destination: AppDetailView(app: app, viewModel: viewModel)) {
                        AppListRow(app: app)
                    }
                }
            }
            .navigationTitle("Store")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Picker("Sort By", selection: $viewModel.appSortOrder) {
                            ForEach(AppSortOption.allCases) { option in
                                Text(option.rawValue).tag(option)
                            }
                        }
                    } label: {
                        Image(systemName: "arrow.up.arrow.down")
                    }
                }
            }
            .searchable(text: $viewModel.searchText, prompt: "Search apps, bundles...")
            .refreshable { await viewModel.fetchAllRepos() }
        }
    }
}

struct AppListRow: View {
    let app: AppItem
    @EnvironmentObject var downloadManager: DownloadManager
    var body: some View {
        HStack(spacing: 16) {
            AsyncImage(url: URL(string: app.iconURL ?? "")) { phase in
                if let image = phase.image { image.resizable() } else { Color.gray.opacity(0.2) }
            }.aspectRatio(contentMode: .fill).frame(width: 60, height: 60).clipShape(RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(app.name).font(.headline).lineLimit(1)
                    if downloadManager.isAppInstalled(bundleID: app.bundleIdentifier) {
                        Text("INSTALLED").font(.system(size: 9, weight: .bold)).padding(4).background(Color.gray.opacity(0.2)).clipShape(Capsule())
                    }
                }
                if let r = app.sourceRepoName { Text("via " + r).font(.caption2).foregroundColor(.blue) }
                if let d = app.localizedDescription { Text(d).font(.caption).foregroundColor(.secondary).lineLimit(2) }
            }
            Spacer()
        }.padding(.vertical, 4)
    }
}

struct InstalledAppsView: View {
    @EnvironmentObject var downloadManager: DownloadManager
    let columns = [GridItem(.adaptive(minimum: 80, maximum: 100), spacing: 20)]
    var body: some View {
        NavigationStack {
            ScrollView {
                if downloadManager.installedApps.isEmpty {
                    ContentUnavailableView("No Apps", systemImage: "square.dashed", description: Text("Apps extracted to the applications folder will appear here."))
                        .padding(.top, 50)
                } else {
                    LazyVGrid(columns: columns, spacing: 24) {
                        ForEach(downloadManager.installedApps) { app in
                            InstalledAppItem(app: app)
                        }
                    }.padding()
                }
            }.navigationTitle("Apps").refreshable { downloadManager.refreshInstalledApps() }
        }
    }
}

struct InstalledAppItem: View {
    let app: LocalApp
    @EnvironmentObject var downloadManager: DownloadManager
    var body: some View {
        Button {
            let urlString = "livecontainer://livecontainer-launch?bundle-name=\(app.url.lastPathComponent)"
            if let url = URL(string: urlString) { UIApplication.shared.open(url) }
        } label: {
            VStack(spacing: 10) {
                if let icon = app.iconURL, let data = try? Data(contentsOf: icon), let img = UIImage(data: data) {
                    Image(uiImage: img).resizable().frame(width: 70, height: 70).cornerRadius(14)
                } else {
                    Image(systemName: "app.fill").resizable().frame(width: 70, height: 70).foregroundColor(.gray).cornerRadius(14)
                }
                Text(app.name).font(.caption).lineLimit(2).frame(height: 35, alignment: .top)
            }
        }.buttonStyle(.plain).contextMenu {
            Button(role: .destructive) { downloadManager.deleteApp(app) } label: { Label("Delete App", systemImage: "trash") }
        }
    }
}

// MARK: - Updated DirectDownloadView with Rename
struct DirectDownloadView: View {
    @ObservedObject var viewModel: AppStoreViewModel
    @EnvironmentObject var downloadManager: DownloadManager
    @State private var urlString = ""
    @State private var renamingFile: URL?
    @State private var newFileName = ""
    @State private var showFileImporter = false
    
    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("https://example.com/app.ipa", text: $urlString)
                        .textInputAutocapitalization(.never).keyboardType(.URL).autocorrectionDisabled()
                    Button("Download") {
                        let s = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
                        let final = (!s.lowercased().hasPrefix("http") ? "https://" + s : s)
                        if let url = URL(string: final) { downloadManager.startDownload(url: url); urlString = "" }
                    }.disabled(urlString.isEmpty)
                } header: { Text("Download from URL") }
                
                if !downloadManager.downloadStates.isEmpty {
                    Section {
                        ForEach(downloadManager.downloadStates.keys.sorted(by: { $0.absoluteString < $1.absoluteString }), id: \.self) { url in
                            DownloadRow(url: url, status: downloadManager.getStatus(for: url), viewModel: viewModel)
                        }
                    } header: { Text("Active Downloads") }
                }
                
                Section {
                    ForEach(downloadManager.fileList, id: \.self) { file in 
                        FileRow(localURL: file, onRename: {
                            renamingFile = file
                            newFileName = file.lastPathComponent
                        }) 
                    }
                    .onDelete { idx in idx.forEach { downloadManager.deleteFile(downloadManager.fileList[$0]) } }
                } header: {
                    HStack {
                        Text("Files")
                        Spacer()
                        if !downloadManager.fileList.isEmpty {
                            Button("Clear All") { downloadManager.clearAllFiles() }.font(.caption).foregroundColor(.red)
                        }
                    }
                } footer: {
                    Text("Loc: \(downloadManager.customDownloadFolder?.lastPathComponent ?? "Default")")
                }
            }
            .navigationTitle("Direct Download")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: { showFileImporter = true }) {
                        Image(systemName: "square.and.arrow.down")
                    }
                }
            }
            .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.data, .archive]) { res in
                if case .success(let url) = res {
                    downloadManager.importFile(at: url)
                }
            }
            .refreshable { downloadManager.refreshFileList() }
            .alert("Rename File", isPresented: Binding(get: { renamingFile != nil }, set: { if !$0 { renamingFile = nil } })) {
                TextField("Filename.ipa", text: $newFileName)
                Button("Cancel", role: .cancel) { renamingFile = nil }
                Button("Save") {
                    if let file = renamingFile {
                        downloadManager.renameFile(file, newName: newFileName)
                    }
                    renamingFile = nil
                }
            }
        }
    }
}

struct DownloadRow: View {
    let url: URL
    let status: DownloadStatus
    var viewModel: AppStoreViewModel? = nil
    @EnvironmentObject var downloadManager: DownloadManager
    
    func getFallbackTotalSize() -> Int64? {
        guard let vm = viewModel else { return nil }
        for (_, apps) in vm.allAppsByVariant {
            if let match = apps.first(where: { $0.downloadURL == url.absoluteString }) {
                return match.size
            }
        }
        return nil
    }
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.down.doc.fill").font(.title2).foregroundColor(.blue)
            VStack(alignment: .leading, spacing: 4) {
                Text(url.lastPathComponent).fontWeight(.medium).lineLimit(1).truncationMode(.middle)
                switch status {
                case .downloading(let p, let written, let total):
                    HStack(spacing: 4) {
                        Text("\(Int(p * 100))%")
                        Text("•")
                        if total > 0 {
                            Text("\(format(written)) / \(format(total))")
                        } else {
                            if let fallback = getFallbackTotalSize() {
                                Text("\(format(written)) / \(format(fallback))")
                            } else {
                                Text(format(written))
                            }
                        }
                    }
                    .font(.caption).foregroundColor(.secondary)
                case .paused:
                    Text("Paused").font(.caption).foregroundColor(.orange)
                case .waitingForConnection:
                    Text("Waiting...").font(.caption).foregroundColor(.red)
                case .none:
                    EmptyView()
                }
            }
            Spacer()
            Button {
                if case .paused = status { downloadManager.resumeDownload(url: url) }
                else if case .waitingForConnection = status { downloadManager.pauseDownload(url: url) }
                else { downloadManager.pauseDownload(url: url) }
            } label: {
                ZStack {
                    Circle().stroke(lineWidth: 3).opacity(0.3).foregroundColor(.blue)
                    if case .downloading(let p, _, _) = status {
                        Circle().trim(from: 0.0, to: CGFloat(max(0.01, p))).stroke(style: StrokeStyle(lineWidth: 3, lineCap: .round)).rotationEffect(.degrees(270)).foregroundColor(.blue)
                    }
                    Image(systemName: (status == .paused || status == .waitingForConnection) ? "play.fill" : "pause.fill").font(.system(size: 10))
                }.frame(width: 28, height: 28)
            }.buttonStyle(.plain)
            Button { downloadManager.cancelDownload(url: url) } label: { Image(systemName: "xmark.circle.fill").foregroundColor(.gray).font(.title3) }.buttonStyle(.plain)
        }.padding(.vertical, 4)
    }
    
    func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

// MARK: - Updated FileRow with Rename
struct FileRow: View {
    let localURL: URL
    @EnvironmentObject var manager: DownloadManager
    @State private var showShare = false
    @State private var tempURL: URL?
    var onRename: (() -> Void)? = nil 
    
    var isExtracting: Bool { manager.extractingFiles.contains(localURL) }
    
    var body: some View {
        HStack {
            Image(systemName: isArchive ? "archivebox.fill" : "doc.fill").foregroundStyle(.blue)
            VStack(alignment: .leading) {
                Text(localURL.lastPathComponent).lineLimit(1)
                if isExtracting {
                    Text("Extracting...").font(.caption2).foregroundColor(.secondary)
                }
            }
            Spacer()
            
            if isExtracting {
                ProgressView().scaleEffect(0.8).padding(.trailing, 8)
            } else {
                // Quick Action: Share
                Button {
                    tempURL = prepareShare(localURL); showShare = true
                } label: { Image(systemName: "square.and.arrow.up").foregroundStyle(.blue) }.buttonStyle(.plain)
            }
        }
        .contextMenu {
            if let onRename = onRename {
                Button { onRename() } label: { Label("Rename", systemImage: "pencil") }
            }
            Button(role: .destructive) { manager.deleteFile(localURL) } label: { Label("Delete", systemImage: "trash") }
            if isArchive {
                Button { manager.convertToApp(file: localURL) } label: { Label("Convert to .app", systemImage: "cube") }
            }
            Button {
                tempURL = prepareShare(localURL); showShare = true
            } label: { Label("Share", systemImage: "square.and.arrow.up") }
        }
        .disabled(isExtracting) // Disable context menu if busy
        .sheet(isPresented: $showShare) { if let u = tempURL { ShareSheet(activityItems: [u]) } }
    }
    var isArchive: Bool {
        let ext = localURL.pathExtension.lowercased()
        return ext == "ipa" || ext == "zip"
    }
    func prepareShare(_ url: URL) -> URL? {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent(url.lastPathComponent)
        try? FileManager.default.createDirectory(at: tmp.deletingLastPathComponent(), withIntermediateDirectories: true)
        _ = url.startAccessingSecurityScopedResource()
        try? FileManager.default.copyItem(at: url, to: tmp)
        url.stopAccessingSecurityScopedResource()
        return tmp
    }
}

struct SettingsView: View {
    @ObservedObject var viewModel: AppStoreViewModel
    @EnvironmentObject var dm: DownloadManager
    @State private var pickDL = false
    @State private var pickApps = false
    @State private var confirmReset = false
    @State private var showExporter = false
    @State private var showImporter = false
    @State private var exportJSONString = ""
    @State private var showCopyAlert = false
    
    var body: some View {
        NavigationStack {
            List {
                Section("Directories") {
                    HStack { Text("Downloads"); Spacer(); if dm.customDownloadFolder != nil { Button("Default") { dm.clearCustomFolder(forApps: false) }.buttonStyle(.bordered) }; Button("Select") { pickDL = true } }
                    HStack { Text("LiveContainer"); Spacer(); if dm.customLiveContainerFolder != nil { Button("Default") { dm.clearCustomFolder(forApps: true) }.buttonStyle(.bordered) }; Button("Select") { pickApps = true } }
                    Toggle("Auto .ipa to .app", isOn: $viewModel.isAutoUnzipEnabled)
                }
                
                Section("Repositories") {
                    NavigationLink("Manage Sources") {
                        RepoManagementView(viewModel: viewModel, parentID: nil)
                    }
                    Picker("Sort Repos By", selection: $viewModel.repoSortOrder) {
                        ForEach(RepoSortOption.allCases) { option in
                            Text(option.rawValue).tag(option)
                        }
                    }
                }
                
                Section("Backup/Restore") {
                    Menu("Export Repos...") {
                        Button("Copy as JSON") {
                            if viewModel.savedRepos.contains(where: { $0.hasDisabledContentRecursive }) {
                                showCopyAlert = true
                            } else {
                                if let s = viewModel.exportReposJSON() { UIPasteboard.general.string = s }
                            }
                        }
                        Button("Copy as URL List") {
                            UIPasteboard.general.string = viewModel.exportReposURLList()
                        }
                        Button("Share JSON File") {
                            if let s = viewModel.exportReposJSON() {
                                exportJSONString = s
                                showExporter = true
                            }
                        }
                    }
                    Button("Import Repos (JSON)") {
                        showImporter = true
                    }
                }
                
                Section("About") {
                    Text("LBox v1.0")
                    Button("Reset to Defaults") { confirmReset = true }.foregroundColor(.red)
                }
            }
            .navigationTitle("Settings")
            .fileImporter(isPresented: $pickDL, allowedContentTypes: [.folder]) { res in 
                if case .success(let url) = res { dm.setCustomFolder(url, forApps: false) } 
            }
            .fileImporter(isPresented: $pickApps, allowedContentTypes: [.folder]) { res in 
                if case .success(let url) = res { dm.setCustomFolder(url, forApps: true) } 
            }
            .alert("Reset?", isPresented: $confirmReset) {
                Button("Cancel", role: .cancel) {}
                Button("Reset", role: .destructive) { viewModel.resetReposToDefault() }
            }
            .confirmationDialog("Copy Options", isPresented: $showCopyAlert) {
                Button("Copy All") {
                    if let s = viewModel.exportReposJSON(onlyEnabled: false) { UIPasteboard.general.string = s }
                }
                Button("Only Enabled") {
                    if let s = viewModel.exportReposJSON(onlyEnabled: true) { UIPasteboard.general.string = s }
                }
                Button("Cancel", role: .cancel) {}
            } message: { Text("Some repositories are disabled. Which would you like to copy?") }
            .sheet(isPresented: $showExporter) {
                ShareSheet(activityItems: [exportJSONString])
            }
            .sheet(isPresented: $showImporter) {
                ImportJSONView(viewModel: viewModel)
            }
        }
    }
}

// MARK: - RepoManagementView (Refactored)
struct RepoManagementView: View {
    @ObservedObject var viewModel: AppStoreViewModel
    let parentID: String?
    
    @State private var showAdd = false
    @State private var showCopyAlert = false
    @State private var pendingCopyRepo: SavedRepo? = nil
    @State private var copyMode: CopyMode = .json
    @State private var showRenameAlert = false
    @State private var renameText = ""
    @State private var pendingRenameRepo: SavedRepo? = nil
    @State private var showMoveSheet = false
    @State private var pendingMoveRepo: SavedRepo? = nil
    
    enum CopyMode { case json, url }
    
    // Explicitly computed from VM to avoid binding issues with hierarchy
    var displayedRepos: [SavedRepo] {
        viewModel.getRepos(in: parentID)
    }
    
    var body: some View {
        List {
            ForEach(displayedRepos) { repo in
                HStack {
                    if repo.isFolder {
                        NavigationLink(destination: RepoManagementView(viewModel: viewModel, parentID: repo.id)) {
                            HStack {
                                Image(systemName: "folder.fill").foregroundColor(.blue)
                                VStack(alignment: .leading) {
                                    Text(repo.name).foregroundColor(repo.isEnabled ? .primary : .secondary)
                                    Text("\(repo.totalAppCount) apps").font(.caption).foregroundColor(.secondary)
                                }
                            }
                        }
                        Spacer()
                        // Toggle folder enabled state
                        Toggle("", isOn: Binding(
                            get: { repo.isEnabled },
                            set: { val in viewModel.setRepoEnabled(id: repo.id, enabled: val) }
                        )).labelsHidden()
                    } else {
                        if case .loading = repo.fetchStatus {
                            ProgressView().scaleEffect(0.5).frame(width: 30, height: 30)
                        } else if case .error = repo.fetchStatus {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.red).frame(width: 30, height: 30)
                        } else if case .waiting = repo.fetchStatus {
                            Image(systemName: "clock.fill").foregroundColor(.gray).frame(width: 30, height: 30)
                        } else {
                            AsyncImage(url: URL(string: repo.iconURL ?? "")) { p in
                                if let i = p.image { i.resizable() } else { Image(systemName: "server.rack") }
                            }.frame(width: 30, height: 30).cornerRadius(6)
                        }
                        
                        VStack(alignment: .leading) {
                            Text(repo.name).foregroundColor(repo.isEnabled ? .primary : .secondary)
                            Text(repo.url?.absoluteString ?? "").font(.caption).foregroundColor(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Text("\(repo.appCount)").font(.caption).foregroundColor(.secondary)
                        
                        // Toggle Repo
                        Toggle("", isOn: Binding(
                            get: { repo.isEnabled },
                            set: { val in viewModel.setRepoEnabled(id: repo.id, enabled: val) }
                        )).labelsHidden()
                    }
                }
                .contextMenu {
                    if repo.isFolder {
                        Button {
                            pendingRenameRepo = repo
                            renameText = repo.name
                            showRenameAlert = true
                        } label: { Label("Rename", systemImage: "pencil") }
                    }
                    
                    Button {
                        pendingMoveRepo = repo
                        showMoveSheet = true
                    } label: { Label("Move...", systemImage: "folder.badge.gear") }
                    
                    Button("Copy URLs") {
                        if repo.hasDisabledContentRecursive {
                            pendingCopyRepo = repo; copyMode = .url; showCopyAlert = true
                        } else {
                            UIPasteboard.general.string = repo.allURLs(onlyEnabled: false)
                        }
                    }
                    Button("Copy JSON") {
                        if repo.hasDisabledContentRecursive {
                            pendingCopyRepo = repo; copyMode = .json; showCopyAlert = true
                        } else {
                            if let s = viewModel.exportSingleRepoJSON(repo, onlyEnabled: false) { UIPasteboard.general.string = s }
                        }
                    }
                    Button(role: .destructive) { viewModel.deleteRepo(id: repo.id) } label: {
                        Label(repo.isFolder ? "Delete Folder" : "Delete", systemImage: "trash")
                    }
                }
            }
            // Use VM method for deletion to handle recursive removal safely
            .onDelete { offsets in
                offsets.forEach { index in
                    if index < displayedRepos.count {
                        viewModel.deleteRepo(id: displayedRepos[index].id)
                    }
                }
            }
        }
        .navigationTitle("Repos")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                HStack {
                    EditButton()
                    Button(action: { showAdd = true }) { Image(systemName: "plus") }
                }
            }
        }
        .sheet(isPresented: $showAdd) {
            AddRepoSheet(viewModel: viewModel, parentID: parentID)
        }
        .sheet(isPresented: $showMoveSheet) {
            if let moveItem = pendingMoveRepo {
                MoveRepoSheet(itemToMove: moveItem, viewModel: viewModel)
            }
        }
        .alert("Rename Folder", isPresented: $showRenameAlert) {
            TextField("New Name", text: $renameText)
            Button("Cancel", role: .cancel) { pendingRenameRepo = nil }
            Button("Save") {
                if let r = pendingRenameRepo { viewModel.renameRepo(id: r.id, newName: renameText) }
                pendingRenameRepo = nil
            }
        }
        .confirmationDialog("Copy Options", isPresented: $showCopyAlert, titleVisibility: .visible) {
            Button("Copy All") { performCopy(all: true) }
            Button("Only Enabled") { performCopy(all: false) }
            Button("Cancel", role: .cancel) { pendingCopyRepo = nil }
        } message: { Text("This item contains disabled content.") }
    }
    
    func performCopy(all: Bool) {
        guard let repo = pendingCopyRepo else { return }
        if copyMode == .json {
            if let s = viewModel.exportSingleRepoJSON(repo, onlyEnabled: !all) { UIPasteboard.general.string = s }
        } else {
            UIPasteboard.general.string = repo.allURLs(onlyEnabled: !all)
        }
        pendingCopyRepo = nil
    }
}
struct MoveRepoSheet: View {
    let itemToMove: SavedRepo
    @ObservedObject var viewModel: AppStoreViewModel
    @Environment(\.dismiss) var dismiss
    
    var body: some View {
        NavigationStack {
            List {
                Button {
                    viewModel.moveRepo(id: itemToMove.id, toParentId: nil)
                    dismiss()
                } label: {
                    HStack {
                        Image(systemName: "house.fill")
                        Text("Root")
                    }
                }
                
                Section("Folders") {
                    ForEach(viewModel.getFolderTargets(excludingId: itemToMove.id)) { folder in
                        Button {
                            viewModel.moveRepo(id: itemToMove.id, toParentId: folder.id)
                            dismiss()
                        } label: {
                            HStack {
                                Image(systemName: "folder")
                                Text(folder.name)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Move to...")
            .toolbar { Button("Cancel") { dismiss() } }
        }
    }
}

struct AddRepoSheet: View {
    @ObservedObject var viewModel: AppStoreViewModel
    let parentID: String?
    @Environment(\.dismiss) var dismiss
    @State private var mode = 0
    @State private var textInput = ""
    @State private var folderName = ""
    
    var body: some View {
        NavigationStack {
            Form {
                Picker("Add", selection: $mode) {
                    Text("Sources").tag(0)
                    Text("Folder").tag(1)
                }.pickerStyle(.segmented)
                
                if mode == 0 {
                    Section(header: Text("URLs (One per line)")) {
                        TextEditor(text: $textInput).frame(height: 150)
                            .autocorrectionDisabled().textInputAutocapitalization(.never)
                        Button("Paste from Clipboard") {
                            if let s = UIPasteboard.general.string { textInput = s }
                        }
                    }
                } else {
                    Section(header: Text("New Folder")) {
                        TextField("Name", text: $folderName)
                    }
                }
            }
            .navigationTitle("Add")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if mode == 0 {
                            let lines = textInput.components(separatedBy: .newlines)
                            for line in lines {
                                let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
                                if !t.isEmpty {
                                    let fixed = (!t.lowercased().hasPrefix("http") ? "https://" + t : t)
                                    if let u = URL(string: fixed) {
                                        viewModel.addRepo(url: u, parentID: parentID)
                                    }
                                }
                            }
                        } else {
                            if !folderName.isEmpty {
                                viewModel.addFolder(name: folderName, parentID: parentID)
                            }
                        }
                        dismiss()
                    }
                }
            }
        }
    }
}

struct ImportJSONView: View {
    @ObservedObject var viewModel: AppStoreViewModel
    @Environment(\.dismiss) var dismiss
    @State private var text = ""
    var body: some View {
        NavigationStack {
            Form {
                TextEditor(text: $text).frame(height: 300)
                Button("Paste") { if let s = UIPasteboard.general.string { text = s } }
            }
            .navigationTitle("Import JSON")
            .toolbar {
                Button("Import") {
                    viewModel.importReposJSON(text)
                    dismiss()
                }
            }
        }
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

