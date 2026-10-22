import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// Arc-style Easel: a canvas for text, drawings, shapes, images and captures of open tabs.
struct EaselView: View {
    let easelID: UUID
    @Environment(BrowserStore.self) private var store

    enum Tool: String, CaseIterable {
        case select, text, pen, rectangle, ellipse

        var systemImage: String {
            switch self {
            case .select: "cursorarrow"
            case .text: "textformat"
            case .pen: "pencil.tip"
            case .rectangle: "rectangle"
            case .ellipse: "circle"
            }
        }

        var help: String {
            switch self {
            case .select: "Select and move"
            case .text: "Text"
            case .pen: "Draw"
            case .rectangle: "Rectangle"
            case .ellipse: "Ellipse"
            }
        }
    }

    static let palette: [ThemeColor?] = [
        nil,
        ThemeColor(red: 0.92, green: 0.26, blue: 0.24),
        ThemeColor(red: 0.98, green: 0.58, blue: 0.13),
        ThemeColor(red: 0.95, green: 0.78, blue: 0.10),
        ThemeColor(red: 0.20, green: 0.70, blue: 0.35),
        ThemeColor(red: 0.20, green: 0.48, blue: 0.95),
        ThemeColor(red: 0.62, green: 0.32, blue: 0.90),
    ]

    static let canvasSize = CGSize(width: 3000, height: 2000)

    @State private var tool = Tool.select
    @State private var color: ThemeColor?
    @State private var selection: UUID?
    @State private var editingTextID: UUID?
    /// The drawing or shape being made.
    @State private var draftPoints: [CGPoint] = []
    @State private var draftStart: CGPoint?
    @State private var draftEnd: CGPoint?
    /// Live offset of the item being dragged.
    @State private var dragOffset: CGSize = .zero
    @State private var resizeDelta: CGSize = .zero
    @FocusState private var canvasFocused: Bool

