import SwiftUI
import AppKit
import AVFoundation

struct ContentView: View {
    @ObservedObject var backend: LiveStemBackend

    @State private var selectedChannelIndex: Int = 0
    @State private var loopNewFile: Bool = true
    @State private var lastLoadedFileName: String = "Nessun file caricato"

    var body: some View {
        HStack(spacing: 0) {
            LeftTrackLoaderView(
                backend: backend,
                selectedChannelIndex: $selectedChannelIndex,
                loopNewFile: $loopNewFile,
                lastLoadedFileName: $lastLoadedFileName,
                onPickFile: pickAudioFileForSelectedChannel
            )
            .frame(width: 260)

            Divider()

            VStack(spacing: 0) {
                HeaderView(
                    onPlayAll: { backend.playAll() },
                    onStopAll: { backend.stopAll() }
                )
                .padding(16)

                Divider()

                ChannelsScrollView(backend: backend)
                    .padding(16)
            }

            Divider()

            FXRackView(backend: backend)
                .frame(width: 190)
        }
        .frame(minWidth: 1200, minHeight: 780)
    }

    private func pickAudioFileForSelectedChannel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard selectedChannelIndex >= 0,
              selectedChannelIndex < backend.channels.count else { return }

        let targetChannel = backend.channels[selectedChannelIndex]
        targetChannel.loadFile(
            url: url,
            loop: loopNewFile,
            autoPlay: true
        )

        lastLoadedFileName = url.lastPathComponent
    }
}

// MARK: - Header View

struct HeaderView: View {
    let onPlayAll: () -> Void
    let onStopAll: () -> Void

    var body: some View {
        HStack {
            Text("MACOS 8-CHANNEL STEM MIXER")
                .font(.system(size: 16, weight: .bold))

            Spacer()

            Button("Play All", action: onPlayAll)
            Button("Stop All", action: onStopAll)
        }
    }
}

// MARK: - FX Rack View

private enum PluginPickerTarget {
    case aux1
    case aux2
}

struct FXRackView: View {
    @ObservedObject var backend: LiveStemBackend
    @ObservedObject var catalog: AUPluginCatalog = .shared

    @State private var selectedAux1Plugin: AVAudioUnitComponent? = nil
    @State private var selectedAux2Plugin: AVAudioUnitComponent? = nil

    @State private var isPluginPickerPresented = false
    @State private var pickerTarget: PluginPickerTarget = .aux1

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("FX RACK")
                .font(.system(size: 14, weight: .bold))

            Divider()

            effectSlot(
                title: "AUX 2",
                subtitle: "Return CH8",
                selection: Binding(
                    get: { backend.aux2EffectType },
                    set: { backend.setAux2EffectType($0) }
                ),
                plugin: selectedAux2Plugin,
                onChoosePlugin: {
                    openPluginPicker(for: .aux2)
                }
            )

            Divider()

            effectSlot(
                title: "AUX 1",
                subtitle: "Return CH7",
                selection: Binding(
                    get: { backend.aux1EffectType },
                    set: { backend.setAux1EffectType($0) }
                ),
                plugin: selectedAux1Plugin,
                onChoosePlugin: {
                    openPluginPicker(for: .aux1)
                }
            )

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("PAD FX")
                    .font(.system(size: 12, weight: .bold))

                Text("REVERB")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.orange)

                Text("Fixed effect")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }

            Spacer()
        }
        .padding(14)
        .frame(maxHeight: .infinity)
        .background(Color.secondary.opacity(0.05))
        .onAppear {
            catalog.refresh()
        }
        .sheet(isPresented: $isPluginPickerPresented) {
            AUPluginPickerModal(catalog: catalog) { component in
                switch pickerTarget {
                case .aux1:
                    selectedAux1Plugin = component
                    backend.setAux1Plugin(component)

                case .aux2:
                    selectedAux2Plugin = component
                    backend.setAux2Plugin(component)
                }
            }
            .frame(width: 620, height: 540)
        }
    }

    private func openPluginPicker(for target: PluginPickerTarget) {
        pickerTarget = target
        isPluginPickerPresented = true
    }

    private func effectSlot(
        title: String,
        subtitle: String,
        selection: Binding<AuxEffectType>,
        plugin: AVAudioUnitComponent?,
        onChoosePlugin: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .bold))

            Text(subtitle)
                .font(.system(size: 10))
                .foregroundColor(.secondary)

            Picker("Effect", selection: selection) {
                ForEach(AuxEffectType.allCases) { effect in
                    Text(effect.rawValue).tag(effect)
                }
            }
            .labelsHidden()
            .frame(maxWidth: .infinity)

            Button(action: onChoosePlugin) {
                HStack {
                    Text("+")
                    Text("Choose AU Plugin")
                }
                .font(.system(size: 10, weight: .medium))
                .frame(maxWidth: .infinity)
            }

            if let plugin = plugin {
                Text(plugin.name)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.blue)
                    .lineLimit(2)
            } else {
                Text("No AU plugin selected")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
        }
    }
}

