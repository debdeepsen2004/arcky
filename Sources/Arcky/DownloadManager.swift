import AppKit
import Observation
import WebKit

@MainActor @Observable
final class DownloadItem: Identifiable {
    enum State: Equatable {
        case inProgress
        case finished
        case failed(String)
        case cancelled
    }

    let id = UUID()
    let sourceURL: URL?
    /// The profile whose tab started it.
    let profileID: UUID?
    var filename: String
    var destination: URL?
    var progress: Double = 0
    var totalBytes: Int64 = 0
    var state: State = .inProgress

    @ObservationIgnored weak var download: WKDownload?
    @ObservationIgnored var progressObservation: NSKeyValueObservation?

    init(sourceURL: URL?, profileID: UUID?) {
        self.sourceURL = sourceURL
        self.profileID = profileID
        self.filename = sourceURL?.lastPathComponent ?? "Download"
    }
}

/// Saves WKDownloads into ~/Downloads and tracks their progress for the downloads popover.
@MainActor @Observable
final class DownloadManager: NSObject {
    var items: [DownloadItem] = []

    @ObservationIgnored private var itemsByDownload: [ObjectIdentifier: DownloadItem] = [:]

    /// A profile's downloads, newest first.
    func items(for profileID: UUID) -> [DownloadItem] {
        items.filter { $0.profileID == profileID }
    }

    /// Average progress of a profile's running downloads, for the sidebar badge.
    func overallProgress(for profileID: UUID) -> Double? {
        let active = items(for: profileID).filter { $0.state == .inProgress }
        guard !active.isEmpty else { return nil }
        return active.map(\.progress).reduce(0, +) / Double(active.count)
    }

    func attach(_ download: WKDownload, profileID: UUID?) {
        download.delegate = self
        let item = DownloadItem(sourceURL: download.originalRequest?.url, profileID: profileID)
        item.download = download
        item.progressObservation = download.progress.observe(\.fractionCompleted, options: [.new]) { progress, _ in
            let fraction = progress.fractionCompleted
            let total = progress.totalUnitCount
            Task { @MainActor in
                item.progress = fraction
                item.totalBytes = total
            }
        }
        itemsByDownload[ObjectIdentifier(download)] = item
        items.insert(item, at: 0)
    }

    func cancel(_ item: DownloadItem) {
        item.download?.cancel()
        item.state = .cancelled
        finish(item)
    }

    func open(_ item: DownloadItem) {
        guard item.state == .finished, let destination = item.destination else { return }
        NSWorkspace.shared.open(destination)
    }

    func reveal(_ item: DownloadItem) {
        guard let destination = item.destination else { return }
        NSWorkspace.shared.activateFileViewerSelecting([destination])
    }

    /// Removes a profile's finished, failed and cancelled downloads from the list.
    func clearCompleted(for profileID: UUID) {
        items.removeAll { $0.profileID == profileID && $0.state != .inProgress }
    }

    /// Drops a deleted profile's downloads from the list (the files stay in Downloads).
    func forgetProfile(_ profileID: UUID) {
        for item in items where item.profileID == profileID && item.state == .inProgress { cancel(item) }
        items.removeAll { $0.profileID == profileID }
    }

    private func finish(_ item: DownloadItem) {
        item.progressObservation?.invalidate()
        item.progressObservation = nil
        if let download = item.download { itemsByDownload[ObjectIdentifier(download)] = nil }
    }

    /// `name.ext`, `name 2.ext`, `name 3.ext`… in the Downloads folder.
    private static func uniqueDestination(for filename: String) -> URL {
        let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let base = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension
        var candidate = folder.appending(path: filename)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path(percentEncoded: false)) {
            let name = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            candidate = folder.appending(path: name)
            n += 1
        }
        return candidate
    }
}

extension DownloadManager: WKDownloadDelegate {
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String) async -> URL? {
        let destination = Self.uniqueDestination(for: suggestedFilename.isEmpty ? "Download" : suggestedFilename)
        if let item = itemsByDownload[ObjectIdentifier(download)] {
            item.filename = destination.lastPathComponent
            item.destination = destination
            item.totalBytes = response.expectedContentLength
        }
        return destination
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let item = itemsByDownload[ObjectIdentifier(download)] else { return }
        item.progress = 1
        item.state = .finished
        if let path = item.destination?.path(percentEncoded: false) {
            // Makes the Downloads stack in the Dock bounce, like Safari and Arc.
            DistributedNotificationCenter.default().post(name: .init("com.apple.DownloadFileFinished"), object: path)
        }
        finish(item)
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        guard let item = itemsByDownload[ObjectIdentifier(download)] else { return }
        if item.state == .inProgress { item.state = .failed(error.localizedDescription) }
        finish(item)
    }
}