    private var documents: DocumentStore { .shared }
    private var easel: Easel { documents.easels[easelID] ?? Easel() }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            ScrollView([.horizontal, .vertical]) {
                canvas
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 10) {
            TextField("Untitled Easel", text: Binding(
                get: { easel.title },
                set: { title in
                    documents.updateEasel(easelID) { $0.title = title }
                    store.syncDocumentTitle(.easel(easelID), title: title)
                }
            ))
            .textFieldStyle(.plain)
            .font(.system(size: 17, weight: .semibold))
            .frame(maxWidth: 260)

            Spacer()

            HStack(spacing: 2) {
                ForEach(Tool.allCases, id: \.self) { item in
                    Button { tool = item } label: {
                        Image(systemName: item.systemImage)
                            .frame(width: 28, height: 24)
                            .background(RoundedRectangle(cornerRadius: 6).fill(tool == item ? Color.accentColor.opacity(0.2) : .clear))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(item.help)
                }
            }

            HStack(spacing: 4) {
                ForEach(Self.palette.indices, id: \.self) { i in
                    let swatch = Self.palette[i]
                    Button {
                        color = swatch
                        if let selection { documents.updateEasel(easelID) { easel in
                            if let index = easel.items.firstIndex(where: { $0.id == selection }) { easel.items[index].color = swatch }
                        } }
                    } label: {
                        Circle()
                            .fill(swatch?.color ?? .primary)
                            .frame(width: 14, height: 14)
                            .overlay(Circle().strokeBorder(.primary.opacity(color == swatch ? 0.8 : 0), lineWidth: 2).padding(-3))
                    }
                    .buttonStyle(.plain)
                }
            }

            Menu {
                let tabs = webTabs
                if tabs.isEmpty {
                    Text("Open a page in this space to capture it")
                }
                ForEach(tabs) { tab in
                    // Tabs load lazily; only ones that have been opened have a page to snapshot.
                    let loaded = store.pool.existingWebView(for: tab.id) != nil
                    Button(loaded ? tab.displayTitle : "\(tab.displayTitle) (open it first)") { capture(tab) }
                        .disabled(!loaded)
                }
            } label: {
                Label("Capture", systemImage: "camera.viewfinder")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Add a snapshot of an open tab")

            Button { insertImageFromFile() } label: { Image(systemName: "photo") }
                .buttonStyle(.borderless)
                .help("Insert Image…")

            Button { deleteSelection() } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless)
                .disabled(selection == nil)
                .help("Delete (⌫)")
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
    }

    // MARK: Canvas

    private var canvas: some View {
        ZStack(alignment: .topLeading) {
            DotGrid()
            // The background takes drawing gestures; items sit above it.
            Color.clear
                .contentShape(Rectangle())
                .gesture(canvasGesture)
            ForEach(easel.items) { item in
                itemView(item)
            }
            draftView
        }
        .frame(width: Self.canvasSize.width, height: Self.canvasSize.height)
        .coordinateSpace(name: "canvas")
        .focusable()
        .focusEffectDisabled()
        .focused($canvasFocused)
        .onDeleteCommand { deleteSelection() }
        .onPasteCommand(of: [.image, .png, .tiff, .fileURL]) { providers in paste(providers) }
        .onExitCommand {
            finishEditing()
            selection = nil
        }
    }

    @ViewBuilder
    private func itemView(_ item: EaselItem) -> some View {
        let isSelected = selection == item.id
        let frame = displayFrame(of: item)
        EaselItemContent(
            item: item,
            size: frame.size,
            editing: editingTextID == item.id,
            onTextChange: { text in update(item.id) { $0.text = text } },
            onEndEditing: { finishEditing() }
        )
        .frame(width: frame.width, height: frame.height, alignment: .topLeading)
        .overlay {
            if isSelected {
                Rectangle()
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                    .padding(-4)
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if isSelected { resizeHandle }
        }
        .contentShape(Rectangle())
        // One tap handler that reads the click count, so a single click selects at once
        // instead of waiting to see whether a double-click follows.
        .onTapGesture {
            selection = item.id
            if (NSApp.currentEvent?.clickCount ?? 1) >= 2 {
                activate(item)
            } else {
                canvasFocused = true
            }
        }
        .gesture(moveGesture(for: item))
        .allowsHitTesting(tool == .select)
        .offset(x: frame.minX, y: frame.minY)
    }

    /// The item's frame, including an in-progress move or resize.
    private func displayFrame(of item: EaselItem) -> CGRect {
        guard selection == item.id else { return item.frame }
        return CGRect(
            x: item.x + dragOffset.width,
            y: item.y + dragOffset.height,
            width: max(20, item.width + resizeDelta.width),
            height: max(20, item.height + resizeDelta.height)
        )
    }

    private var resizeHandle: some View {
        Circle()
            .fill(Color.accentColor)
            .frame(width: 12, height: 12)
            .offset(x: 8, y: 8)
            .gesture(
                DragGesture(coordinateSpace: .named("canvas"))
                    .onChanged { value in resizeDelta = value.translation }
                    .onEnded { value in
                        guard let id = selection else { return }
                        update(id) { item in
                            item.width = max(20, item.width + value.translation.width)
                            item.height = max(20, item.height + value.translation.height)
                        }
                        resizeDelta = .zero
                    }
            )
    }

    private func moveGesture(for item: EaselItem) -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named("canvas"))
            .onChanged { value in
                selection = item.id
                dragOffset = value.translation
            }
            .onEnded { value in
                update(item.id) { moved in
                    moved.x += value.translation.width
                    moved.y += value.translation.height
                }
                dragOffset = .zero
            }
    }

    /// Ends text editing; a text box left empty is removed.
    private func finishEditing() {
        guard let id = editingTextID else { return }
        editingTextID = nil
        if easel.items.first(where: { $0.id == id })?.text?.isEmpty ?? true {
            documents.updateEasel(easelID) { $0.items.removeAll { $0.id == id } }
            if selection == id { selection = nil }
        }
        canvasFocused = true
    }

    /// Double-click: edit text, or open a capture's page.
    private func activate(_ item: EaselItem) {
        switch item.kind {
        case .text:
            selection = item.id
            editingTextID = item.id
        case .image:
            if let url = item.sourceURL { store.open(url, inNewTab: true) }
        default:
            break
        }
    }