private struct AUPluginEntry: Identifiable {
    let id: String
    let component: AVAudioUnitComponent
    let searchIndex: String
    let category: String
}

// MARK: - AU Plugin Picker Modal

struct AUPluginPickerModal: View {
    @ObservedObject var catalog: AUPluginCatalog

    let onSelect: (AVAudioUnitComponent) -> Void

    @Environment(\.presentationMode) var presentationMode

    @State private var searchText = ""
    @State private var selectedCategory = "All"

    @State private var entries: [AUPluginEntry] = []
    @State private var filteredEntries: [AUPluginEntry] = []

    private let categories = [
        "All",
        "Reverb",
        "Delay",
        "Dynamics",
        "Distortion",
        "Modulation",
        "Other"
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("SELECT AUDIO UNIT")
                    .font(.system(size: 16, weight: .bold))

                Spacer()

                Button("Cancel") {
                    presentationMode.wrappedValue.dismiss()
                }
            }

            Divider()

            HStack {
                Text("⌕")
                    .foregroundColor(.secondary)

                TextField(
                    "Search by name or manufacturer...",
                    text: Binding(
                        get: { searchText },
                        set: {
                            searchText = $0
                            applyFilter()
                        }
                    )
                )
            }
            .padding(8)
            .background(Color.secondary.opacity(0.1))
            .cornerRadius(6)

            HStack {
                Text("Category")
                    .font(.system(size: 11, weight: .semibold))

                Picker(
                    "Category",
                    selection: Binding(
                        get: { selectedCategory },
                        set: {
                            selectedCategory = $0
                            applyFilter()
                        }
                    )
                ) {
                    ForEach(categories, id: \.self) { category in
                        Text(category).tag(category)
                    }
                }
                .frame(width: 160)

                Spacer()

                Text("\(filteredEntries.count) plugins")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }

            Divider()

            if catalog.isScanning {
                Spacer()
                Text("Scanning Audio Units...")
                    .foregroundColor(.secondary)
                Spacer()

            } else if filteredEntries.isEmpty {
                Spacer()
                Text("No matching plugins found")
                    .foregroundColor(.secondary)
                Spacer()

            } else {
                List(filteredEntries) { entry in
                    pluginRow(entry)
                }
                .listStyle(PlainListStyle())
            }

            Divider()

