import SwiftUI
import Combine

// Explicit alias selects the property wrapper with SDKs that also declare a State macro.
typealias ViewState<Value> = SwiftUI.State<Value>
import AppKit
import ServiceManagement
import ImageIO

enum PanelTab: String, CaseIterable {
    case recent, emoji, gifs, kaomoji, symbols, clipboard
    var title: String {
        switch self { case .recent: return "Recently used"; case .emoji: return "Emoji"; case .gifs: return "GIFs"; case .kaomoji: return "Kaomoji"; case .symbols: return "Symbols"; case .clipboard: return "Clipboard" }
    }
    var icon: String {
        switch self { case .recent: return "clock"; case .emoji: return "face.smiling"; case .gifs: return "photo.on.rectangle.angled"; case .kaomoji: return "face.dashed"; case .symbols: return "number"; case .clipboard: return "clipboard" }
    }
}

@MainActor
final class PanelState: ObservableObject {
    @Published var tab = PanelTab.clipboard
    @Published var query = "" { didSet { if query != oldValue { selection = 0; refresh() } } }
    @Published var filter = "All" { didSet { if filter != oldValue { selection = 0; refresh() } } }
    @Published var showSearch = false
    @Published var category = "All"
    @Published var selection = 0
    @Published var presentation = UUID()
    @Published var isPresented = false
    @Published private(set) var searching = false
    @Published private(set) var results: [Clip] = []
    var paste: ((Clip, Bool) -> Void)?
    var settings: (() -> Void)?
    var close: (() -> Void)?
    private var subscription: AnyCancellable?
    private var searchTask: Task<Void, Never>?
    private var snapshot: [Clip] = []
    func connect(_ store: ClipboardStore) {
        subscription = store.$clips.sink { [weak self] clips in self?.snapshot = clips; self?.refresh() }
    }
    func filtered(_ store: ClipboardStore) -> [Clip] { results }
    private func refresh() {
        searchTask?.cancel()
        guard isPresented else { results = []; searching = false; return }
        let query = query, filter = filter
        let candidates = snapshot.filter { clip in
            filter == "All" || (filter == "Pinned" && clip.pinned) || (filter == "Text" && clip.hasText) || (filter == "Images" && clip.imageData != nil) || (filter == "Files" && !clip.fileURLs.isEmpty)
        }
        if query.isEmpty { results = candidates; searching = false; return }
        searching = true; results = []
        searchTask = Task {
            do { try await Task.sleep(nanoseconds: 120_000_000) } catch { return }
            let worker = Task.detached(priority: .userInitiated) {
                var matches: [Clip] = []
                for clip in candidates {
                    if Task.isCancelled { return matches }
                    if autoreleasepool(invoking: { clip.source.localizedCaseInsensitiveContains(query) || (clip.hasText ? clip.text : clip.summary).localizedCaseInsensitiveContains(query) }) { matches.append(clip) }
                }
                return matches
            }
            let matches = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
            guard !Task.isCancelled else { return }
            results = matches; searching = false
        }
    }
    func hide() { isPresented = false; searchTask?.cancel(); query = ""; filter = "All"; searching = false; results = [] }
    func show() { isPresented = true; refresh() }
}

struct SmallIconButton: View {
    var icon: String
    var help: String
    var action: () -> Void
    var body: some View {
        Button(action: action) { Image(systemName: icon).font(.system(size: 13, weight: .medium)).frame(width: 27, height: 27).contentShape(Rectangle()) }
            .buttonStyle(.plain).foregroundStyle(.secondary).help(help).accessibilityLabel(help)
    }
}