    private var canvasGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("canvas"))
            .onChanged { value in
                switch tool {
                case .pen:
                    draftPoints.append(value.location)
                case .rectangle, .ellipse:
                    draftStart = value.startLocation
                    draftEnd = value.location
                default:
                    break
                }
            }
            .onEnded { value in
                switch tool {
                case .select:
                    // The canvas takes keyboard focus so Delete works on the selection.
                    finishEditing()
                    canvasFocused = true
                    selection = nil
                case .text:
                    addText(at: value.location)
                case .pen:
                    finishStroke()
                case .rectangle, .ellipse:
                    finishShape()
                }
            }
    }

    @ViewBuilder
    private var draftView: some View {
        if tool == .pen, draftPoints.count > 1 {
            Path { path in path.addLines(draftPoints) }
                .stroke(color?.color ?? .primary, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                .allowsHitTesting(false)
        }
        if let start = draftStart, let end = draftEnd, tool == .rectangle || tool == .ellipse {
            let rect = CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
            ShapeContent(kind: tool == .rectangle ? .rectangle : .ellipse, color: color)
                .frame(width: rect.width, height: rect.height)
                .offset(x: rect.minX, y: rect.minY)
                .allowsHitTesting(false)
        }
    }

    // MARK: Creating items

    private func add(_ item: EaselItem) {
        documents.updateEasel(easelID) { $0.items.append(item) }
        selection = item.id
    }

    private func update(_ id: UUID, _ body: (inout EaselItem) -> Void) {
        documents.updateEasel(easelID) { easel in
            guard let i = easel.items.firstIndex(where: { $0.id == id }) else { return }
            body(&easel.items[i])
        }
    }

    private func addText(at point: CGPoint) {
        let item = EaselItem(kind: .text, x: point.x, y: point.y - 12, width: 240, height: 44, color: color, text: "", fontSize: 20)
        add(item)
        editingTextID = item.id
        tool = .select
    }

    private func finishStroke() {
        defer { draftPoints = [] }
        guard draftPoints.count > 1 else { return }
        let xs = draftPoints.map(\.x), ys = draftPoints.map(\.y)
        let pad = 4.0
        let box = CGRect(x: xs.min()! - pad, y: ys.min()! - pad, width: xs.max()! - xs.min()! + pad * 2, height: ys.max()! - ys.min()! + pad * 2)
        let relative = draftPoints.map { CGPoint(x: $0.x - box.minX, y: $0.y - box.minY) }
        add(EaselItem(kind: .stroke, x: box.minX, y: box.minY, width: box.width, height: box.height, color: color,
                      points: relative, pointsWidth: box.width, pointsHeight: box.height, lineWidth: 3))
        selection = nil
    }

    private func finishShape() {
        defer {
            draftStart = nil
            draftEnd = nil
        }
        guard let start = draftStart, let end = draftEnd, abs(end.x - start.x) > 4, abs(end.y - start.y) > 4 else { return }
        let rect = CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
        add(EaselItem(kind: tool == .rectangle ? .rectangle : .ellipse, x: rect.minX, y: rect.minY, width: rect.width, height: rect.height, color: color))
        tool = .select
    }

    /// Adds an image, scaled to at most 480 points wide, near the top-left of the canvas.
    private func addImage(_ image: NSImage, source: URL? = nil) {
        guard let file = documents.saveImage(image) else { return }
        let scale = min(1, 480 / max(image.size.width, 1))
        let offset = Double(easel.items.count % 8) * 24
        add(EaselItem(kind: .image, x: 60 + offset, y: 60 + offset,
                      width: image.size.width * scale, height: image.size.height * scale,
                      imageFile: file, sourceURL: source))
        tool = .select
    }

    /// The space's web pages (not Notes or Easels).
    private var webTabs: [BrowserTab] {
        store.sidebarOrder.filter { $0.url != nil && ArckyDocument(url: $0.url) == nil }
    }

    /// Arc's Capture: a snapshot of a tab's visible page that links back to it.
    private func capture(_ tab: BrowserTab) {
        guard let webView = store.pool.existingWebView(for: tab.id) else { return }
        webView.takeSnapshot(with: nil) { image, _ in
            guard let image else { return }
            addImage(image, source: tab.url)
        }
    }

    private func insertImageFromFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK, let url = panel.url, let image = NSImage(contentsOf: url) else { return }
        addImage(image)
    }

    private func paste(_ providers: [NSItemProvider]) {
        for provider in providers where provider.canLoadObject(ofClass: NSImage.self) {
            _ = provider.loadObject(ofClass: NSImage.self) { object, _ in
                guard let image = object as? NSImage else { return }
                Task { @MainActor in addImage(image) }
            }
        }
    }

    private func deleteSelection() {
        guard let id = selection, editingTextID == nil else { return }
        documents.updateEasel(easelID) { $0.items.removeAll { $0.id == id } }
        selection = nil
    }
}

