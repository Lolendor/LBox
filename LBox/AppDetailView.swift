import SwiftUI

struct AppDetailView: View {
    let app: AppItem
    @ObservedObject var viewModel: AppStoreViewModel
    @EnvironmentObject var downloadManager: DownloadManager
    
    // Helper to extract versions cleanly and avoid compiler confusion in ViewBuilder
    private var versionHistory: [AppItem] {
        return viewModel.getVersions(for: app)
    }
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // App Header
                headerSection
                
                Divider().padding(.horizontal)
                
                // Screenshots
                if !app.screenshotURLs.isEmpty {
                    screenshotsSection
                    Divider().padding(.horizontal)
                }
                
                // Description
                aboutSection
                
                Divider().padding(.horizontal)
                
                // Versions Section
                versionsSection
                    .padding(.bottom, 40)
            }
            .padding(.top)
        }
        .navigationBarTitleDisplayMode(.inline)
    }
    
    var headerSection: some View {
        HStack(alignment: .top, spacing: 16) {
            AsyncImage(url: URL(string: app.iconURL ?? "")) { phase in
                if let image = phase.image {
                    image.resizable()
                } else if phase.error != nil {
                    Color.gray
                } else {
                    Color.gray.opacity(0.3)
                }
            }
            .frame(width: 100, height: 100)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .shadow(radius: 2)
            
            VStack(alignment: .leading, spacing: 6) {
                Text(app.name)
                    .font(.title2)
                    .fontWeight(.bold)
                
                Text(app.bundleIdentifier)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                
                // New: Display App Size and Version
                HStack(spacing: 4) {
                    Text("v\(app.version)")
                    if let size = app.size {
                        Text("•")
                        Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                    }
                }
                .font(.caption)
                .foregroundColor(.secondary)
                
                if let repo = app.sourceRepoName {
                     Text(repo)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.blue.opacity(0.1))
                        .foregroundColor(.blue)
                        .cornerRadius(4)
                }
                
                // Action Buttons Row
                HStack(spacing: 12) {
                    // 1. Download/Status Button
                    DownloadButton(app: app)
                    
                    // 2. Open Button
                    if downloadManager.isAppInstalled(bundleID: app.bundleIdentifier) {
                        Button {
                            launchApp(bundleID: app.bundleIdentifier)
                        } label: {
                            Text("OPEN")
                                .font(.headline.bold())
                                .foregroundColor(.white)
                                .padding(.horizontal, 24)
                                .padding(.vertical, 6)
                                .background(Color.blue)
                                .clipShape(Capsule())
                        }
                    }
                }
                .padding(.top, 4)
            }
            Spacer()
        }
        .padding(.horizontal)
    }
    
    var screenshotsSection: some View {
        VStack(alignment: .leading) {
            Text("Preview")
                .font(.headline)
                .padding(.horizontal)
            
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(app.screenshotURLs, id: \.self) { urlString in
                        AsyncImage(url: URL(string: urlString)) { phase in
                            if let image = phase.image {
                                image.resizable()
                                    .aspectRatio(contentMode: .fit)
                            } else {
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(Color.gray.opacity(0.1))
                                    .frame(width: 200, height: 350)
                            }
                        }
                        .frame(height: 350)
                        .cornerRadius(12)
                    }
                }
                .padding(.horizontal)
            }
        }
    }
    
    var aboutSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("About")
                .font(.headline)
            Text(app.localizedDescription ?? "No description available.")
                .font(.body)
                .foregroundColor(.primary)
        }
        .padding(.horizontal)
    }
    
    var versionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Version History")
                .font(.headline)
                .padding(.horizontal)
            
            // Use the computed property to fix compiler error
            ForEach(versionHistory) { versionApp in
                VersionRow(app: versionApp)
            }
        }
    }
    
    // Launch Logic matching InstalledAppItem
    func launchApp(bundleID: String) {
        if let installedApp = downloadManager.installedApps.first(where: { $0.bundleID == bundleID }) {
            let folderName = installedApp.url.lastPathComponent
            let urlString = "livecontainer://livecontainer-launch?bundle-name=\(folderName)"
            if let url = URL(string: urlString) {
                UIApplication.shared.open(url)
            }
        }
    }
}

// Separate row for versions
struct VersionRow: View {
    let app: AppItem
    
