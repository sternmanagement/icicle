import SwiftUI
import UniformTypeIdentifiers

enum CustomizeWindow {
    private static var window: NSWindow?

    static func show(face: UUID? = nil) {
        LockController.shared.hide()
        if window == nil {
            let visible = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1440, height: 900)
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: min(1500, visible.width - 40), height: min(940, visible.height - 40)),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = "Customize Lock Screen"
            w.titlebarAppearsTransparent = true
            w.minSize = NSSize(width: 1100, height: 680)
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: CustomizeView(selected: face ?? FaceStore.shared.activeId))
            w.center()
            window = w
            Live.track(w) { window = nil }
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

/// A scaled, live copy of the lock screen at the main display's proportions.
struct FacePreview: View {
    let face: LockFace
    var editing: Binding<EditTarget?>? = nil
    var cornerRadius: CGFloat = 14
    /// Called when a widget from the library is dropped on the preview, with the drop point as a fraction of the screen.
    var onDropWidget: ((String, CGPoint) -> Bool)? = nil

    static var virtualSize: CGSize {
        let s = NSScreen.main?.frame.size ?? CGSize(width: 1512, height: 982)
        return CGSize(width: max(1200, s.width), height: max(760, s.height))
    }

    var body: some View {
        GeometryReader { geo in
            let vs = Self.virtualSize
            let scale = min(geo.size.width / vs.width, geo.size.height / vs.height)
            LockView(faceOverride: face, isMain: true, editing: editing, chrome: 1 / max(scale, 0.2), previewBackground: true, dismiss: {})
                .environment(\.stillPreview, scale < 0.4)
                .frame(width: vs.width, height: vs.height)
                .scaleEffect(scale, anchor: .topLeading)
                .frame(width: vs.width * scale, height: vs.height * scale, alignment: .topLeading)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).strokeBorder(.separator))
                .shadow(color: .black.opacity(0.25), radius: 14, y: 6)
                .position(x: geo.size.width / 2, y: geo.size.height / 2)
                .dropDestination(for: String.self) { items, location in
                    guard let onDropWidget, let payload = items.first else { return false }
                    let w = vs.width * scale, h = vs.height * scale
                    let origin = CGPoint(x: (geo.size.width - w) / 2, y: (geo.size.height - h) / 2)
                    // The drop location is in this view's coordinates; convert it to a fraction of the screen.
                    let p = CGPoint(x: (location.x - origin.x) / w, y: (location.y - origin.y) / h)
                    return onDropWidget(payload, CGPoint(x: min(1, max(0, p.x)), y: min(1, max(0, p.y))))
                }
        }
        .aspectRatio(Self.virtualSize.width / Self.virtualSize.height, contentMode: .fit)
    }
}

struct CustomizeView: View {
    @ObservedObject private var store = FaceStore.shared
    @State var selected: UUID
    @State private var target: EditTarget? = .clock
    @State private var confirmDelete = false
    @StateObject private var editor = EditorState()
    @State private var undoStack: [LockFace] = []
    @State private var redoStack: [LockFace] = []
    @State private var restoring = false
    @State private var lastSnapshot = Date.distantPast
    @State private var keyMonitor: Any?

    private var face: Binding<LockFace> { store.binding(selected) }