            HStack {
                Button("Refresh Catalog") {
                    catalog.refresh()
                }
                .disabled(catalog.isScanning)

                Spacer()

                Button("Close") {
                    presentationMode.wrappedValue.dismiss()
                }
            }
        }
        .padding(20)
        .onAppear {
            rebuildEntries(catalog.components)
        }
        .onReceive(catalog.$components) { components in
            rebuildEntries(components)
        }
    }

    // MARK: - Data preparation

    private func rebuildEntries(_ components: [AVAudioUnitComponent]) {
        entries = components.map { component in
            let pluginCategory = self.category(for: component)

            return AUPluginEntry(
                id: "\(component.manufacturerName)|\(component.name)|\(component.audioComponentDescription.componentSubType)",
                component: component,
                searchIndex: (
                    component.name + " " +
                    component.manufacturerName
                ).lowercased(),
                category: pluginCategory
            )
        }

        applyFilter()
    }

    // MARK: - Filtering

    private func applyFilter() {
        let query = searchText.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).lowercased()

        filteredEntries = entries.filter { entry in
            let matchesSearch =
                query.isEmpty || entry.searchIndex.contains(query)

            let matchesCategory =
                selectedCategory == "All" ||
                entry.category == selectedCategory

            return matchesSearch && matchesCategory
        }
    }

    // MARK: - Category detection

    private func category(for component: AVAudioUnitComponent) -> String {
        let name = component.name.lowercased()

        if name.contains("reverb") || name.contains("space designer") {
            return "Reverb"
        }

        if name.contains("delay") || name.contains("echo") {
            return "Delay"
        }

        if name.contains("compressor") ||
            name.contains("limiter") ||
            name.contains("gate") ||
            name.contains("expander") {
            return "Dynamics"
        }

        if name.contains("distortion") ||
            name.contains("overdrive") ||
            name.contains("saturat") ||
            name.contains("bitcrusher") {
            return "Distortion"
        }

        if name.contains("chorus") ||
            name.contains("flanger") ||
            name.contains("phaser") ||
            name.contains("tremolo") ||
            name.contains("vibrato") {
            return "Modulation"
        }

        return "Other"
    }

    // MARK: - Plugin Row

    private func pluginRow(_ entry: AUPluginEntry) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.component.name)
                    .font(.system(size: 12, weight: .semibold))

                HStack(spacing: 8) {
                    Text(entry.component.manufacturerName)
                    Text("·")
                    Text(entry.category)
                }
                .font(.system(size: 10))
                .foregroundColor(.secondary)
            }

            Spacer()

            Button("Select") {
                onSelect(entry.component)
                presentationMode.wrappedValue.dismiss()
            }
            .font(.system(size: 11, weight: .semibold))
        }
        .padding(8)
    }
}

// MARK: - Left Track Loader & Stem Pack Playlist View

struct LeftTrackLoaderView: View {
    @ObservedObject var backend: LiveStemBackend

    @Binding var selectedChannelIndex: Int
    @Binding var loopNewFile: Bool
    @Binding var lastLoadedFileName: String

    let onPickFile: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            playlistHeaderSection
            playlistListSection
            Divider()
            singleChannelSection
        }
        .padding(14)
        .background(Color.secondary.opacity(0.05))
    }

    @ViewBuilder
    private var playlistHeaderSection: some View {
        Text("PLAYLIST STEM PACKS")
            .font(.system(size: 13, weight: .bold))

        Text("Attivo: \(backend.loadedPackName)")
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(.blue)
            .lineLimit(1)

        HStack(spacing: 8) {
            Button("Carica Pack") {
                backend.loadHighlightedPack(autoPlay: true)
            }

            Button("Riscansiona") {
                backend.scanStemPacks()
            }
        }
    }

    @ViewBuilder
    private var playlistListSection: some View {
        if backend.availablePacks.isEmpty {
            Text("Nessun pack in StemPacks/")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .padding(.vertical, 6)

        } else {
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(
                        Array(backend.availablePacks.enumerated()),
                        id: \.element.id
                    ) { idx, pack in
                        playlistRow(index: idx, pack: pack)
                    }
                }
            }
            .frame(maxHeight: 210)
        }
    }

    private func playlistRow(
        index: Int,
        pack: StemPackItem
    ) -> some View {
        let isHighlighted = index == backend.highlightedPackIndex
        let isLoaded = pack.metadata.packName == backend.loadedPackName
        let isPackPlaying = isLoaded && backend.isPlaying

        let rowBg: Color = isHighlighted
            ? Color.blue.opacity(0.22)
            : Color.secondary.opacity(0.06)

        let weight: Font.Weight = isHighlighted ? .bold : .regular

        return VStack(alignment: .leading, spacing: 2) {
            Text("\(index + 1). \(pack.metadata.packName)")
                .font(.system(size: 11, weight: weight))
                .lineLimit(1)

            if isPackPlaying {
                Text("In riproduzione")
                    .font(.system(size: 9))
                    .foregroundColor(.green)

            } else if isLoaded {
                Text("Caricato")
                    .font(.system(size: 9))
                    .foregroundColor(.blue)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(7)
        .background(rowBg)
        .cornerRadius(6)
        .contentShape(Rectangle())
        .onTapGesture {
            backend.highlightedPackIndex = index
            backend.loadStemPack(at: index, autoPlay: false)
        }
    }

    @ViewBuilder
    private var singleChannelSection: some View {
        Text("SINGOLO CANALE")
            .font(.system(size: 12, weight: .bold))

        Button("Carica WAV su Canale...", action: onPickFile)

        Toggle("Loop automatico", isOn: $loopNewFile)
            .font(.system(size: 11))

        Text("Ultimo: \(lastLoadedFileName)")
            .font(.system(size: 10))
            .foregroundColor(.secondary)
            .lineLimit(1)

        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(backend.channels) { channel in
                    channelSelectorRow(channel)
                }
            }
        }
    }

    private func channelSelectorRow(
        _ channel: AudioChannelStrip
    ) -> some View {
        let isSelected = channel.index == selectedChannelIndex

        let currentTrackName =
            channel.currentFile?.url.lastPathComponent ?? "Vuoto"

        let rowBg: Color = isSelected
            ? Color.blue.opacity(0.18)
            : Color.secondary.opacity(0.06)

        let titleWeight: Font.Weight = isSelected
            ? .bold
            : .semibold

        return VStack(alignment: .leading, spacing: 2) {
            Text("CH \(channel.index + 1) · \(channel.roleName)")
                .font(.system(size: 10, weight: titleWeight))
                .lineLimit(1)

            Text(currentTrackName)
                .font(.system(size: 9))
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(6)
        .background(rowBg)
        .cornerRadius(5)
        .contentShape(Rectangle())
        .onTapGesture {
            selectedChannelIndex = channel.index
        }
    }
}