    var body: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading) {
                Text("Version \(app.version)")
                    .fontWeight(.semibold)
                
                HStack(spacing: 4) {
                    Text(app.versionDate ?? "Unknown Date")
                    
                    if let size = app.size {
                        Text("•")
                        Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                    }
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }
            Spacer()
            DownloadButton(app: app, compact: true)
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
        .padding(.horizontal)
    }
}

// Helper to provide a share sheet
struct FileShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

struct DownloadButton: View {
    let app: AppItem
    var compact: Bool = false
    @EnvironmentObject var downloadManager: DownloadManager
    @State private var showShareSheet = false
    
    var body: some View {
        let downloadURL = URL(string: app.downloadURL)
        
        Group {
            // Check file existence
            if let url = downloadURL, let localURL = downloadManager.getLocalFile(for: url) {
                // 1. File Downloaded -> Share/File
                Button {
                    showShareSheet = true
                } label: {
                    if compact {
                        Image(systemName: "doc.fill")
                            .font(.body.bold())
                            .foregroundColor(.secondary)
                            .frame(width: 28, height: 28)
                            .background(Color.gray.opacity(0.15))
                            .clipShape(Circle())
                    } else {
                        // Standard mode: "FILE" or Icon to differentiate from Run
                        Label("File", systemImage: "doc.fill")
                            .font(.headline)
                            .padding(.vertical, 8)
                            .padding(.horizontal, 20)
                            .background(Color.gray.opacity(0.15))
                            .foregroundColor(.primary)
                            .clipShape(Capsule())
                    }
                }
                .sheet(isPresented: $showShareSheet) {
                    FileShareSheet(activityItems: [prepareFileForShare(localURL)])
                }
            } else if let url = downloadURL, case .downloading(let progress, _, _) = downloadManager.getStatus(for: url) {
                // 2. Active Download
                Button {
                    downloadManager.pauseDownload(url: url)
                } label: {
                    ZStack {
                        Circle()
                            .stroke(lineWidth: 3)
                            .opacity(0.2)
                            .foregroundColor(.blue)
                        
                        Circle()
                            .trim(from: 0.0, to: CGFloat(max(0.01, progress)))
                            .stroke(style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                            .foregroundColor(.blue)
                            .rotationEffect(Angle(degrees: 270.0))
                            .animation(.linear, value: progress)
                        
                        Image(systemName: "pause.fill")
                            .font(.system(size: compact ? 10 : 14))
                            .foregroundColor(.blue)
                    }
                    .frame(width: compact ? 28 : 32, height: compact ? 28 : 32)
                }
            } else if let url = downloadURL, case .paused = downloadManager.getStatus(for: url) {
                // 3. Paused
                Button {
                    downloadManager.resumeDownload(url: url)
                } label: {
                    ZStack {
                        Circle()
                            .stroke(lineWidth: 3)
                            .opacity(0.2)
                            .foregroundColor(.blue)
                        Image(systemName: "play.fill")
                            .font(.system(size: compact ? 10 : 14))
                            .foregroundColor(.blue)
                    }
                    .frame(width: compact ? 28 : 32, height: compact ? 28 : 32)
                }
            } else if let url = downloadURL, case .waitingForConnection = downloadManager.getStatus(for: url) {
                // 4. Waiting
                Button {
                    downloadManager.pauseDownload(url: url)
                } label: {
                    ZStack {
                        Circle().stroke(lineWidth: 3).opacity(0.2).foregroundColor(.orange)
                        Image(systemName: "wifi.slash")
                            .font(.system(size: compact ? 10 : 14)).foregroundColor(.orange)
                    }
                    .frame(width: compact ? 28 : 32, height: compact ? 28 : 32)
                }
            } else {
                // 5. GET Button
                Button(action: {
                    if let url = downloadURL {
                        downloadManager.startDownload(url: url)
                    }
                }) {
                    Text("GET")
                        .font(compact ? .caption.bold() : .headline.bold())
                        .foregroundColor(.blue)
                        .padding(.horizontal, compact ? 16 : 24)
                        .padding(.vertical, compact ? 6 : 6)
                        .background(Color.blue.opacity(0.15))
                        .clipShape(Capsule())
                }
            }
        }
    }
    
    func prepareFileForShare(_ url: URL) -> URL {
        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let tempFile = tempDir.appendingPathComponent(url.lastPathComponent)
        try? fileManager.removeItem(at: tempFile)
        try? fileManager.copyItem(at: url, to: tempFile)
        return tempFile
    }
}