    var body: some View {
        HStack(spacing: 0) {
            WidgetLibrary(add: addFromLibrary)
                .frame(width: 210)
            Divider()
            VStack(spacing: 12) {
                faceStrip
                toolbar.padding(.horizontal, 24)
                FacePreview(face: face.wrappedValue, editing: $target, onDropWidget: drop)
                    .environment(\.editor, editor)
                    .padding(.horizontal, 24)
                Text("Drag widgets from the left onto the screen, or drag them around. Right-click a widget for sizes. Click the clock or background to change them.")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .padding(.horizontal, 24).padding(.bottom, 16)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.top, 34)
            .background(.background.secondary)

            Divider()

            Inspector(face: face, target: $target, selected: $selected, editor: editor)
                .frame(width: 380)
        }
        .onAppear(perform: setUp)
        .onDisappear { if let keyMonitor { NSEvent.removeMonitor(keyMonitor) } }
        .onChange(of: selected) { _, _ in undoStack = []; redoStack = []; editor.selectedWidget = nil; bindEditor() }
        .onChange(of: face.wrappedValue) { old, _ in recordUndo(old) }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Button { undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .keyboardShortcut("z", modifiers: .command).disabled(undoStack.isEmpty).help("Undo (⌘Z)")
            Button { redo() } label: { Image(systemName: "arrow.uturn.forward") }
                .keyboardShortcut("z", modifiers: [.command, .shift]).disabled(redoStack.isEmpty).help("Redo (⇧⌘Z)")
            Spacer()
            if let id = editor.selectedWidget, let w = face.wrappedValue.widgets.first(where: { $0.id == id }) {
                Label(w.kind.name, systemImage: w.kind.symbol).font(.callout.weight(.medium))
                Picker("", selection: Binding(get: { w.size }, set: { editor.setSize(id, $0) })) {
                    Text("Small").tag(WidgetSize.small); Text("Wide").tag(WidgetSize.wide)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 120)
                if w.isFree { Button("Put Under Clock") { editor.putInRow(id) }.disabled(face.wrappedValue.usedSlots + w.size.slots > 4) }
                Button(role: .destructive) { editor.remove(id) } label: { Image(systemName: "trash") }.help("Remove (Delete)")
            }
            Spacer()
            Button { LockController.shared.show() } label: { Label("Try It", systemImage: "play.fill") }
                .disabled(face.wrappedValue.id != store.activeId)
                .help("Open the lock screen with this design")
        }
        .controlSize(.regular)
    }

    // MARK: Editing

    private func setUp() {
        bindEditor()
        // Delete removes the selected widget (unless you're typing in a text field).
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let typing = NSApp.keyWindow?.firstResponder is NSText
            if !typing, [51, 117].contains(Int(event.keyCode)), let id = editor.selectedWidget {
                editor.remove(id); return nil
            }
            if !typing, event.keyCode == 53, editor.selectedWidget != nil { editor.selectedWidget = nil; return nil }
            return event
        }
    }

    private func bindEditor() {
        let id = selected
        editor.update = { change in
            guard var f = FaceStore.shared.faces.first(where: { $0.id == id }) else { return }
            change(&f)
            FaceStore.shared.binding(id).wrappedValue = f
        }
        editor.onSelectWidgets = { target = .widgets }
    }

    private func recordUndo(_ old: LockFace) {
        guard !restoring, old.id == selected else { return }
        // Group quick successive changes (dragging, sliders) into one step.
        if Date().timeIntervalSince(lastSnapshot) > 0.7 || undoStack.isEmpty {
            undoStack.append(old)
            if undoStack.count > 60 { undoStack.removeFirst() }
            redoStack = []
        }
        lastSnapshot = Date()
    }
    private func undo() {
        guard let prev = undoStack.popLast() else { return }
        redoStack.append(face.wrappedValue)
        restoring = true; face.wrappedValue = prev
        DispatchQueue.main.async { restoring = false; lastSnapshot = .distantPast }
    }
    private func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(face.wrappedValue)
        restoring = true; face.wrappedValue = next
        DispatchQueue.main.async { restoring = false; lastSnapshot = .distantPast }
    }

    /// Clicking a widget in the library puts it under the clock if there's room, otherwise in the middle of the screen.
    private func addFromLibrary(_ kind: WidgetKind, _ size: WidgetSize) {
        var item = WidgetItem(kind: kind, size: size)
        if face.wrappedValue.usedSlots + size.slots > 4 { item.x = 0.5; item.y = 0.62 }
        face.wrappedValue.widgets.append(item)
        editor.selectedWidget = item.id; target = .widgets
    }

    private func drop(_ payload: String, at point: CGPoint) -> Bool {
        let parts = payload.split(separator: ":")
        guard parts.count == 3, parts[0] == "widget", let kind = WidgetKind(rawValue: String(parts[1])),
              let size = WidgetSize(rawValue: String(parts[2])) else { return false }
        var item = WidgetItem(kind: kind, size: size)
        item.x = min(0.97, max(0.03, point.x)); item.y = min(0.96, max(0.04, point.y))
        face.wrappedValue.widgets.append(item)
        editor.selectedWidget = item.id; target = .widgets
        return true
    }

    private var faceStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
                ForEach(store.faces) { f in
                    Button { selected = f.id } label: {
                        VStack(spacing: 6) {
                            FacePreview(face: f, cornerRadius: 8)
                                .frame(width: 150, height: 98)
                                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.accentColor, lineWidth: f.id == selected ? 3 : 0).padding(-3))
                                .allowsHitTesting(false)
                            HStack(spacing: 4) {
                                if f.id == store.activeId { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                                Text(f.name).lineLimit(1)
                            }
                            .font(.caption.weight(.medium))
                        }
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Use This Lock Screen") { store.activeId = f.id }
                        Button("Duplicate") { if let id = store.duplicate(f.id) { selected = id } }
                        Button("Delete", role: .destructive) { store.delete(f.id); if selected == f.id { selected = store.activeId } }
                            .disabled(store.faces.count < 2)
                    }
                }
                Button { selected = store.add() } label: {
                    VStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                            .foregroundStyle(.secondary)
                            .overlay(Image(systemName: "plus").font(.title2).foregroundStyle(.secondary))
                            .frame(width: 150, height: 98)
                        Text("New").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 24).padding(.vertical, 6)
        }
    }
}