// MARK: - Channels Scroll View

struct ChannelsScrollView: View {
    @ObservedObject var backend: LiveStemBackend

    var body: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            HStack(spacing: 12) {
                ForEach(backend.channels) { channel in
                    ChannelStripContainerView(channel: channel)
                }
            }
            .padding(.vertical, 4)
        }
    }
}

// MARK: - Channel Strip Container View

struct ChannelStripContainerView: View {
    @ObservedObject var channel: AudioChannelStrip

    var body: some View {
        VStack(spacing: 8) {
            channelHeader
            Divider()
            ChannelKnobsView(channel: channel)
            Divider()
            ChannelFaderView(channel: channel)
            Divider()
            ChannelButtonsView(channel: channel)
        }
        .padding(8)
        .frame(width: 120, height: 740)
        .background(Color.secondary.opacity(0.06))
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(
                    Color.secondary.opacity(0.2),
                    lineWidth: 1.5
                )
        )
    }

    private var channelHeader: some View {
        VStack(spacing: 2) {
            Text("CH \(channel.index + 1)")
                .bold()
                .font(.system(size: 12, weight: .bold))

            Text(channel.roleName)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .frame(height: 18)
                .lineLimit(1)
        }
    }
}

// MARK: - Channel Knobs Section

struct ChannelKnobsView: View {
    @ObservedObject var channel: AudioChannelStrip

    var body: some View {
        VStack(spacing: 6) {
            KnobControlView(
                title: "Gain",
                value: $channel.gainValue,
                range: -12...12
            )

            KnobControlView(
                title: "High",
                value: $channel.highValue,
                range: -12...12
            )

            KnobControlView(
                title: "Mid",
                value: $channel.midValue,
                range: -12...12
            )

            KnobControlView(
                title: "Low",
                value: $channel.lowValue,
                range: -12...12
            )

            KnobControlView(
                title: "Aux2",
                value: $channel.aux2Value,
                range: 0...100
            )

            KnobControlView(
                title: "Aux1",
                value: $channel.aux1Value,
                range: 0...100
            )

            KnobControlView(
                title: "Filter",
                value: $channel.filterValue,
                range: 0...100
            )
        }
    }
}

// MARK: - Single Knob Control Component

struct KnobControlView: View {
    let title: String

    @Binding var value: Double

    let range: ClosedRange<Double>

