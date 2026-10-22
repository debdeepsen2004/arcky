import AppKit
import Observation
import SwiftUI

/// Notes and Easels live in the sidebar as tabs whose URL is `arcky://note/<id>` or
/// `arcky://easel/<id>`, so pinning, folders, Split View and the Archive all work on them.
/// Their content is stored here, apart from the sidebar.
enum ArckyDocument: Equatable {
    case note(UUID)
    case easel(UUID)

    init?(url: URL?) {
        guard let url, url.scheme == "arcky", let id = UUID(uuidString: url.lastPathComponent) else { return nil }
        switch url.host() {
        case "note": self = .note(id)
        case "easel": self = .easel(id)
        default: return nil
        }
    }

    var url: URL {
        switch self {
        case .note(let id): URL(string: "arcky://note/\(id.uuidString)")!
        case .easel(let id): URL(string: "arcky://easel/\(id.uuidString)")!
        }
    }

    var systemImage: String {
        switch self {
        case .note: "note.text"
        case .easel: "scribble.variable"
        }
    }

    var kindName: String {
        switch self {
        case .note: "Note"
        case .easel: "Easel"
        }
    }
}

struct Note: Codable, Hashable {
    var title = ""
    /// The body as RTFD, so pasted images survive.
    var body = Data()
    var modified = Date()
}

/// A freeform canvas of text, drawings, shapes, images and page captures.
struct Easel: Codable, Hashable {
    var title = ""
    var items: [EaselItem] = []
    var modified = Date()
}

struct EaselItem: Codable, Hashable, Identifiable {
    enum Kind: String, Codable {
        case text, image, stroke, rectangle, ellipse
    }

    var id = UUID()
    var kind: Kind
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    /// nil draws in the adaptive primary colour.
    var color: ThemeColor?
    var text: String?
    var fontSize: Double?
    /// An image's file in the Easel images folder.
    var imageFile: String?
    /// A stroke's points, relative to the box it was drawn in (`pointsWidth` × `pointsHeight`),
    /// so resizing the item scales the drawing.
    var points: [CGPoint]?
    var pointsWidth: Double?
    var pointsHeight: Double?
    var lineWidth: Double?
    /// For captures: the page it came from.
    var sourceURL: URL?

    var frame: CGRect {
        get { CGRect(x: x, y: y, width: width, height: height) }
        set {
            x = newValue.minX
            y = newValue.minY
            width = newValue.width
            height = newValue.height
        }
    }
}

/// Stores Notes, Easels and Easel images under Application Support/Arcky.
@MainActor @Observable
final class DocumentStore {
    static let shared = DocumentStore()

    var notes: [UUID: Note] = [:]
    var easels: [UUID: Easel] = [:]

    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var imageCache: [String: NSImage] = [:]

    private struct Saved: Codable {
        var notes: [UUID: Note]
        var easels: [UUID: Easel]
    }

    private static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "Arcky")
    }
    private static var fileURL: URL { folder.appending(path: "documents.json") }
    static var imagesFolder: URL { folder.appending(path: "EaselImages") }

    private init() {
        guard let data = try? Data(contentsOf: Self.fileURL) else { return }
        do {
            let saved = try JSONDecoder().decode(Saved.self, from: data)
            notes = saved.notes
            easels = saved.easels
        } catch {
            NSLog("Arcky: could not read notes and easels: \(error)")
        }
    }

    func createNote() -> UUID {
        let id = UUID()
        notes[id] = Note()
        scheduleSave()
        return id
    }

    func createEasel() -> UUID {
        let id = UUID()
        easels[id] = Easel()
        scheduleSave()
        return id
    }

    func updateNote(_ id: UUID, _ body: (inout Note) -> Void) {
        guard var note = notes[id] else { return }
        body(&note)
        note.modified = Date()
        notes[id] = note
        scheduleSave()
    }

    func updateEasel(_ id: UUID, _ body: (inout Easel) -> Void) {
        guard var easel = easels[id] else { return }
        body(&easel)
        easel.modified = Date()
        easels[id] = easel
        scheduleSave()
    }

    // MARK: Images

    /// Saves an image as PNG in the Easel images folder and returns its file name.
    func saveImage(_ image: NSImage) -> String? {
        guard let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return nil }
        let name = UUID().uuidString + ".png"
        do {
            try FileManager.default.createDirectory(at: Self.imagesFolder, withIntermediateDirectories: true)
            try png.write(to: Self.imagesFolder.appending(path: name), options: .atomic)
        } catch {
            NSLog("Arcky: could not save easel image: \(error)")
            return nil
        }
        imageCache[name] = image
        return name
    }

    func image(named name: String) -> NSImage? {
        if let cached = imageCache[name] { return cached }
        let image = NSImage(contentsOf: Self.imagesFolder.appending(path: name))
        imageCache[name] = image
        return image
    }

    // MARK: Saving

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        saveTask?.cancel()
        do {
            try FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
            try JSONEncoder().encode(Saved(notes: notes, easels: easels)).write(to: Self.fileURL, options: .atomic)
        } catch {
            NSLog("Arcky: could not save notes and easels: \(error)")
        }
    }
}