// MARK: - Inspector

private struct Inspector: View {
    @Binding var face: LockFace
    @Binding var target: EditTarget?
    @Binding var selected: UUID
    @ObservedObject var editor: EditorState
    @ObservedObject private var store = FaceStore.shared
    @ObservedObject private var prefs = Prefs.shared

    var body: some View {
        VStack(spacing: 0) {
            Picker("Edit", selection: Binding(get: { target ?? .clock }, set: { target = $0 })) {
                Image(systemName: "photo").tag(EditTarget.wallpaper).help("Wallpaper")
                Image(systemName: "textformat.size").tag(EditTarget.clock).help("Clock")
                Image(systemName: "text.line.first.and.arrowtriangle.forward").tag(EditTarget.inline).help("Top widget")
                Image(systemName: "square.grid.2x2").tag(EditTarget.widgets).help("Widgets")
                Image(systemName: "list.bullet.rectangle").tag(EditTarget.content).help("Layout")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 16).padding(.top, 40).padding(.bottom, 8)

            Form {
                Section {
                    TextField("Name", text: $face.name)
                    HStack {
                        if face.id == store.activeId {
                            Label("Current lock screen", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        } else {
                            Button("Use This Lock Screen") { store.activeId = face.id }
                        }
                        Spacer()
                        Button { LockController.shared.show() } label: { Label("Preview", systemImage: "play.fill") }
                            .disabled(face.id != store.activeId)
                    }
                }
                switch target ?? .clock {
                case .clock: ClockInspector(face: $face, use24h: $prefs.use24h)
                case .inline: InlineInspector(face: $face)
                case .widgets: WidgetsInspector(face: $face, city: $prefs.weatherCity, editor: editor)
                case .content: LayoutInspector(face: $face, name: $prefs.displayName)
                case .wallpaper: WallpaperInspector(face: $face)
                }
                Section {
                    HStack {
                        Button("Duplicate") { if let id = store.duplicate(face.id) { selected = id } }
                        Spacer()
                        Button("Delete Lock Screen", role: .destructive) {
                            let id = face.id; selected = store.faces.first { $0.id != id }?.id ?? id; store.delete(id)
                        }
                        .disabled(store.faces.count < 2)
                    }
                }
            }
            .formStyle(.grouped)
        }
    }
}

private let palette: [String?] = [nil, "#FFFFFF", "#FF9AA2", "#FFB86B", "#FFE066", "#9BE7A0", "#7FDBFF", "#8AB6FF", "#C3A6FF", "#FF6B6B"]

private struct ClockInspector: View {
    @Binding var face: LockFace
    @Binding var use24h: Bool