struct ClipboardPanelView: View {
    @ObservedObject var store: ClipboardStore
    @ObservedObject var state: PanelState
    @FocusState private var searchFocused: Bool
    @StateObject private var gifs = GIFSearch()
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                ForEach(PanelTab.allCases, id: \.self) { tab in
                    Button {
                        state.tab = tab; state.query = ""; state.category = "All"; state.selection = 0
                        if tab == .gifs { gifs.search("") } else { gifs.stop() }
                    } label: {
                        VStack(spacing: 8) {
                            Group {
                                if tab == .gifs { Text("GIF").font(.system(size: 10, weight: .semibold)) }
                                else if tab == .kaomoji { Text(";−)").font(.system(size: 17)) }
                                else if tab == .symbols { Text("Ω").font(.system(size: 20)) }
                                else { Image(systemName: tab.icon).font(.system(size: 17, weight: .regular)) }
                            }.frame(height: 23)
                            Capsule().fill(state.tab == tab ? Color.accentColor : .clear).frame(width: 17, height: 2)
                        }.foregroundStyle(Color.primary.opacity(state.tab == tab ? 0.95 : 0.65))
                            .frame(maxWidth: .infinity).padding(.vertical, 7).contentShape(Rectangle())
                    }.buttonStyle(.plain).help(tab.title).accessibilityLabel(tab.title)
                }
            }.padding(.horizontal, 15).padding(.top, 10).padding(.bottom, 5)
            HStack(spacing: 8) {
                Text(state.tab.title).font(.system(size: 14, weight: .semibold))
                Spacer()
                if state.tab == .clipboard {
                    SmallIconButton(icon: "magnifyingglass", help: "Search clipboard (⌘F)") { state.showSearch.toggle() }
                    Button("Clear all") { store.clearUnpinned() }
                        .font(.system(size: 11)).buttonStyle(WindowsButtonStyle())
                        .disabled(!store.clips.contains { !$0.pinned })
                }
            }.padding(.horizontal, 15).padding(.top, 3).padding(.bottom, 12)
            if state.tab != .clipboard || state.showSearch {
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(.secondary)
                    TextField(state.tab == .clipboard ? "Search clipboard history" : "Search \(state.tab.title.lowercased())", text: $state.query)
                        .textFieldStyle(.plain).font(.system(size: 12)).focused($searchFocused).accessibilityLabel("Search")
                    if state.tab == .clipboard {
                        Menu { ForEach(["All", "Pinned", "Text", "Images", "Files"], id: \.self) { value in Button { state.filter = value } label: { if state.filter == value { Label(value, systemImage: "checkmark") } else { Text(value) } } } }
                        label: { Image(systemName: "line.3.horizontal.decrease").font(.system(size: 12)).foregroundStyle(state.filter == "All" ? Color.secondary : Color.accentColor) }
                            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Filter clipboard")
                    }
                    if !state.query.isEmpty { SmallIconButton(icon: "xmark.circle.fill", help: "Clear search") { state.query = "" } }
                }.padding(.horizontal, 10).frame(height: 32)
                    .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 5))
                    .overlay(alignment: .bottom) { Rectangle().fill(searchFocused ? Color.accentColor : Color.primary.opacity(0.15)).frame(height: searchFocused ? 2 : 1) }
                    .padding(.horizontal, 15).padding(.bottom, 10)
            }
            if !store.storageError.isEmpty { banner(store.storageError, icon: "exclamationmark.triangle") }
            if !store.trusted && store.preferences.automaticPaste {
                Button { state.settings?() } label: { Label("Enable Accessibility for click-to-paste", systemImage: "hand.tap").font(.system(size: 11)).frame(maxWidth: .infinity, alignment: .leading) }
                    .buttonStyle(.plain).foregroundStyle(Color.accentColor).padding(.horizontal, 22).padding(.bottom, 10)
            }
            if !store.preferences.captureEnabled { banner("Clipboard recording is paused", icon: "pause.circle") }
            Group {
                switch state.tab {
                case .clipboard: history
                case .emoji: characterGrid(CharacterCatalog.emoji, emoji: true)
                case .symbols: characterGrid(CharacterCatalog.symbols, emoji: false)
                case .kaomoji: characterGrid(CharacterCatalog.kaomoji, emoji: false, wide: true)
                case .recent: recent
                case .gifs: if state.isPresented { gifPanel }
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack(spacing: 7) {
                Button { store.preferences.captureEnabled.toggle(); store.updatePreferences() } label: { Image(systemName: store.preferences.captureEnabled ? "pause" : "play").font(.system(size: 10)).frame(width: 18, height: 22) }
                    .buttonStyle(.plain).help(store.preferences.captureEnabled ? "Pause clipboard history" : "Resume clipboard history")
                Text("\(store.clips.count) items").font(.system(size: 10)).foregroundStyle(.tertiary)
                Spacer()
                Text(store.preferences.shortcut.label).font(.system(size: 10)).foregroundStyle(.tertiary)
                SmallIconButton(icon: "gearshape", help: "Settings") { state.settings?() }
            }.foregroundStyle(.secondary).padding(.horizontal, 14).frame(height: 29)
        }.overlay(alignment: .top) { WindowDragHandle().frame(height: 8) }
            .frame(width: PanelLayout.width, height: PanelLayout.height).tint(Color(nsColor: .secondaryLabelColor))
            .onChange(of: state.presentation) { searchFocused = state.showSearch }
            .onChange(of: state.showSearch) { searchFocused = state.showSearch; if !state.showSearch { state.query = ""; state.filter = "All" } }
            .onChange(of: state.query) { if state.tab == .gifs { gifs.search(state.query) } }
            .onDisappear { gifs.stop() }
            .onChange(of: state.isPresented) { if !state.isPresented { gifs.stop() } }
            .onChange(of: state.tab) { if state.tab != .gifs { gifs.stop() } }
    }
    private func banner(_ message: String, icon: String) -> some View {
        Label(message, systemImage: icon).font(.system(size: 11)).foregroundStyle(.orange).lineLimit(3).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 22).padding(.bottom, 9)
    }
    private var history: some View {
        VStack(spacing: 9) {
            let items = state.filtered(store)
            if store.isLoading || state.searching {
                VStack(spacing: 10) { Spacer(); ProgressView(); Text(store.isLoading ? "Opening encrypted history…" : "Searching…").font(.system(size: 12)).foregroundStyle(.secondary); Spacer() }
            } else if items.isEmpty {
                empty(icon: state.query.isEmpty ? "clipboard" : "magnifyingglass", title: state.query.isEmpty ? "Your clipboard, remembered" : "No matching items", detail: state.query.isEmpty ? "Copy text, images or files anywhere.\nThey'll be waiting for you here." : "Try another search or filter.")
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 7) {
                            ForEach(Array(items.enumerated()), id: \.element.id) { index, clip in
                                ClipCard(clip: clip, selected: state.selection == index, index: index, store: store, state: state).id(clip.id)
                            }
                        }.padding(.horizontal, 14).padding(.top, 1).padding(.bottom, 9)
                    }.onChange(of: state.selection) { _, index in
                        if items.indices.contains(index) { withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(items[index].id, anchor: .center) } }
                    }
                }
            }
            if !store.notice.isEmpty {
                HStack { Text(store.notice).lineLimit(2); Spacer(); Button { store.notice = "" } label: { Image(systemName: "xmark") }.buttonStyle(.plain) }.font(.system(size: 10)).foregroundStyle(.secondary).padding(.horizontal, 22).padding(.bottom, 6)
            }
        }
    }
    private func empty(icon: String, title: String, detail: String) -> some View {
        VStack(spacing: 13) {
            Spacer()
            Image(systemName: icon).font(.system(size: 37, weight: .ultraLight)).foregroundStyle(.secondary).padding(.bottom, 4)
            Text(title).font(.system(size: 15, weight: .medium))
            Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center).lineSpacing(4)
            Spacer(); Spacer().frame(height: 15)
        }.frame(maxWidth: .infinity)
    }
    private func characterGrid(_ items: [CharacterItem], emoji: Bool, wide: Bool = false) -> some View {
        let categories = ["All"] + Array(Set(items.map(\.category))).sorted()
        let filtered = items.filter { (state.category == "All" || state.category == $0.category) && (state.query.isEmpty || $0.name.localizedCaseInsensitiveContains(state.query) || $0.value.contains(state.query)) }
        return VStack(spacing: 8) {
            HStack {
                Picker("Category", selection: $state.category) { ForEach(categories, id: \.self) { Text($0).tag($0) } }.labelsHidden().frame(width: 150)
                Spacer()
                Button("Character Viewer ↗") { NSApp.orderFrontCharacterPalette(nil) }.font(.system(size: 10)).buttonStyle(.plain).foregroundStyle(Color.accentColor)
            }.padding(.horizontal, 20)
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: wide ? 2 : 7), spacing: 5) {
                    ForEach(filtered) { item in
                        Button { store.rememberCharacter(item.value); state.paste?(.text(item.value), false) } label: {
                            Text(item.value).font(.system(size: emoji ? 25 : wide ? 15 : 22)).lineLimit(1).minimumScaleFactor(0.5)
                                .frame(maxWidth: .infinity).frame(height: wide ? 43 : 42).background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 7))
                        }.buttonStyle(.plain).help(item.name).accessibilityLabel(item.name)
                    }
                }.padding(.horizontal, 19).padding(.bottom, 16)
            }
            Text("\(filtered.count) \(emoji ? "emoji" : "characters")").font(.system(size: 10)).foregroundStyle(.tertiary).padding(.bottom, 7)
        }
    }
    private var recent: some View {
        let values = store.recentCharacters.filter { state.query.isEmpty || $0.contains(state.query) }
        return Group {
            if values.isEmpty { empty(icon: "clock", title: "Your favourites, closer", detail: "Emoji, symbols and kaomoji you use\nwill appear here.") }
            else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 45))], spacing: 8) {
                        ForEach(values, id: \.self) { value in
                            Button { store.rememberCharacter(value); state.paste?(.text(value), false) } label: { Text(value).font(.system(size: value.count > 4 ? 14 : 25)).frame(maxWidth: .infinity).frame(height: 45).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8)) }.buttonStyle(.plain)
                        }
                    }.padding(20)
                }
            }
        }
    }
    private var gifPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack { Text("Your GIFs").font(.system(size: 12, weight: .semibold)); Spacer(); Button("Import GIFs…") { store.importGIFs() }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Color.accentColor) }
                if store.gifLibrary.isEmpty { Text("Import animated GIFs to keep a personal library.").font(.system(size: 11)).foregroundStyle(.secondary) }
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    ForEach(store.gifLibrary.filter { state.query.isEmpty || $0.source.localizedCaseInsensitiveContains(state.query) }) { clip in
                        Button { state.paste?(clip, false) } label: { AnimatedImage(data: clip.imageData).frame(height: 100).clipped().background(.black.opacity(0.05), in: RoundedRectangle(cornerRadius: 8)) }.buttonStyle(.plain).help(clip.source)
                            .contextMenu { Button("Remove from library", role: .destructive) { store.gifLibrary.removeAll { $0.id == clip.id }; store.saveGIFs() } }
                    }
                }
                Divider().padding(.vertical, 3)
                HStack { Text(state.query.isEmpty ? "Trending on GIPHY" : "GIPHY results").font(.system(size: 12, weight: .semibold)); Spacer(); if gifs.loading { ProgressView().controlSize(.small) } }
                if !gifs.error.isEmpty { Text(gifs.error).font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(3) }
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    ForEach(gifs.results) { gif in
                        Button {
                            Task { do { let clip = try await gifs.download(gif, maximum: store.preferences.itemLimitMB * 1024 * 1024); state.paste?(clip, false) } catch { store.notice = error.localizedDescription } }
                        } label: { RemoteGIFView(url: URL(string: gif.images.fixed_width.url)).frame(height: 100).clipped().background(.black.opacity(0.04), in: RoundedRectangle(cornerRadius: 8)) }.buttonStyle(.plain).help(gif.title)
                    }
                }
                if !gifs.results.isEmpty { Text("Powered by GIPHY").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary) }
            }.padding(.horizontal, 20).padding(.bottom, 18)
        }
    }
}