/// What an item draws, at its current size.
private struct EaselItemContent: View {
    let item: EaselItem
    let size: CGSize
    let editing: Bool
    let onTextChange: (String) -> Void
    let onEndEditing: () -> Void
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        switch item.kind {
        case .text:
            if editing {
                TextField("Text", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: item.fontSize ?? 20, weight: .medium))
                    .foregroundStyle(item.color?.color ?? .primary)
                    .focused($focused)
                    .onAppear {
                        draft = item.text ?? ""
                        // Wait a turn so the new field exists before taking focus.
                        DispatchQueue.main.async { focused = true }
                    }
                    .onChange(of: draft) { onTextChange(draft) }
                    .onSubmit(onEndEditing)
            } else {
                Text((item.text ?? "").isEmpty ? "Text" : item.text!)
                    .font(.system(size: item.fontSize ?? 20, weight: .medium))
                    .foregroundStyle((item.text ?? "").isEmpty ? Color.secondary : (item.color?.color ?? .primary))
            }
        case .image:
            if let file = item.imageFile, let image = DocumentStore.shared.image(named: file) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size.width, height: size.height)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
                    .overlay(alignment: .bottomLeading) {
                        if let url = item.sourceURL {
                            Label(url.host()?.strippingWWW ?? url.absoluteString, systemImage: "link")
                                .font(.system(size: 10, weight: .medium))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(.ultraThinMaterial, in: Capsule())
                                .padding(6)
                                .help("Double-click to open \(url.absoluteString)")
                        }
                    }
            } else {
                RoundedRectangle(cornerRadius: 8).fill(.quaternary)
            }
        case .stroke:
            let sx = size.width / max(item.pointsWidth ?? size.width, 1)
            let sy = size.height / max(item.pointsHeight ?? size.height, 1)
            Path { path in path.addLines((item.points ?? []).map { CGPoint(x: $0.x * sx, y: $0.y * sy) }) }
                .stroke(item.color?.color ?? .primary, style: StrokeStyle(lineWidth: item.lineWidth ?? 3, lineCap: .round, lineJoin: .round))
        case .rectangle, .ellipse:
            ShapeContent(kind: item.kind, color: item.color)
        }
    }
}

private struct ShapeContent: View {
    let kind: EaselItem.Kind
    let color: ThemeColor?

    var body: some View {
        let tint = color?.color ?? .primary
        if kind == .ellipse {
            Ellipse().fill(tint.opacity(0.15)).overlay(Ellipse().stroke(tint, lineWidth: 2))
        } else {
            RoundedRectangle(cornerRadius: 6).fill(tint.opacity(0.15)).overlay(RoundedRectangle(cornerRadius: 6).stroke(tint, lineWidth: 2))
        }
    }
}

/// The canvas's faint dot grid.
private struct DotGrid: View {
    var body: some View {
        Canvas { context, size in
            let spacing: CGFloat = 24
            var y: CGFloat = spacing
            while y < size.height {
                var x: CGFloat = spacing
                while x < size.width {
                    context.fill(Path(ellipseIn: CGRect(x: x - 1, y: y - 1, width: 2, height: 2)), with: .color(.secondary.opacity(0.35)))
                    x += spacing
                }
                y += spacing
            }
        }
        .allowsHitTesting(false)
    }
}