    var body: some View {
        Section("Font") {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                ForEach(ClockFont.allCases) { f in
                    Button { face.font = f } label: {
                        VStack(spacing: 2) {
                            Text("12").font(f.font(size: 26, weight: face.fontWeight))
                            Text(f.name).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, minHeight: 56)
                        .background(face.font == f ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.08),
                                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.accentColor, lineWidth: face.font == f ? 2 : 0))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 4)
            LabeledContent("Weight") {
                HStack {
                    Image(systemName: "textformat.size.smaller").foregroundStyle(.secondary)
                    Slider(value: $face.weight, in: 0...1)
                    Image(systemName: "bold").foregroundStyle(.secondary)
                }
            }
        }
        Section("Color") {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(26), spacing: 10), count: 6), alignment: .leading, spacing: 10) {
                ForEach(palette, id: \.self) { hex in
                    Button { face.colorHex = hex } label: {
                        Circle()
                            .fill(hex.map { AnyShapeStyle(Color(hex: $0)) } ?? AnyShapeStyle(
                                AngularGradient(colors: [.white, .gray, .white], center: .center)))
                            .frame(width: 22, height: 22)
                            .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: face.colorHex == hex ? 2.5 : 0).padding(-3))
                    }
                    .buttonStyle(.plain)
                    .help(hex == nil ? "Automatic" : hex!)
                }
                ColorPicker("", selection: Binding(get: { Color(hex: face.colorHex ?? "#FFFFFF") }, set: { face.colorHex = NSColor($0).hexString }))
                    .labelsHidden()
            }
            .padding(.vertical, 4)
            LabeledContent("Tone") {
                Slider(value: $face.tone, in: 0...1).disabled(face.colorHex == nil)
            }
        }
        Section("Size and Position") {
            LabeledContent("Clock size") {
                HStack {
                    Image(systemName: "textformat.size.smaller").foregroundStyle(.secondary)
                    Slider(value: $face.clockScale, in: 0.6...1.5)
                    Image(systemName: "textformat.size.larger").foregroundStyle(.secondary)
                }
            }
            Picker("Alignment", selection: $face.alignment) {
                Label("Center", systemImage: "text.aligncenter").tag(FaceAlignment.center)
                Label("Left", systemImage: "text.alignleft").tag(FaceAlignment.leading)
            }
            .pickerStyle(.segmented)
            Toggle("24-hour time", isOn: $use24h)
        }
    }
}