struct ClipboardThumbnail: View {
    let clip: Clip
    @ViewState private var image: NSImage?
    var body: some View {
        Group {
            if let image { Image(nsImage: image).resizable().scaledToFit() }
            else { Image(systemName: "photo").font(.system(size: 22)).foregroundStyle(.secondary).frame(height: 60) }
        }.frame(maxWidth: .infinity, maxHeight: 115).clipShape(RoundedRectangle(cornerRadius: 3))
            .task(id: clip.digest) {
                if let cached = PreviewCache.images.object(forKey: clip.digest as NSString) { image = cached; return }
                guard let data = clip.imageData else { return }
                let cg = await MediaPreparer.shared.thumbnail(data)
                guard !Task.isCancelled, let cg else { return }
                let result = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
                PreviewCache.images.setObject(result, forKey: clip.digest as NSString, cost: cg.width * cg.height * 4)
                image = result
            }
    }
}

struct WindowsButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.padding(.horizontal, 11).padding(.vertical, 5)
            .background(Color(nsColor: .controlBackgroundColor).opacity(configuration.isPressed ? 0.4 : 0.75), in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
    }
}

enum PanelLayout { static let width: CGFloat = 352; static let height: CGFloat = 500 }

struct WindowDragHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> Handle {
        let view = Handle(); view.toolTip = "Drag to move the clipboard panel"; return view
    }
    func updateNSView(_ view: Handle, context: Context) {}
    final class Handle: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    }
}