    var body: some View {
        ScrollableKnobView(
            content: {
                VStack(spacing: 2) {
                    HStack(spacing: 2) {
                        Text(title)
                            .font(.system(size: 9, weight: .bold))

                        Spacer()

                        Text(String(format: "%.0f", value))
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(.blue)
                    }
                    .frame(width: 95)

                    ZStack {
                        Circle()
                            .stroke(
                                Color.secondary.opacity(0.3),
                                lineWidth: 3
                            )
                            .frame(width: 36, height: 36)

                        Rectangle()
                            .fill(Color.blue)
                            .frame(width: 2, height: 10)
                            .offset(y: -9)
                            .rotationEffect(
                                .degrees(angleForValue(value))
                            )
                    }
                    .frame(width: 38, height: 38)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { gesture in
                                let span = range.upperBound - range.lowerBound
                                let sensitivity = span / 180.0
                                let delta =
                                    -Double(gesture.translation.height) * sensitivity

                                let targetVal = value + (delta * 0.05)

                                value = max(
                                    range.lowerBound,
                                    min(range.upperBound, targetVal)
                                )
                            }
                    )
                    .onTapGesture(count: 2) {
                        value = range.lowerBound < 0 ? 0.0 : 50.0
                    }
                }
                .padding(.vertical, 2)
            },
            onScroll: { scrollDelta in
                let span = range.upperBound - range.lowerBound
                let step = span / 50.0

                let newValue = value + (
                    scrollDelta > 0 ? step : -step
                )

                value = max(
                    range.lowerBound,
                    min(range.upperBound, newValue)
                )
            }
        )
    }

    private func angleForValue(_ val: Double) -> Double {
        let percentage =
            (val - range.lowerBound) /
            (range.upperBound - range.lowerBound)

        return -135.0 + (percentage * 270.0)
    }
}

// MARK: - Channel Fader Section

struct ChannelFaderView: View {
    @ObservedObject var channel: AudioChannelStrip

    var body: some View {
        VStack(spacing: 2) {
            Text("\(Int(channel.faderVolume * 100))%")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(.secondary)

            ZStack(alignment: .bottom) {
                Rectangle()
                    .fill(Color.secondary.opacity(0.3))
                    .frame(width: 6, height: 130)

                Rectangle()
                    .fill(Color.blue)
                    .frame(width: 28, height: 14)
                    .cornerRadius(3)
                    .offset(y: -CGFloat(channel.faderVolume) * 116)
            }
            .frame(width: 40, height: 130)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let sliderHeight: CGFloat = 130.0

                        let localY = max(
                            0,
                            min(sliderHeight, value.location.y)
                        )

                        let newNorm = 1.0 - Double(
                            localY / sliderHeight
                        )

                        channel.faderVolume = Float(newNorm)
                    }
            )
        }
    }
}

// MARK: - Channel Buttons Section

struct ChannelButtonsView: View {
    @ObservedObject var channel: AudioChannelStrip

    var body: some View {
        VStack(spacing: 4) {
            Button(channel.isMuted ? "mute" : "MUTE") {
                channel.isMuted.toggle()
            }
            .font(.system(size: 11, weight: .bold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .foregroundColor(
                !channel.isMuted ? .white : .primary
            )
            .background(
                !channel.isMuted
                    ? Color.green
                    : Color.secondary.opacity(0.15)
            )
            .cornerRadius(4)

            Button(channel.isInsertActive ? "FX ON" : "fx off") {
                channel.isInsertActive.toggle()
            }
            .font(.system(size: 11, weight: .bold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .foregroundColor(
                channel.isInsertActive ? .white : .primary
            )
            .background(
                channel.isInsertActive
                    ? Color.orange
                    : Color.secondary.opacity(0.15)
            )
            .cornerRadius(4)
        }
    }
}

// MARK: - Scrollable Knob View

#if os(macOS)

struct ScrollableKnobView<Content: View>: NSViewRepresentable {
    let content: Content
    let onScroll: (Double) -> Void

    init(
        @ViewBuilder content: () -> Content,
        onScroll: @escaping (Double) -> Void
    ) {
        self.content = content()
        self.onScroll = onScroll
    }

    func makeNSView(context: Context) -> HostingScrollView {
        let hostingView = HostingScrollView(
            rootView: AnyView(content)
        )

        hostingView.onScroll = onScroll

        return hostingView
    }

    func updateNSView(
        _ nsView: HostingScrollView,
        context: Context
    ) {
        nsView.rootView = AnyView(content)
        nsView.onScroll = onScroll
    }
}

class HostingScrollView: NSHostingView<AnyView> {
    var onScroll: ((Double) -> Void)?

    override func scrollWheel(with event: NSEvent) {
        let delta = Double(event.deltaY)

        if abs(delta) > 0.01 {
            onScroll?(delta)
        } else {
            super.scrollWheel(with: event)
        }
    }
}

#endif