private struct InlineInspector: View {
    @Binding var face: LockFace
    var body: some View {
        Section("Above the Clock") {
            Picker("Show", selection: $face.inline) {
                ForEach(InlineWidget.allCases) { Text($0.name).tag($0) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }
    }
}

private struct WidgetsInspector: View {
    @Binding var face: LockFace
    @Binding var city: String
    @ObservedObject var editor: EditorState
    @State private var cityDraft = ""

    private var freeSlots: Int { 4 - face.usedSlots }

    var body: some View {
        Section {
            Picker("Position", selection: $face.widgetsPlacement) {
                Text("Below Clock").tag(WidgetsPlacement.belowClock)
                Text("Bottom").tag(WidgetsPlacement.bottom)
            }
            .pickerStyle(.segmented)
        } header: { Text("Row Under the Clock") } footer: {
            Text("\(face.usedSlots) of 4 spaces used. Widgets you place anywhere on the screen don't count, so you can add as many as you like.")
        }

        Section("On This Lock Screen") {
            if face.widgets.isEmpty { Text("No widgets yet. Add some below.").foregroundStyle(.secondary) }
            List {
                ForEach($face.widgets) { $w in
                    HStack {
                        Image(systemName: w.kind.symbol).frame(width: 20).foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(w.kind.name)
                            Text(w.isFree ? "Anywhere" : "Under the clock").font(.caption2).foregroundStyle(.secondary)
                        }
                        if w.kind == .worldClock {
                            Picker("", selection: Binding(get: { w.timeZone ?? "America/New_York" }, set: { w.timeZone = $0 })) {
                                ForEach(WorldClocks.cities, id: \.1) { Text($0.0).tag($0.1) }
                            }
                            .labelsHidden().frame(width: 110)
                        }
                        Spacer()
                        Picker("", selection: Binding(get: { w.size }, set: { new in
                            if w.isFree || new.slots - w.size.slots <= freeSlots { w.size = new }
                        })) {
                            Text("S").tag(WidgetSize.small); Text("W").tag(WidgetSize.wide)
                        }
                        .pickerStyle(.segmented).labelsHidden().frame(width: 64)
                        Menu {
                            if w.isFree { Button("Put Under the Clock") { editor.putInRow(w.id) }.disabled(freeSlots < w.size.slots) }
                            else { Button("Place Anywhere") { w.x = 0.5; w.y = 0.62 } }
                        } label: { Image(systemName: "arrow.up.and.down.and.arrow.left.and.right") }
                        .menuStyle(.borderlessButton).frame(width: 30).help("Where it goes")
                        Button { face.widgets.removeAll { $0.id == w.id } } label: {
                            Image(systemName: "minus.circle.fill").foregroundStyle(.red)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .onMove { face.widgets.move(fromOffsets: $0, toOffset: $1) }
            }
            .frame(minHeight: CGFloat(max(1, face.widgets.count)) * 30)
            Text("Drag to reorder.").font(.caption).foregroundStyle(.secondary)
        }

        Section {
            Text("Add widgets from the library on the left: drag one anywhere on the screen, or click it to put it under the clock.")
                .font(.callout).foregroundStyle(.secondary)
        }

        Section {
            HStack {
                TextField("City", text: $cityDraft, prompt: Text("Use my location"))
                    .onSubmit(applyCity)
                Button("Set", action: applyCity).disabled(cityDraft == city)
            }
        } header: { Text("Weather Location") } footer: {
            Text("Leave empty to use Location Services. Weather comes from Open-Meteo.")
        }
        .onAppear { cityDraft = city }
    }

    private func add(_ k: WidgetKind, _ s: WidgetSize) {
        guard s.slots <= freeSlots else { return }
        face.widgets.append(WidgetItem(kind: k, size: s, timeZone: k == .worldClock ? "America/New_York" : nil))
    }
    private func applyCity() { city = cityDraft; WeatherService.shared.ensureStarted(); WeatherService.shared.refresh() }
}

private struct LayoutInspector: View {
    @Binding var face: LockFace
    @Binding var name: String

    var body: some View {
        Section {
            List {
                ForEach($face.sections) { $s in
                    HStack {
                        Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary)
                        Image(systemName: s.section.symbol).frame(width: 20).foregroundStyle(.secondary)
                        Text(s.section.name)
                        Spacer()
                        Toggle("", isOn: $s.enabled).labelsHidden().toggleStyle(.switch).controlSize(.small)
                    }
                }
                .onMove { face.sections.move(fromOffsets: $0, toOffset: $1) }
            }
            .frame(minHeight: 130)
        } header: { Text("Below the Clock") } footer: { Text("Drag to change the order. Turn off anything you don't want to see.") }

        Section("Notifications") {
            Picker("Display as", selection: $face.notificationStyle) {
                Text("Count").tag("count"); Text("Stack").tag("stack"); Text("List").tag("list")
            }
            .pickerStyle(.segmented)
        }

        Section("Profile") {
            Toggle("Show picture and name", isOn: $face.showProfile)
            TextField("Name", text: $name, prompt: Text("Optional"))
        }
    }
}

private struct WallpaperInspector: View {
    @Binding var face: LockFace

    var body: some View {
        Section("Wallpaper") {
            Picker("Type", selection: $face.wallpaper.kind) {
                ForEach(Wallpaper.Kind.allCases, id: \.self) { Text($0.name).tag($0) }
            }
            .pickerStyle(.segmented)
            switch face.wallpaper.kind {
            case .desktop:
                Text("Your desktop picture, sharp like the macOS lock screen. Add blur for a frosted look.").foregroundStyle(.secondary)
                LabeledContent("Blur") { Slider(value: $face.wallpaper.blur, in: 0...60) }
            case .color:
                ColorPicker("Color", selection: hexBinding($face.wallpaper.color1), supportsOpacity: false)
                swatches
            case .gradient:
                ColorPicker("Top", selection: hexBinding($face.wallpaper.color1), supportsOpacity: false)
                ColorPicker("Bottom", selection: hexBinding($face.wallpaper.color2), supportsOpacity: false)
                swatches
            case .photo:
                HStack {
                    Text(face.wallpaper.photoPath.map { ($0 as NSString).lastPathComponent } ?? "No photo chosen")
                        .foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    Button("Choose Photo…", action: choosePhoto)
                }
                LabeledContent("Blur") { Slider(value: $face.wallpaper.blur, in: 0...60) }
            }
            LabeledContent("Dim") { Slider(value: $face.wallpaper.dim, in: 0...0.7) }
        }
    }

    private var swatches: some View {
        let pairs: [(String, String)] = [("#1B2A4E", "#7B3FA8"), ("#0F3D3E", "#2E8B8B"), ("#3A1C32", "#C0596B"), ("#141414", "#3C3C3C"),
                                         ("#0B2447", "#19376D"), ("#4A2511", "#D2803A"), ("#162F1E", "#5E8C61")]
        return HStack(spacing: 8) {
            ForEach(pairs, id: \.0) { p in
                Button { face.wallpaper.color1 = p.0; face.wallpaper.color2 = p.1 } label: {
                    Circle().fill(LinearGradient(colors: [Color(hex: p.0), Color(hex: p.1)], startPoint: .top, endPoint: .bottom))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func choosePhoto() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let src = panel.url else { return }
        // Keep a copy so the wallpaper survives if the original moves.
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Glass Lock/Wallpapers", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(UUID().uuidString + "." + (src.pathExtension.isEmpty ? "jpg" : src.pathExtension))
        do { try FileManager.default.copyItem(at: src, to: dest); face.wallpaper.photoPath = dest.path }
        catch { face.wallpaper.photoPath = src.path }
    }
}

// MARK: - Widget library

/// Every widget, live, in both sizes. Drag one onto the screen to place it anywhere, or click to add it.
private struct WidgetLibrary: View {
    let add: (WidgetKind, WidgetSize) -> Void
    @State private var search = ""

    private var kinds: [WidgetKind] {
        search.isEmpty ? WidgetKind.allCases : WidgetKind.allCases.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Widgets").font(.title3.weight(.semibold)).padding(.top, 40)
            TextField("Search", text: $search).textFieldStyle(.roundedBorder)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(kinds) { k in
                        VStack(alignment: .leading, spacing: 6) {
                            Label(k.name, systemImage: k.symbol).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            HStack(alignment: .top, spacing: 8) {
                                tile(k, .small)
                                tile(k, .wide)
                            }
                        }
                    }
                }
                .padding(.vertical, 6)
            }
        }
        .padding(.horizontal, 14)
        .background(.background)
    }

    private func tile(_ k: WidgetKind, _ size: WidgetSize) -> some View {
        let item = WidgetItem(kind: k, size: size)
        let scale: CGFloat = 0.62
        let w = (size == .small ? LockWidget.unit : LockWidget.unit * 2 + LockWidget.gap) * scale
        return TimelineView(.periodic(from: .now, by: 30)) { ctx in
            LockWidget(item: item, date: ctx.date)
                .environment(\.colorScheme, .dark)
                .environment(\.stillPreview, true)
                .scaleEffect(scale, anchor: .topLeading)
                .frame(width: w, height: LockWidget.unit * scale, alignment: .topLeading)
                .background(LinearGradient(colors: [Color(hex: "#30466E"), Color(hex: "#5A3F7E")], startPoint: .topLeading, endPoint: .bottomTrailing),
                            in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        }
        .frame(width: w, height: LockWidget.unit * scale)
        .contentShape(Rectangle())
        .onTapGesture { add(k, size) }
        .draggable("widget:\(k.rawValue):\(size.rawValue)") {
            LockWidget(item: item, date: Date()).environment(\.colorScheme, .dark).environment(\.stillPreview, true)
        }
        .help("Drag onto the screen, or click to add \(size == .small ? "small" : "wide")")
    }
}