struct ClipCard: View {
    var clip: Clip
    var selected: Bool
    var index: Int
    @ObservedObject var store: ClipboardStore
    @ObservedObject var state: PanelState
    @ViewState private var hover = false
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 6) {
                Button { state.paste?(clip, NSEvent.modifierFlags.contains(.shift)) } label: {
                    Group {
                        if clip.imageData != nil { ClipboardThumbnail(clip: clip) }
                        else { Text(clip.summary).font(.system(size: 12)).lineLimit(4).lineSpacing(2).frame(maxWidth: .infinity, minHeight: 34, alignment: .topLeading).multilineTextAlignment(.leading) }
                    }.foregroundStyle(.primary).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(.plain).help("Click to paste. Shift-click for plain text.")
                Menu {
                    if clip.hasText { Button("Paste as plain text", systemImage: "textformat") { state.paste?(clip, true) } }
                    Button("Copy", systemImage: "doc.on.doc") { if store.writeToPasteboard(clip) { store.notice = "Copied. Paste with ⌘V." } }
                    if clip.hasText, !store.preferences.syncPath.isEmpty { Button("Sync text", systemImage: "icloud.and.arrow.up") { store.sync?.upload(clip) } }
                    Divider()
                    Button("Delete", systemImage: "trash", role: .destructive) { store.delete(clip) }
                } label: { Image(systemName: "ellipsis").font(.system(size: 12, weight: .semibold)).frame(width: 23, height: 20).contentShape(Rectangle()) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("See more")
            }
            HStack {
                Spacer()
                Button { store.togglePin(clip) } label: { Image(systemName: clip.pinned ? "pin.fill" : "pin").font(.system(size: 11)).rotationEffect(.degrees(clip.pinned ? 0 : 35)).frame(width: 23, height: 21).contentShape(Rectangle()) }
                    .buttonStyle(.plain).foregroundStyle(clip.pinned ? Color.accentColor : Color.secondary).help(clip.pinned ? "Unpin" : "Pin")
                    .accessibilityLabel(clip.pinned ? "Unpin item" : "Pin item")
            }
        }.padding(.leading, 11).padding(.trailing, 7).padding(.top, 10).padding(.bottom, 5)
            .background(Color(nsColor: .controlBackgroundColor).opacity(hover ? 0.88 : 0.7), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(selected ? Color.accentColor.opacity(0.6) : Color.primary.opacity(0.09), lineWidth: selected ? 1 : 0.5))
            .onHover { hover = $0 }
            .help(clip.source.isEmpty ? "Clipboard item" : "Copied from \(clip.source)")
            .contextMenu {
                Button("Paste") { state.paste?(clip, false) }
                if clip.hasText { Button("Paste as plain text") { state.paste?(clip, true) } }
                Button(clip.pinned ? "Unpin" : "Pin") { store.togglePin(clip) }
                Button("Delete", role: .destructive) { store.delete(clip) }
            }
    }
}

struct AnimatedImage: NSViewRepresentable {
    var data: Data?
    func makeNSView(context: Context) -> NSImageView { let view = NSImageView(); view.imageScaling = .scaleProportionallyUpOrDown; view.animates = true; return view }
    func updateNSView(_ view: NSImageView, context: Context) {
        guard context.coordinator.data != data else { return }
        context.coordinator.task?.cancel()
        context.coordinator.data = data
        guard let data else { view.image = nil; return }
        view.image = nil
        context.coordinator.task = Task { [weak view] in
            let animate = await MediaPreparer.shared.canAnimate(data)
            guard !Task.isCancelled, let view else { return }
            if animate { view.animates = true; view.image = NSImage(data: data) }
            else {
                let cg = await MediaPreparer.shared.thumbnail(data)
                guard !Task.isCancelled else { return }
                view.animates = false; view.image = cg.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
            }
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    static func dismantleNSView(_ view: NSImageView, coordinator: Coordinator) { coordinator.task?.cancel(); view.animates = false; view.image = nil }
    @MainActor final class Coordinator { var data: Data?; var task: Task<Void, Never>? }
}

struct RemoteGIFView: View {
    var url: URL?
    @ViewState private var data: Data?
    var body: some View {
        AnimatedImage(data: data).task(id: url) {
            guard let url else { return }
            data = nil
            if let body = try? await BoundedHTTP.shared.data(from: url, maximum: 2 * 1024 * 1024, mime: ["image/gif", "application/octet-stream"]), !Task.isCancelled, MediaSafety.isGIF(body) { data = body }
        }
    }
}

struct ShortcutRecorder: NSViewRepresentable {
    var shortcut: Shortcut
    var change: (Shortcut) -> Bool
    func makeNSView(context: Context) -> RecorderButton { let button = RecorderButton(); button.bezelStyle = .rounded; button.target = button; button.action = #selector(RecorderButton.beginRecording); return button }
    func updateNSView(_ button: RecorderButton, context: Context) { button.shortcut = shortcut; button.change = change; if !button.recording { button.title = shortcut.label } }
}

final class RecorderButton: NSButton {
    var shortcut = Shortcut()
    var change: ((Shortcut) -> Bool)?
    var recording = false
    override var acceptsFirstResponder: Bool { true }
    @objc func beginRecording() {
        recording = true; title = "Press shortcut…"; window?.makeFirstResponder(self)
        NotificationCenter.default.post(name: .clipboardShortcutRecording, object: nil, userInfo: ["recording": true])
    }
    func finishRecording() {
        guard recording else { return }
        recording = false; title = shortcut.label
        NotificationCenter.default.post(name: .clipboardShortcutRecording, object: nil, userInfo: ["recording": false])
    }
    override func keyDown(with event: NSEvent) {
        guard recording else { super.keyDown(with: event); return }
        if event.keyCode == 53 { finishRecording(); return }
        guard let shortcut = Shortcut.from(event) else { NSSound.beep(); return }
        if change?(shortcut) == true { self.shortcut = shortcut; finishRecording() }
        else { title = "Shortcut unavailable"; NSSound.beep() }
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool { if recording { keyDown(with: event); return true }; return super.performKeyEquivalent(with: event) }
    override func resignFirstResponder() -> Bool { finishRecording(); return super.resignFirstResponder() }
}

struct SettingsView: View {
    @ObservedObject var store: ClipboardStore
    var changeShortcut: (Shortcut) -> Bool
    var requestAccessibility: () -> Void
    @ViewState private var tab = "General"
    @ViewState private var giphyKey = ""
    @ViewState private var syncPhrase = ""
    @ViewState private var message = ""
    @ViewState private var excludedID = ""
    @ViewState private var loginEnabled = SMAppService.mainApp.status == .enabled
    @ViewState private var confirmErase = false
    @ViewState private var rememberPosition = UserDefaults.standard.object(forKey: "rememberPanelPosition") as? Bool ?? true
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "clipboard.fill").font(.system(size: 28)).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 3) { Text("Clipboard").font(.system(size: 20, weight: .semibold)); Text("Your clipboard, with a longer memory.").font(.system(size: 12)).foregroundStyle(.secondary) }
                Spacer()
            }.padding(24)
            Picker("Settings", selection: $tab) { ForEach(["General", "History", "Privacy", "Sync & GIFs"], id: \.self) { Text($0).tag($0) } }.pickerStyle(.segmented).padding(.horizontal, 24).padding(.bottom, 14)
            Form {
                if tab == "General" {
                    Section("Keyboard shortcut") {
                        HStack { Text("Open clipboard"); Spacer(); ShortcutRecorder(shortcut: store.preferences.shortcut, change: changeShortcut).frame(width: 170, height: 28) }
                        Text("Click the shortcut, then press your preferred keys. Include Command, Control or Option. Escape cancels.").font(.caption).foregroundStyle(.secondary)
                    }
                    Section("Pasting") {
                        Toggle("Paste automatically when selecting an item", isOn: preference(\.automaticPaste))
                        Toggle("Always paste text without formatting", isOn: preference(\.pastePlainText))
                        HStack { Label(store.trusted ? "Accessibility enabled" : "Accessibility permission required", systemImage: store.trusted ? "checkmark.circle.fill" : "hand.tap").foregroundStyle(store.trusted ? Color.green : .orange); Spacer(); Button(store.trusted ? "Open settings" : "Enable…", action: requestAccessibility) }
                        Text("Without Accessibility permission, selecting an item copies it. Press ⌘V in your destination app. Shift-click or Shift-Return pastes plain text.").font(.caption).foregroundStyle(.secondary)
                    }
                    Section("App") {
                        Toggle("Record clipboard history", isOn: preference(\.captureEnabled))
                        Toggle("Launch at login", isOn: $loginEnabled).onChange(of: loginEnabled) { _, enabled in
                            do { if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }; message = enabled ? "Login item registered. macOS may ask you to approve it." : "Launch at login disabled." }
                            catch { message = error.localizedDescription; loginEnabled = SMAppService.mainApp.status == .enabled }
                        }
                        Picker("Appearance", selection: preference(\.appearance)) { Text("System").tag("system"); Text("Light").tag("light"); Text("Dark").tag("dark") }
                        Toggle("Remember where I last dragged the clipboard panel", isOn: $rememberPosition).onChange(of: rememberPosition) { UserDefaults.standard.set(rememberPosition, forKey: "rememberPanelPosition") }
                        Button("Reset saved panel position") { UserDefaults.standard.removeObject(forKey: "panelPosition"); message = "The panel will open near the cursor until you drag it again." }
                    }
                } else if tab == "History" {
                    Section("Capacity") {
                        Stepper("History items: \(store.preferences.historyLimit)", value: preference(\.historyLimit), in: 25...5000, step: 25)
                        Stepper("Maximum item: \(store.preferences.itemLimitMB) MB", value: preference(\.itemLimitMB), in: 4...128, step: 4)
                        Stepper("History storage budget: \(store.preferences.storageLimitMB) MB", value: preference(\.storageLimitMB), in: 64...4096, step: 64)
                        Text("Currently \(store.clips.count) items using \(ByteCountFormatter.string(fromByteCount: Int64(store.totalBytes), countStyle: .file)). Older unpinned items are removed first. Pinned items are never automatically deleted; if pins fill the budget, new items are skipped.").font(.caption).foregroundStyle(.secondary)
                        Button("Use Windows-compatible limits (25 items, 4 MB)") { store.preferences.historyLimit = 25; store.preferences.itemLimitMB = 4; store.updatePreferences() }
                    }
                    Section("Retention") {
                        Toggle("Keep unpinned history after quitting and restarting", isOn: preference(\.persistHistory))
                        Text("Pinned items always persist. Text and original image data are kept together, including HTML and RTF formatting where available.").font(.caption).foregroundStyle(.secondary)
                        Button("Clear unpinned history") { store.clearUnpinned(); message = "Unpinned history cleared." }
                    }
                } else if tab == "Privacy" {
                    Section("Local storage") {
                        Label("History is encrypted with AES-256-GCM", systemImage: "lock.shield")
                        Text("Your encryption key is stored in macOS Keychain. Clipboard content is only shared if you configure and use folder sync. GIPHY receives GIF searches when an API key is configured.").font(.caption).foregroundStyle(.secondary)
                        if !store.storageError.isEmpty { Text(store.storageError).foregroundStyle(.orange) }
                    }
                    Section("Excluded apps") {
                        Text("Copies from these apps and content marked concealed, transient or automatically generated are skipped.").font(.caption).foregroundStyle(.secondary)
                        ForEach(store.preferences.excludedApps, id: \.self) { id in HStack { Text(id).font(.system(size: 11, design: .monospaced)); Spacer(); Button { store.preferences.excludedApps.removeAll { $0 == id }; store.updatePreferences() } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain) } }
                        HStack { TextField("App bundle ID, e.g. com.example.app", text: $excludedID); Button("Add") { let id = excludedID.trimmingCharacters(in: .whitespacesAndNewlines); if !id.isEmpty, !store.preferences.excludedApps.contains(id) { store.preferences.excludedApps.append(id); store.updatePreferences(); excludedID = "" } } }
                        Button("Choose an app…") { let panel = NSOpenPanel(); panel.allowedContentTypes = [.applicationBundle]; if panel.runModal() == .OK, let url = panel.url, let id = Bundle(url: url)?.bundleIdentifier, !store.preferences.excludedApps.contains(id) { store.preferences.excludedApps.append(id); store.updatePreferences() } }
                    }
                    Section("Delete") { Button("Erase all history, including pins…", role: .destructive) { confirmErase = true } }
                } else {
                    Section("Text sync between Macs") {
                        Text("Choose an iCloud Drive, OneDrive or other synced folder on each Mac, using the same passphrase. Text up to 1 MB is encrypted before sharing. Images and files stay local. Microsoft-account clipboard sync is not supported.").font(.caption).foregroundStyle(.secondary)
                        SecureField("Shared passphrase (at least 12 characters)", text: $syncPhrase)
                        HStack { Button("Choose sync folder…") { chooseSyncFolder() }; if !store.preferences.syncPath.isEmpty { Button("Disconnect") { store.sync?.disconnect(); message = "Sync disconnected. Existing shared files remain in the chosen folder." } } }
                        if !store.preferences.syncPath.isEmpty {
                            Text(store.preferences.syncPath).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            Toggle("Automatically sync copied text", isOn: preference(\.automaticSync))
                            Button("Check for shared text now") { store.sync?.receive(); message = "Checked the sync folder." }
                        }
                    }
                    Section("Online GIFs") {
                        Text("Personal GIF imports work without an account. Online search uses GIPHY and requires your own API key.").font(.caption).foregroundStyle(.secondary)
                        SecureField("GIPHY API key", text: $giphyKey)
                        HStack { Button("Save API key") { do { try Keychain.write(Data(giphyKey.trimmingCharacters(in: .whitespacesAndNewlines).utf8), account: "giphy-api-key"); giphyKey = ""; message = "GIPHY key saved in Keychain. Open the GIF tab to search." } catch { message = error.localizedDescription } }; Link("Get a GIPHY API key ↗", destination: URL(string: "https://developers.giphy.com/dashboard/")!) }
                        Button("Import GIFs…") { store.importGIFs() }
                    }
                }
                if !message.isEmpty { Section { Text(message).font(.caption).textSelection(.enabled) } }
            }.formStyle(.grouped)
            HStack { Text("Clipboard 1.2 · Made for macOS").foregroundStyle(.tertiary); Spacer(); Text("⌘⇧V by default").foregroundStyle(.secondary) }.font(.system(size: 10)).padding(.horizontal, 24).frame(height: 32)
        }.frame(width: 620, height: 660).tint(Color(nsColor: .secondaryLabelColor))
            .confirmationDialog("Erase all clipboard history, including pinned items?", isPresented: $confirmErase) { Button("Erase all history", role: .destructive) { store.clearEverything(); message = "All local clipboard history erased." } }
    }
    private func preference<T>(_ path: WritableKeyPath<Preferences, T>) -> Binding<T> { Binding(get: { store.preferences[keyPath: path] }, set: { store.preferences[keyPath: path] = $0; store.updatePreferences() }) }
    private func chooseSyncFolder() {
        guard syncPhrase.count >= 12 else { message = "Enter a shared passphrase of at least 12 characters first."; return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        let phrase = syncPhrase
        syncPhrase = ""
        message = "Configuring encrypted sync…"
        Task {
            do { try await store.sync?.configure(folder: folder, phrase: phrase); message = "Encrypted folder sync configured. Use the same folder and passphrase on your other Mac." }
            catch { message = "Sync setup failed. Check the passphrase and folder access." }
        }
    }
}
