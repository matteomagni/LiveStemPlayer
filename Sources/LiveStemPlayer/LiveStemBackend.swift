import Foundation
import AVFoundation
import Combine
import CoreMIDI
import Darwin

// MARK: - Audio Feedback Bridge

private final class AudioFeedbackBridge {

    private let format: AVAudioFormat

    private let capacity = 32768
    private let mask: UInt32 = 32767
    private let minimumDelayFrames: UInt32 = 1024

    private let leftBuffer: UnsafeMutablePointer<Float>
    private let rightBuffer: UnsafeMutablePointer<Float>

    private var writeIndex: Int32 = 0
    private var readIndex: Int32 = 0

    lazy var sourceNode: AVAudioSourceNode = {
        [unowned self] in

        return AVAudioSourceNode(format: self.format) {
            [unowned self] isSilence, _, frameCount, outputData in

            return self.render(
                isSilence: isSilence,
                frameCount: frameCount,
                outputData: outputData
            )
        }
    }()

    lazy var sinkNode: AVAudioSinkNode = {
        [unowned self] in

        return AVAudioSinkNode {
            [unowned self] _, frameCount, inputData in

            return self.capture(
                frameCount: frameCount,
                inputData: inputData
            )
        }
    }()

    init(format: AVAudioFormat) {
        self.format = format

        leftBuffer = UnsafeMutablePointer<Float>.allocate(
            capacity: capacity
        )

        rightBuffer = UnsafeMutablePointer<Float>.allocate(
            capacity: capacity
        )

        leftBuffer.initialize(
            repeating: 0,
            count: capacity
        )

        rightBuffer.initialize(
            repeating: 0,
            count: capacity
        )
    }

    deinit {
        leftBuffer.deinitialize(count: capacity)
        rightBuffer.deinitialize(count: capacity)

        leftBuffer.deallocate()
        rightBuffer.deallocate()
    }

    private func atomicLoad(
        _ value: inout Int32
    ) -> Int32 {
        return OSAtomicAdd32Barrier(0, &value)
    }

    private func atomicStore(
        _ newValue: Int32,
        to value: inout Int32
    ) {
        while true {
            let oldValue = atomicLoad(&value)

            if OSAtomicCompareAndSwap32Barrier(
                oldValue,
                newValue,
                &value
            ) {
                return
            }
        }
    }

    func reset() {
        atomicStore(0, to: &writeIndex)
        atomicStore(0, to: &readIndex)
    }

    private func capture(
        frameCount: AVAudioFrameCount,
        inputData: UnsafePointer<AudioBufferList>
    ) -> OSStatus {

        let buffers = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: inputData)
        )

        guard buffers.count >= 2,
              let leftData = buffers[0].mData,
              let rightData = buffers[1].mData else {
            return kAudio_ParamError
        }

        let leftInput = leftData.assumingMemoryBound(to: Float.self)
        let rightInput = rightData.assumingMemoryBound(to: Float.self)

        var nextWrite = atomicLoad(&writeIndex)
        let currentRead = atomicLoad(&readIndex)

        for frame in 0..<Int(frameCount) {
            let usedFrames =
                UInt32(bitPattern: nextWrite) &- UInt32(bitPattern: currentRead)

            if usedFrames >= UInt32(capacity) {
                continue
            }

            let position = Int(
                UInt32(bitPattern: nextWrite) & mask
            )

            leftBuffer[position] = leftInput[frame]
            rightBuffer[position] = rightInput[frame]

            nextWrite = nextWrite &+ 1
        }

        atomicStore(nextWrite, to: &writeIndex)

        return noErr
    }

    private func render(
        isSilence: UnsafeMutablePointer<ObjCBool>,
        frameCount: AVAudioFrameCount,
        outputData: UnsafeMutablePointer<AudioBufferList>
    ) -> OSStatus {

        let buffers = UnsafeMutableAudioBufferListPointer(outputData)

        guard buffers.count >= 2,
              let leftData = buffers[0].mData,
              let rightData = buffers[1].mData else {
            return kAudio_ParamError
        }

        let leftOutput = leftData.assumingMemoryBound(to: Float.self)
        let rightOutput = rightData.assumingMemoryBound(to: Float.self)

        let currentRead = atomicLoad(&readIndex)
        let currentWrite = atomicLoad(&writeIndex)

        let availableFrames =
            UInt32(bitPattern: currentWrite) &- UInt32(bitPattern: currentRead)

        let readableFrames = availableFrames > minimumDelayFrames
            ? availableFrames - minimumDelayFrames
            : 0

        let framesToRead = min(
            UInt32(frameCount),
            readableFrames
        )

        var nextRead = currentRead

        for frame in 0..<Int(frameCount) {
            if UInt32(frame) < framesToRead {
                let position = Int(
                    UInt32(bitPattern: nextRead) & mask
                )

                leftOutput[frame] = leftBuffer[position]
                rightOutput[frame] = rightBuffer[position]

                nextRead = nextRead &+ 1
            } else {
                leftOutput[frame] = 0
                rightOutput[frame] = 0
            }
        }

        atomicStore(nextRead, to: &readIndex)

        isSilence.pointee = ObjCBool(framesToRead == 0)

        return noErr
    }
}

// MARK: - AUX Effect Type

enum AuxEffectType: String, CaseIterable, Identifiable {
    case reverb = "Reverb"
    case delay = "Delay"
    case distortion = "Distortion"

    var id: String { rawValue }
}

class LiveStemBackend: ObservableObject {

    let engine = AVAudioEngine()

    private let stereoFormat = AVAudioFormat(
        standardFormatWithSampleRate: 44100.0,
        channels: 2
    )!

    // Gli 8 canali del mixer stem
    @Published var channels: [AudioChannelStrip] = []

    // Playlist Stem Pack
    @Published var availablePacks: [StemPackItem] = []
    @Published var highlightedPackIndex: Int = 0
    @Published var loadedPackName: String = "Nessun pack"
    @Published var isPlaying: Bool = false

    // PAD FX
    let masterFXNode = AVAudioUnitReverb()
    let masterFXMixer = AVAudioMixerNode()

    // MARK: - AUX Effect Selection

    @Published private(set) var aux1EffectType: AuxEffectType = .reverb
    @Published private(set) var aux2EffectType: AuxEffectType = .delay

    private var aux1FXNode: AVAudioUnitEffect = AVAudioUnitReverb()
    let aux1FXMixer = AVAudioMixerNode()

    // Plugin Audio Unit selezionato per AUX1
    private var aux1CustomFXNode: AVAudioUnit?
    @Published private(set) var aux1PluginName: String?
    @Published private(set) var aux1PluginError: String?

    private var aux1PluginLoadRequestID = UUID()

    // Adattatori formato AUX1
    private let aux1PluginInputAdapter = AVAudioMixerNode()
    private let aux1PluginOutputAdapter = AVAudioMixerNode()

    private var aux2FXNode: AVAudioUnitEffect = AVAudioUnitDelay()
    let aux2FXMixer = AVAudioMixerNode()

    // Plugin Audio Unit selezionato per AUX2
    private var aux2CustomFXNode: AVAudioUnit?
    @Published private(set) var aux2PluginName: String?
    @Published private(set) var aux2PluginError: String?

    private var aux2PluginLoadRequestID = UUID()

    // Adattatori formato AUX2
    private let aux2PluginInputAdapter = AVAudioMixerNode()
    private let aux2PluginOutputAdapter = AVAudioMixerNode()

    // MARK: - AUX 1 Parameters

    @Published var aux1ReverbWetDry: Float = 100 {
        didSet { applyAux1Parameters() }
    }

    @Published var aux1DelayTime: Double = 0.4 {
        didSet { applyAux1Parameters() }
    }

    @Published var aux1DelayFeedback: Float = 60 {
        didSet { applyAux1Parameters() }
    }

    @Published var aux1DelayLowPass: Float = 15000 {
        didSet { applyAux1Parameters() }
    }

    @Published var aux1DelayWetDry: Float = 100 {
        didSet { applyAux1Parameters() }
    }

    @Published var aux1DistortionPreGain: Float = 0 {
        didSet { applyAux1Parameters() }
    }

    @Published var aux1DistortionWetDry: Float = 100 {
        didSet { applyAux1Parameters() }
    }

    // MARK: - AUX 2 Parameters

    @Published var aux2ReverbWetDry: Float = 100 {
        didSet { applyAux2Parameters() }
    }

    @Published var aux2DelayTime: Double = 0.4 {
        didSet { applyAux2Parameters() }
    }

    @Published var aux2DelayFeedback: Float = 60 {
        didSet { applyAux2Parameters() }
    }

    @Published var aux2DelayLowPass: Float = 15000 {
        didSet { applyAux2Parameters() }
    }

    @Published var aux2DelayWetDry: Float = 100 {
        didSet { applyAux2Parameters() }
    }

    @Published var aux2DistortionPreGain: Float = 0 {
        didSet { applyAux2Parameters() }
    }

    @Published var aux2DistortionWetDry: Float = 100 {
        didSet { applyAux2Parameters() }
    }

    // Fader dedicati ai due canali di ritorno
    private let aux1ReturnFaderMixer = AVAudioMixerNode()
    private let aux2ReturnFaderMixer = AVAudioMixerNode()

    // Bridge per il feedback incrociato.
    // CH7 -> AUX2
    // CH8 -> AUX1
    private lazy var ch7Feedback = AudioFeedbackBridge(
        format: stereoFormat
    )

    private lazy var ch8Feedback = AudioFeedbackBridge(
        format: stereoFormat
    )

    private var isEngineRunning: Bool = false
    private var lastLeftArrowTime: Date?
    private let doublePressThreshold: TimeInterval = 1.2

    // CoreMIDI
    private var midiClient = MIDIClientRef()
    private var midiInputPort = MIDIPortRef()
    private var pressedEffectNotes: Set<UInt8> = []

    private var midiOutputPort = MIDIPortRef()
    private var midiDestination = MIDIEndpointRef()

    private let midiTemplate: UInt8 = 2
    private var channelStateSubscriptions = Set<AnyCancellable>()

    init() {
        setupChannels()
        observeChannelStates()
        setupAudioEngineRouting()
        startEngine()
        scanAndLoadInitialStemPack()
        setupMIDI()
    }

    // MARK: - Canali e Routing Audio

    private func setupChannels() {
        let channelNames = [
            "Drum",
            "Bass",
            "Musica",
            "Voce",
            "Sampler?",
            "Sampler?",
            "Aux 1 Return",
            "Aux 2 Return"
        ]

        channels = channelNames.enumerated().map { index, name in
            AudioChannelStrip(index: index, roleName: name)
        }
    }

    private func updateReturnFader(_ channel: AudioChannelStrip) {
        let filterClosed =
            channel.filterValue <= 0.5 ||
            channel.filterValue >= 99.5

        let volume = filterClosed ? 0.0 : channel.faderVolume

        switch channel.index {
        case 6:
            aux1ReturnFaderMixer.outputVolume = volume

        case 7:
            aux2ReturnFaderMixer.outputVolume = volume

        default:
            break
        }
    }

    private func connectChannelGraph(_ channel: AudioChannelStrip) {
        let nodes: [AVAudioNode] = [
            channel.player,
            channel.eqNode,
            channel.sendVolumeNode,
            channel.aux1SendNode,
            channel.aux2SendNode,
            channel.muteGateMixer
        ]

        for node in nodes where node.engine !== engine {
            engine.attach(node)
        }

        // I canali 1–6 hanno una sorgente Player.
        if channel.index < 6 {
            engine.connect(
                channel.player,
                to: channel.eqNode,
                format: stereoFormat
            )
        }

        // EQ -> Fader Return -> Mute Gate per CH7 e CH8.
        if channel.index == 6 {
            engine.connect(
                channel.eqNode,
                to: aux1ReturnFaderMixer,
                format: stereoFormat
            )

            engine.connect(
                aux1ReturnFaderMixer,
                to: channel.muteGateMixer,
                format: stereoFormat
            )

            updateReturnFader(channel)

        } else if channel.index == 7 {
            engine.connect(
                channel.eqNode,
                to: aux2ReturnFaderMixer,
                format: stereoFormat
            )

            engine.connect(
                aux2ReturnFaderMixer,
                to: channel.muteGateMixer,
                format: stereoFormat
            )

            updateReturnFader(channel)

        } else {
            engine.connect(
                channel.eqNode,
                to: channel.muteGateMixer,
                format: stereoFormat
            )
        }

        // Mute Gate -> Main + PAD FX + AUX.
        let mainMixerBus = engine.mainMixerNode.nextAvailableInputBus

        var destinations = [
            AVAudioConnectionPoint(
                node: engine.mainMixerNode,
                bus: mainMixerBus
            ),
            AVAudioConnectionPoint(
                node: channel.sendVolumeNode,
                bus: 0
            )
        ]

        if channel.index < 6 {
            destinations.append(
                AVAudioConnectionPoint(
                    node: channel.aux1SendNode,
                    bus: 0
                )
            )

            destinations.append(
                AVAudioConnectionPoint(
                    node: channel.aux2SendNode,
                    bus: 0
                )
            )

        } else if channel.index == 6 {
            // CH7: mandata AUX2.
            destinations.append(
                AVAudioConnectionPoint(
                    node: channel.aux2SendNode,
                    bus: 0
                )
            )

        } else if channel.index == 7 {
            // CH8: mandata AUX1.
            destinations.append(
                AVAudioConnectionPoint(
                    node: channel.aux1SendNode,
                    bus: 0
                )
            )
        }

        engine.connect(
            channel.muteGateMixer,
            to: destinations,
            fromBus: 0,
            format: stereoFormat
        )

        // PAD FX: disponibile su tutti i canali.
        engine.connect(
            channel.sendVolumeNode,
            to: masterFXMixer,
            format: stereoFormat
        )

        // AUX dei canali 1–6.
        if channel.index < 6 {
            engine.connect(
                channel.aux1SendNode,
                to: aux1FXMixer,
                format: stereoFormat
            )

            engine.connect(
                channel.aux2SendNode,
                to: aux2FXMixer,
                format: stereoFormat
            )

        } else if channel.index == 6 {
            // CH7 -> sink -> source -> AUX2.
            engine.connect(
                channel.aux2SendNode,
                to: ch7Feedback.sinkNode,
                format: stereoFormat
            )

            engine.connect(
                ch7Feedback.sourceNode,
                to: aux2FXMixer,
                format: stereoFormat
            )

        } else if channel.index == 7 {
            // CH8 -> sink -> source -> AUX1.
            engine.connect(
                channel.aux1SendNode,
                to: ch8Feedback.sinkNode,
                format: stereoFormat
            )

            engine.connect(
                ch8Feedback.sourceNode,
                to: aux1FXMixer,
                format: stereoFormat
            )
        }

        // Ripristino livelli mandate.
        channel.sendVolumeNode.outputVolume =
            channel.isInsertActive ? 1.0 : 0.0

        channel.aux1SendNode.outputVolume = Float(
            min(100.0, max(0.0, channel.aux1Value)) / 100.0
        )

        channel.aux2SendNode.outputVolume = Float(
            min(100.0, max(0.0, channel.aux2Value)) / 100.0
        )
    }

    private func rebuildFullAudioGraph() {
        // 1. Ferma l'engine.
        if engine.isRunning {
            engine.stop()
        }

        isEngineRunning = false

        // 2. Ferma i player.
        for channel in channels {
            channel.player.stop()
        }

        // 3. Attacca i nodi FX e gli adattatori di formato.
        var fxNodes: [AVAudioNode] = [
            masterFXMixer,
            masterFXNode,

            aux1FXMixer,
            aux1FXNode,
            aux1PluginInputAdapter,
            aux1PluginOutputAdapter,

            aux2FXMixer,
            aux2FXNode,
            aux2PluginInputAdapter,
            aux2PluginOutputAdapter,

            aux1ReturnFaderMixer,
            aux2ReturnFaderMixer,

            ch7Feedback.sinkNode,
            ch7Feedback.sourceNode,
            ch8Feedback.sinkNode,
            ch8Feedback.sourceNode
        ]

        if let customPlugin = aux1CustomFXNode {
            fxNodes.append(customPlugin)
        }

        if let customPlugin = aux2CustomFXNode {
            fxNodes.append(customPlugin)
        }

        for node in fxNodes where node.engine !== engine {
            engine.attach(node)
        }

        // Gli adattatori non devono modificare il livello del segnale.
        aux1PluginInputAdapter.outputVolume = 1.0
        aux1PluginOutputAdapter.outputVolume = 1.0
        aux2PluginInputAdapter.outputVolume = 1.0
        aux2PluginOutputAdapter.outputVolume = 1.0

        // 4. Attacca i nodi dei canali.
        for channel in channels {
            let nodes: [AVAudioNode] = [
                channel.player,
                channel.eqNode,
                channel.muteGateMixer,
                channel.sendVolumeNode,
                channel.aux1SendNode,
                channel.aux2SendNode
            ]

            for node in nodes where node.engine !== engine {
                engine.attach(node)
            }
        }

        // 5. Disconnette le uscite precedenti.
        for channel in channels {
            engine.disconnectNodeOutput(channel.player)
            engine.disconnectNodeOutput(channel.eqNode)
            engine.disconnectNodeOutput(channel.muteGateMixer)
            engine.disconnectNodeOutput(channel.sendVolumeNode)
            engine.disconnectNodeOutput(channel.aux1SendNode)
            engine.disconnectNodeOutput(channel.aux2SendNode)
        }

        for node in fxNodes {
            if node is AVAudioSinkNode {
                engine.disconnectNodeInput(node)
            } else {
                engine.disconnectNodeOutput(node)
            }
        }

        // Elimina eventuali campioni residui dei feedback precedenti.
        ch7Feedback.reset()
        ch8Feedback.reset()

        // 6. Configurazione PAD FX: Reverb.
        masterFXNode.loadFactoryPreset(.largeHall)
        masterFXNode.wetDryMix = 100.0

        // 7. Configurazione effetti AUX selezionati.
        configureAuxEffectNode(
            aux1FXNode,
            type: aux1EffectType,
            aux: 1
        )

        configureAuxEffectNode(
            aux2FXNode,
            type: aux2EffectType,
            aux: 2
        )

        // 8. PAD FX -> Main Mixer.
        engine.connect(
            masterFXMixer,
            to: masterFXNode,
            format: stereoFormat
        )

        engine.connect(
            masterFXNode,
            to: engine.mainMixerNode,
            format: stereoFormat
        )

        // 9. AUX1:
        // Send stereo -> input adapter -> plugin -> output adapter -> CH7.
        let activeAux1FXNode: AVAudioNode =
            aux1CustomFXNode ?? aux1FXNode

        let aux1PluginInputFormat =
            activeAux1FXNode.inputFormat(forBus: 0)

        let aux1PluginOutputFormat =
            activeAux1FXNode.outputFormat(forBus: 0)

        print(
            "[AUX1] Plugin input: " +
            "\(aux1PluginInputFormat.channelCount) ch, " +
            "\(aux1PluginInputFormat.sampleRate) Hz"
        )

        print(
            "[AUX1] Plugin output: " +
            "\(aux1PluginOutputFormat.channelCount) ch, " +
            "\(aux1PluginOutputFormat.sampleRate) Hz"
        )

        engine.connect(
            aux1FXMixer,
            to: aux1PluginInputAdapter,
            format: stereoFormat
        )

        engine.connect(
            aux1PluginInputAdapter,
            to: activeAux1FXNode,
            format: aux1PluginInputFormat
        )

        engine.connect(
            activeAux1FXNode,
            to: aux1PluginOutputAdapter,
            format: aux1PluginOutputFormat
        )

        engine.connect(
            aux1PluginOutputAdapter,
            to: channels[6].eqNode,
            format: stereoFormat
        )

        // 10. AUX2:
        // Send stereo -> input adapter -> plugin -> output adapter -> CH8.
        let activeAux2FXNode: AVAudioNode =
            aux2CustomFXNode ?? aux2FXNode

        let aux2PluginInputFormat =
            activeAux2FXNode.inputFormat(forBus: 0)

        let aux2PluginOutputFormat =
            activeAux2FXNode.outputFormat(forBus: 0)

        print(
            "[AUX2] Plugin input: " +
            "\(aux2PluginInputFormat.channelCount) ch, " +
            "\(aux2PluginInputFormat.sampleRate) Hz"
        )

        print(
            "[AUX2] Plugin output: " +
            "\(aux2PluginOutputFormat.channelCount) ch, " +
            "\(aux2PluginOutputFormat.sampleRate) Hz"
        )

        engine.connect(
            aux2FXMixer,
            to: aux2PluginInputAdapter,
            format: stereoFormat
        )

        engine.connect(
            aux2PluginInputAdapter,
            to: activeAux2FXNode,
            format: aux2PluginInputFormat
        )

        engine.connect(
            activeAux2FXNode,
            to: aux2PluginOutputAdapter,
            format: aux2PluginOutputFormat
        )

        engine.connect(
            aux2PluginOutputAdapter,
            to: channels[7].eqNode,
            format: stereoFormat
        )

        // 11. Ricostruzione degli 8 canali.
        for channel in channels {
            connectChannelGraph(channel)
        }

        // 12. Prepara l'engine.
        engine.prepare()

        print(
            "[AUDIO GRAPH] Routing PAD FX + AUX1 + AUX2 " +
            "+ feedback incrociato ricostruito."
        )
    }

    // MARK: - AUX Effect Selection

    func setAux1Plugin(_ component: AVAudioUnitComponent) {
        let requestID = UUID()
        aux1PluginLoadRequestID = requestID
        aux1PluginError = nil

        print("[AUX1] Caricamento plugin: \(component.name)")

        AVAudioUnit.instantiate(
            with: component.audioComponentDescription,
            options: []
        ) { [weak self] audioUnit, error in

            DispatchQueue.main.async {
                guard let self = self,
                      self.aux1PluginLoadRequestID == requestID else {
                    return
                }

                if let error = error {
                    self.aux1PluginError = error.localizedDescription
                    print("[AUX1 ERROR] \(error.localizedDescription)")
                    return
                }

                guard let audioUnit = audioUnit else {
                    self.aux1PluginError =
                        "Impossibile istanziare il plugin."
                    return
                }

                self.installAux1Plugin(
                    audioUnit,
                    name: component.name
                )
            }
        }
    }

    private func installAux1Plugin(
        _ plugin: AVAudioUnit,
        name: String
    ) {
        let resumePlayback = isPlaying

        let pauseHostTime = mach_absolute_time()

        for channel in channels {
            channel.pauseForGraphRebuild(atHostTime: pauseHostTime)
        }

        engine.stop()

        if let oldPlugin = aux1CustomFXNode {
            engine.disconnectNodeInput(oldPlugin)
            engine.disconnectNodeOutput(oldPlugin)

            if oldPlugin.engine === engine {
                engine.detach(oldPlugin)
            }
        }

        aux1CustomFXNode = plugin
        aux1PluginName = name
        aux1PluginError = nil

        rebuildFullAudioGraph()

        print("[AUX1] Plugin installato: \(name)")

        if resumePlayback {
            startEngine()

            let channelsToResume = channels.filter {
                $0.prepareResumeAfterGraphRebuild()
            }

            let startHostTime = mach_absolute_time()
                + AVAudioTime.hostTime(forSeconds: 0.15)

            for channel in channelsToResume {
                channel.resumeAfterGraphRebuild(atHostTime: startHostTime)
            }

            isPlaying = !channelsToResume.isEmpty
        } else {
            isPlaying = false
        }
    }

    func setAux2Plugin(_ component: AVAudioUnitComponent) {
        let requestID = UUID()
        aux2PluginLoadRequestID = requestID
        aux2PluginError = nil

        print("[AUX2] Caricamento plugin: \(component.name)")

        AVAudioUnit.instantiate(
            with: component.audioComponentDescription,
            options: []
        ) { [weak self] audioUnit, error in

            DispatchQueue.main.async {
                guard let self = self,
                      self.aux2PluginLoadRequestID == requestID else {
                    return
                }

                if let error = error {
                    self.aux2PluginError = error.localizedDescription
                    print("[AUX2 ERROR] \(error.localizedDescription)")
                    return
                }

                guard let audioUnit = audioUnit else {
                    self.aux2PluginError =
                        "Impossibile istanziare il plugin."
                    return
                }

                self.installAux2Plugin(
                    audioUnit,
                    name: component.name
                )
            }
        }
    }

    private func installAux2Plugin(
        _ plugin: AVAudioUnit,
        name: String
    ) {
        let resumePlayback = isPlaying

        let pauseHostTime = mach_absolute_time()

        for channel in channels {
            channel.pauseForGraphRebuild(atHostTime: pauseHostTime)
        }

        engine.stop()

        if let oldPlugin = aux2CustomFXNode {
            engine.disconnectNodeInput(oldPlugin)
            engine.disconnectNodeOutput(oldPlugin)

            if oldPlugin.engine === engine {
                engine.detach(oldPlugin)
            }
        }

        aux2CustomFXNode = plugin
        aux2PluginName = name
        aux2PluginError = nil

        rebuildFullAudioGraph()

        print("[AUX2] Plugin installato: \(name)")

        if resumePlayback {
            startEngine()

            let channelsToResume = channels.filter {
                $0.prepareResumeAfterGraphRebuild()
            }

            let startHostTime = mach_absolute_time()
                + AVAudioTime.hostTime(forSeconds: 0.15)

            for channel in channelsToResume {
                channel.resumeAfterGraphRebuild(atHostTime: startHostTime)
            }

            isPlaying = !channelsToResume.isEmpty
        } else {
            isPlaying = false
        }
    }

    func setAux1EffectType(_ type: AuxEffectType) {
        guard type != aux1EffectType ||
            aux1CustomFXNode != nil else {
            return
        }

        aux1PluginLoadRequestID = UUID()

        let resumePlayback = isPlaying
        let pauseHostTime = mach_absolute_time()

        for channel in channels {
            channel.pauseForGraphRebuild(atHostTime: pauseHostTime)
        }

        engine.stop()

        if let customPlugin = aux1CustomFXNode {
            engine.disconnectNodeInput(customPlugin)
            engine.disconnectNodeOutput(customPlugin)

            if customPlugin.engine === engine {
                engine.detach(customPlugin)
            }
        }

        aux1CustomFXNode = nil
        aux1PluginName = nil
        aux1PluginError = nil

        aux1EffectType = type
        aux1FXNode = makeAuxEffectNode(for: type)

        rebuildFullAudioGraph()

        if resumePlayback {
            startEngine()

            let channelsToResume = channels.filter {
                $0.prepareResumeAfterGraphRebuild()
            }

            let startHostTime = mach_absolute_time()
                + AVAudioTime.hostTime(forSeconds: 0.15)

            for channel in channelsToResume {
                channel.resumeAfterGraphRebuild(atHostTime: startHostTime)
            }

            isPlaying = !channelsToResume.isEmpty
        } else {
            isPlaying = false
        }
    }

    func setAux2EffectType(_ type: AuxEffectType) {
        guard type != aux2EffectType ||
            aux2CustomFXNode != nil else {
            return
        }

        aux2PluginLoadRequestID = UUID()

        let resumePlayback = isPlaying
        let pauseHostTime = mach_absolute_time()

        for channel in channels {
            channel.pauseForGraphRebuild(atHostTime: pauseHostTime)
        }

        engine.stop()

        if let customPlugin = aux2CustomFXNode {
            engine.disconnectNodeInput(customPlugin)
            engine.disconnectNodeOutput(customPlugin)

            if customPlugin.engine === engine {
                engine.detach(customPlugin)
            }
        }

        aux2CustomFXNode = nil
        aux2PluginName = nil
        aux2PluginError = nil

        aux2EffectType = type
        aux2FXNode = makeAuxEffectNode(for: type)

        rebuildFullAudioGraph()

        if resumePlayback {
            startEngine()

            let channelsToResume = channels.filter {
                $0.prepareResumeAfterGraphRebuild()
            }

            let startHostTime = mach_absolute_time()
                + AVAudioTime.hostTime(forSeconds: 0.15)

            for channel in channelsToResume {
                channel.resumeAfterGraphRebuild(atHostTime: startHostTime)
            }

            isPlaying = !channelsToResume.isEmpty
        } else {
            isPlaying = false
        }
    }

    // MARK: - AUX Effect Parameters

    private func applyAux1Parameters() {
        configureAuxEffectNode(
            aux1FXNode,
            type: aux1EffectType,
            aux: 1
        )
    }

    private func applyAux2Parameters() {
        configureAuxEffectNode(
            aux2FXNode,
            type: aux2EffectType,
            aux: 2
        )
    }

    private func configureAuxEffectNode(
        _ node: AVAudioUnitEffect,
        type: AuxEffectType,
        aux: Int
    ) {
        switch type {
        case .reverb:
            guard let reverb = node as? AVAudioUnitReverb else {
                return
            }

            if aux == 1 {
                reverb.wetDryMix = aux1ReverbWetDry
            } else {
                reverb.wetDryMix = aux2ReverbWetDry
            }

            reverb.loadFactoryPreset(.mediumHall)

            reverb.wetDryMix = aux == 1
                ? aux1ReverbWetDry
                : aux2ReverbWetDry

        case .delay:
            guard let delay = node as? AVAudioUnitDelay else {
                return
            }

            if aux == 1 {
                delay.delayTime = aux1DelayTime
                delay.feedback = aux1DelayFeedback
                delay.lowPassCutoff = aux1DelayLowPass
                delay.wetDryMix = aux1DelayWetDry
            } else {
                delay.delayTime = aux2DelayTime
                delay.feedback = aux2DelayFeedback
                delay.lowPassCutoff = aux2DelayLowPass
                delay.wetDryMix = aux2DelayWetDry
            }

        case .distortion:
            guard let distortion = node as? AVAudioUnitDistortion else {
                return
            }

            distortion.loadFactoryPreset(.drumsBitBrush)

            if aux == 1 {
                distortion.preGain = aux1DistortionPreGain
                distortion.wetDryMix = aux1DistortionWetDry
            } else {
                distortion.preGain = aux2DistortionPreGain
                distortion.wetDryMix = aux2DistortionWetDry
            }
        }
    }

    private func makeAuxEffectNode(
        for type: AuxEffectType
    ) -> AVAudioUnitEffect {
        switch type {
        case .reverb:
            return AVAudioUnitReverb()

        case .delay:
            return AVAudioUnitDelay()

        case .distortion:
            return AVAudioUnitDistortion()
        }
    }

    // MARK: - Audio Engine

    private func setupAudioEngineRouting() {
        rebuildFullAudioGraph()
    }

    private func hasValidOutputFormat() -> Bool {
        let outFormat = engine.outputNode.outputFormat(forBus: 0)
        let mixFormat = engine.mainMixerNode.outputFormat(forBus: 0)

        return outFormat.sampleRate > 0 &&
            outFormat.channelCount > 0 &&
            mixFormat.sampleRate > 0 &&
            mixFormat.channelCount > 0
    }

    func startEngine() {
        if engine.isRunning && hasValidOutputFormat() {
            isEngineRunning = true
            return
        }

        guard hasValidOutputFormat() else {
            isEngineRunning = false
            return
        }

        do {
            engine.prepare()
            try engine.start()
            isEngineRunning = engine.isRunning
        } catch {
            isEngineRunning = false
            print("[AUDIO ENGINE ERROR] Impossibile avviare l'engine: \(error)")
        }
    }

    private func isChannelGraphValid(
        _ channel: AudioChannelStrip
    ) -> Bool {
        let nodes: [AVAudioNode] = [
            channel.player,
            channel.eqNode,
            channel.muteGateMixer,
            channel.sendVolumeNode,
            channel.aux1SendNode,
            channel.aux2SendNode
        ]

        guard nodes.allSatisfy({ $0.engine === engine }) else {
            return false
        }

        if channel.index < 6 {
            let playerOutputs = engine.outputConnectionPoints(
                for: channel.player,
                outputBus: 0
            )

            guard playerOutputs.contains(where: {
                $0.node === channel.eqNode
            }) else {
                return false
            }
        }

        let eqOutputs = engine.outputConnectionPoints(
            for: channel.eqNode,
            outputBus: 0
        )

        if channel.index == 6 {
            guard eqOutputs.contains(where: {
                $0.node === aux1ReturnFaderMixer
            }) else {
                return false
            }

        } else if channel.index == 7 {
            guard eqOutputs.contains(where: {
                $0.node === aux2ReturnFaderMixer
            }) else {
                return false
            }

        } else {
            guard eqOutputs.contains(where: {
                $0.node === channel.muteGateMixer
            }) else {
                return false
            }
        }

        let muteOutputs = engine.outputConnectionPoints(
            for: channel.muteGateMixer,
            outputBus: 0
        )

        guard muteOutputs.contains(where: {
            $0.node === engine.mainMixerNode
        }) else {
            return false
        }

        guard muteOutputs.contains(where: {
            $0.node === channel.sendVolumeNode
        }) else {
            return false
        }

        if channel.index < 6 {
            guard muteOutputs.contains(where: {
                $0.node === channel.aux1SendNode
            }) else {
                return false
            }

            guard muteOutputs.contains(where: {
                $0.node === channel.aux2SendNode
            }) else {
                return false
            }

        } else if channel.index == 6 {
            guard muteOutputs.contains(where: {
                $0.node === channel.aux2SendNode
            }) else {
                return false
            }

        } else if channel.index == 7 {
            guard muteOutputs.contains(where: {
                $0.node === channel.aux1SendNode
            }) else {
                return false
            }
        }

        let padOutputs = engine.outputConnectionPoints(
            for: channel.sendVolumeNode,
            outputBus: 0
        )

        guard padOutputs.contains(where: {
            $0.node === masterFXMixer
        }) else {
            return false
        }

        if channel.index < 6 {
            let aux1Outputs = engine.outputConnectionPoints(
                for: channel.aux1SendNode,
                outputBus: 0
            )

            guard aux1Outputs.contains(where: {
                $0.node === aux1FXMixer
            }) else {
                return false
            }

            let aux2Outputs = engine.outputConnectionPoints(
                for: channel.aux2SendNode,
                outputBus: 0
            )

            guard aux2Outputs.contains(where: {
                $0.node === aux2FXMixer
            }) else {
                return false
            }

        } else if channel.index == 6 {
            let sendOutputs = engine.outputConnectionPoints(
                for: channel.aux2SendNode,
                outputBus: 0
            )

            guard sendOutputs.contains(where: {
                $0.node === ch7Feedback.sinkNode
            }) else {
                return false
            }

            let feedbackOutputs = engine.outputConnectionPoints(
                for: ch7Feedback.sourceNode,
                outputBus: 0
            )

            guard feedbackOutputs.contains(where: {
                $0.node === aux2FXMixer
            }) else {
                return false
            }

        } else if channel.index == 7 {
            let sendOutputs = engine.outputConnectionPoints(
                for: channel.aux1SendNode,
                outputBus: 0
            )

            guard sendOutputs.contains(where: {
                $0.node === ch8Feedback.sinkNode
            }) else {
                return false
            }

            let feedbackOutputs = engine.outputConnectionPoints(
                for: ch8Feedback.sourceNode,
                outputBus: 0
            )

            guard feedbackOutputs.contains(where: {
                $0.node === aux1FXMixer
            }) else {
                return false
            }
        }

        // Verifica routing AUX1.
        let activeAux1FXNode: AVAudioNode =
            aux1CustomFXNode ?? aux1FXNode

        let aux1MixerOutputs = engine.outputConnectionPoints(
            for: aux1FXMixer,
            outputBus: 0
        )

        guard aux1MixerOutputs.contains(where: {
            $0.node === aux1PluginInputAdapter
        }) else {
            return false
        }

        let aux1InputAdapterOutputs = engine.outputConnectionPoints(
            for: aux1PluginInputAdapter,
            outputBus: 0
        )

        guard aux1InputAdapterOutputs.contains(where: {
            $0.node === activeAux1FXNode
        }) else {
            return false
        }

        let activeAux1Outputs = engine.outputConnectionPoints(
            for: activeAux1FXNode,
            outputBus: 0
        )

        guard activeAux1Outputs.contains(where: {
            $0.node === aux1PluginOutputAdapter
        }) else {
            return false
        }

        let aux1OutputAdapterOutputs = engine.outputConnectionPoints(
            for: aux1PluginOutputAdapter,
            outputBus: 0
        )

        guard aux1OutputAdapterOutputs.contains(where: {
            $0.node === channels[6].eqNode
        }) else {
            return false
        }

        // Verifica routing AUX2.
        let activeAux2FXNode: AVAudioNode =
            aux2CustomFXNode ?? aux2FXNode

        let aux2MixerOutputs = engine.outputConnectionPoints(
            for: aux2FXMixer,
            outputBus: 0
        )

        guard aux2MixerOutputs.contains(where: {
            $0.node === aux2PluginInputAdapter
        }) else {
            return false
        }

        let aux2InputAdapterOutputs = engine.outputConnectionPoints(
            for: aux2PluginInputAdapter,
            outputBus: 0
        )

        guard aux2InputAdapterOutputs.contains(where: {
            $0.node === activeAux2FXNode
        }) else {
            return false
        }

        let activeAux2Outputs = engine.outputConnectionPoints(
            for: activeAux2FXNode,
            outputBus: 0
        )

        guard activeAux2Outputs.contains(where: {
            $0.node === aux2PluginOutputAdapter
        }) else {
            return false
        }

        let aux2OutputAdapterOutputs = engine.outputConnectionPoints(
            for: aux2PluginOutputAdapter,
            outputBus: 0
        )

        guard aux2OutputAdapterOutputs.contains(where: {
            $0.node === channels[7].eqNode
        }) else {
            return false
        }

        return true
    }

    private func ensureChannelReady(
        _ channel: AudioChannelStrip
    ) -> Bool {
        guard channel.currentFile != nil else {
            return false
        }

        if !isChannelGraphValid(channel) {
            print("[AUDIO GRAPH] Routing non valido CH \(channel.index + 1).")
            rebuildFullAudioGraph()
            startEngine()
        }

        guard engine.isRunning,
              hasValidOutputFormat(),
              isChannelGraphValid(channel) else {
            print("[AUDIO ERROR] CH \(channel.index + 1) non pronto.")
            return false
        }

        return true
    }

    // MARK: - Gestione StemPacks

    private func resolveStemPacksDirectory() -> URL? {
        let fm = FileManager.default

        let cwdURL = URL(fileURLWithPath: fm.currentDirectoryPath)
            .appendingPathComponent("StemPacks")

        if fm.fileExists(atPath: cwdURL.path) {
            return cwdURL
        }

        var searchURL = URL(
            fileURLWithPath: CommandLine.arguments[0]
        ).deletingLastPathComponent()

        for _ in 0..<5 {
            let candidate = searchURL.appendingPathComponent("StemPacks")

            if fm.fileExists(atPath: candidate.path) {
                return candidate
            }

            searchURL.deleteLastPathComponent()
        }

        return nil
    }

    func scanAndLoadInitialStemPack() {
        scanStemPacks()
        highlightedPackIndex = 0
    }

    func scanStemPacks() {
        guard let rootURL = resolveStemPacksDirectory() else {
            print("[STEMPACKS] Cartella 'StemPacks' non trovata.")
            availablePacks = []
            return
        }

        let fm = FileManager.default

        guard let entries = try? fm.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        let folders = entries
            .filter {
                (try? $0.resourceValues(
                    forKeys: [.isDirectoryKey]
                ).isDirectory) == true
            }
            .sorted {
                $0.lastPathComponent.localizedStandardCompare(
                    $1.lastPathComponent
                ) == .orderedAscending
            }

        availablePacks = folders.map { folder in
            let metaURL = folder.appendingPathComponent("metadata.json")

            if let data = try? Data(contentsOf: metaURL),
               let decoded = try? JSONDecoder().decode(
                StemPackMetadata.self,
                from: data
               ) {
                return StemPackItem(
                    folderURL: folder,
                    metadata: decoded
                )
            }

            let fallbackMeta = StemPackMetadata(
                packName: folder.lastPathComponent,
                bpm: 120.0,
                channelSettings: []
            )

            return StemPackItem(
                folderURL: folder,
                metadata: fallbackMeta
            )
        }

        print("[STEMPACKS] Trovati \(availablePacks.count) pack in \(rootURL.path)")
    }

    func loadHighlightedPack(autoPlay: Bool = false) {
        loadStemPack(
            at: highlightedPackIndex,
            autoPlay: autoPlay
        )
    }

    func loadStemPack(
        at packIndex: Int,
        autoPlay: Bool = false
    ) {
        guard packIndex >= 0 &&
              packIndex < availablePacks.count else {
            return
        }

        let pack = availablePacks[packIndex]
        let fm = FileManager.default

        stopAll()

        let allowedExt: Set<String> = [
            "wav", "aif", "aiff", "mp3", "m4a", "flac"
        ]

        let allFiles = (try? fm.contentsOfDirectory(
            at: pack.folderURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []

        let audioFiles = allFiles
            .filter {
                allowedExt.contains($0.pathExtension.lowercased())
            }
            .sorted {
                $0.lastPathComponent.localizedStandardCompare(
                    $1.lastPathComponent
                ) == .orderedAscending
            }

        // Gli Stem Pack caricano solo CH1–CH6.
        let stemChannelCount = min(6, channels.count)

        for i in 0..<stemChannelCount {
            let explicitStem = audioFiles.first {
                $0.deletingPathExtension()
                    .lastPathComponent.lowercased() == "stem\(i + 1)"
            }

            let fileURL = explicitStem ??
                (i < audioFiles.count ? audioFiles[i] : nil)

            if let url = fileURL {
                channels[i].loadFile(
                    url: url,
                    loop: true,
                    autoPlay: false
                )
            } else {
                channels[i].clearAudio()
            }
        }

        // CH7 e CH8 sono return FX, mai sorgenti audio.
        for i in stemChannelCount..<channels.count {
            channels[i].clearAudio()
        }

        highlightedPackIndex = packIndex
        loadedPackName = pack.metadata.packName
        isPlaying = false

        print("[STEMPACKS] Caricato pack '\(loadedPackName)' (\(audioFiles.count) file)")

        if autoPlay {
            playAll()
        }
    }

    func selectPreviousPack() {
        guard !availablePacks.isEmpty else { return }

        highlightedPackIndex = max(
            0,
            highlightedPackIndex - 1
        )
    }

    func selectNextPack() {
        guard !availablePacks.isEmpty else { return }

        highlightedPackIndex = min(
            availablePacks.count - 1,
            highlightedPackIndex + 1
        )
    }

    // MARK: - Trasporto e Navigazione Brani
    private func startLoadedChannelsSynchronously() {
        startEngine()

        guard engine.isRunning,
            hasValidOutputFormat() else {
            isPlaying = false
            return
        }

        // Prima prepariamo tutti i player.
        var channelsToStart: [AudioChannelStrip] = []

        for channel in channels {
            guard ensureChannelReady(channel) else {
                continue
            }

            if channel.prepareForSynchronizedStart() {
                channelsToStart.append(channel)
            }
        }

        guard !channelsToStart.isEmpty else {
            isPlaying = false
            return
        }

        // Un solo istante di partenza per tutti i player.
        let startHostTime = mach_absolute_time()
            + AVAudioTime.hostTime(forSeconds: 0.20)

        for channel in channelsToStart {
            channel.startAtHostTime(startHostTime)
        }

        isPlaying = true
    }

    func loadStem(at index: Int, url: URL) {
        guard index >= 0 && index < min(6, channels.count) else {
            return
        }

        channels[index].loadFile(
            url: url,
            loop: true,
            autoPlay: false
        )
    }

    func playAll() {
        startLoadedChannelsSynchronously()
    }

    func stopAll() {
        for channel in channels {
            channel.player.stop()
        }

        isPlaying = false
    }

    func handleRightArrow() {
        if !isPlaying {
            playAll()

        } else if !availablePacks.isEmpty {
            let nextIndex = (
                highlightedPackIndex + 1
            ) % availablePacks.count

            loadStemPack(
                at: nextIndex,
                autoPlay: true
            )
        }
    }

    func handleLeftArrow() {
        let now = Date()

        let isDoubleTap = lastLeftArrowTime.map {
            now.timeIntervalSince($0) <= doublePressThreshold
        } ?? false

        lastLeftArrowTime = now

        if isDoubleTap && !availablePacks.isEmpty {
            let prevIndex = (
                highlightedPackIndex - 1 + availablePacks.count
            ) % availablePacks.count

            loadStemPack(
                at: prevIndex,
                autoPlay: true
            )
        } else {
            startLoadedChannelsSynchronously()
        }
    }

    // MARK: - CoreMIDI (Novation Launch Control XL)

    private func setupMIDI() {
        let clientStatus = MIDIClientCreateWithBlock(
            "LiveStemPlayerMIDIClient" as CFString,
            &midiClient
        ) { [weak self] notification in
            if notification.pointee.messageID == .msgSetupChanged {
                self?.connectAllMIDISources()
            }
        }

        guard clientStatus == noErr else {
            print("[MIDI ERROR] MIDIClientCreate fallito: \(clientStatus)")
            return
        }

        let portStatus = MIDIInputPortCreateWithBlock(
            midiClient,
            "LiveStemPlayerInput" as CFString,
            &midiInputPort
        ) { [weak self] packetList, _ in
            self?.handleMIDIPacketList(packetList)
        }

        guard portStatus == noErr else {
            print("[MIDI ERROR] MIDIInputPortCreate fallito: \(portStatus)")
            return
        }

        connectAllMIDISources()
        setupMIDIOutput()
    }

    private func connectAllMIDISources() {
        let sourceCount = MIDIGetNumberOfSources()

        print("[MIDI] Sorgenti trovate: \(sourceCount)")

        for i in 0..<sourceCount {
            let src = MIDIGetSource(i)

            var nameRef: Unmanaged<CFString>?

            MIDIObjectGetStringProperty(
                src,
                kMIDIPropertyDisplayName,
                &nameRef
            )

            let name = (nameRef?.takeRetainedValue() as String?) ??
                "Sorgente \(i)"

            MIDIPortConnectSource(
                midiInputPort,
                src,
                nil
            )

            print("[MIDI] Connesso a: \(name)")
        }
    }

    private func handleMIDIPacketList(
        _ packetList: UnsafePointer<MIDIPacketList>
    ) {
        var packet = packetList.pointee.packet

        for _ in 0..<packetList.pointee.numPackets {
            let bytes = Mirror(reflecting: packet.data)
                .children
                .prefix(Int(packet.length))
                .compactMap { $0.value as? UInt8 }

            parseMIDIBytes(bytes)
            packet = MIDIPacketNext(&packet).pointee
        }
    }

    private func parseMIDIBytes(_ bytes: [UInt8]) {
        var index = 0

        while index + 2 < bytes.count {
            let status = bytes[index]
            let msgType = status & 0xF0
            let data1 = bytes[index + 1]
            let data2 = bytes[index + 2]

            if msgType == 0xB0 ||
               msgType == 0x90 ||
               msgType == 0x80 {

                DispatchQueue.main.async { [weak self] in
                    self?.dispatchMIDIMessage(
                        type: msgType,
                        number: data1,
                        value: data2
                    )
                }

                index += 3

            } else {
                index += 1
            }
        }
    }

    private func dispatchMIDIMessage(
        type: UInt8,
        number: UInt8,
        value: UInt8
    ) {
        print(
            String(
                format: "[MIDI IN] type=0x%02X num=%d val=%d",
                type,
                number,
                value
            )
        )

        let row1Aux2CC: [UInt8] =
            [13, 14, 15, 16, 17, 18, 19, 20]

        let row2Aux1CC: [UInt8] =
            [29, 30, 31, 32, 33, 34, 35, 36]

        let row3FilterCC: [UInt8] =
            [49, 50, 51, 52, 53, 54, 55, 56]

        let faderCC: [UInt8] =
            [77, 78, 79, 80, 81, 82, 83, 84]

        let muteNotes: [UInt8] =
            [41, 42, 43, 44, 57, 58, 59, 60]

        let effectNotes: [UInt8] =
            [73, 74, 75, 76, 89, 90, 91, 92]

        // MARK: Control Change

        if type == 0xB0 {
            let norm = Double(value) / 127.0

            if let ch = row1Aux2CC.firstIndex(of: number),
               ch < channels.count {
                channels[ch].aux2Value = norm * 100.0
                return
            }

            if let ch = row2Aux1CC.firstIndex(of: number),
               ch < channels.count {
                channels[ch].aux1Value = norm * 100.0
                return
            }

            if let ch = row3FilterCC.firstIndex(of: number),
               ch < channels.count {
                channels[ch].filterValue = norm * 100.0
                return
            }

            if let ch = faderCC.firstIndex(of: number),
               ch < channels.count {
                channels[ch].faderVolume = Float(norm)
                return
            }

            if value > 0 {
                switch number {
                case 104:
                    selectPreviousPack()

                case 105:
                    selectNextPack()

                case 106:
                    handleLeftArrow()

                case 107:
                    handleRightArrow()

                default:
                    break
                }
            }

            return
        }

        // MARK: Note On / Note Off

        guard type == 0x90 || type == 0x80 else {
            return
        }

        // Pulsanti FX.
        if let ch = effectNotes.firstIndex(of: number),
           ch < channels.count {

            if type == 0x90 && value > 0 {
                guard !pressedEffectNotes.contains(number) else {
                    return
                }

                pressedEffectNotes.insert(number)
                channels[ch].isInsertActive.toggle()

                print(
                    "[FX] CH \(ch + 1): " +
                    "\(channels[ch].isInsertActive ? "ON" : "OFF")"
                )

            } else {
                pressedEffectNotes.remove(number)
            }

            return
        }

        guard type == 0x90 && value > 0 else {
            return
        }

        // Pulsanti Mute.
        if let ch = muteNotes.firstIndex(of: number),
           ch < channels.count {
            channels[ch].isMuted.toggle()
            return
        }

        // Pulsante Device.
        if number == 105 {
            loadHighlightedPack(autoPlay: false)
            return
        }
    }

    // MARK: - Osservazione stati canali

    private func observeChannelStates() {
        for channel in channels {
            channel.$isMuted
                .dropFirst()
                .sink { [weak self, weak channel] isMuted in
                    guard let self = self,
                          let channel = channel else {
                        return
                    }

                    self.updateMuteLED(
                        channel,
                        isMuted: isMuted
                    )
                }
                .store(in: &channelStateSubscriptions)

            channel.$isInsertActive
                .dropFirst()
                .sink { [weak self, weak channel] isInsertActive in
                    guard let self = self,
                          let channel = channel else {
                        return
                    }

                    self.updateFXLED(
                        channel,
                        isInsertActive: isInsertActive
                    )
                }
                .store(in: &channelStateSubscriptions)

            if channel.index >= 6 {
                channel.$faderVolume
                    .dropFirst()
                    .sink { [weak self, weak channel] _ in
                        guard let self = self,
                              let channel = channel else {
                            return
                        }

                        self.updateReturnFader(channel)
                    }
                    .store(in: &channelStateSubscriptions)

                channel.$filterValue
                    .dropFirst()
                    .sink { [weak self, weak channel] _ in
                        guard let self = self,
                              let channel = channel else {
                            return
                        }

                        self.updateReturnFader(channel)
                    }
                    .store(in: &channelStateSubscriptions)
            }
        }
    }

    // MARK: - MIDI Output e LED

    private func setupMIDIOutput() {
        let status = MIDIOutputPortCreate(
            midiClient,
            "LiveStemPlayerOutput" as CFString,
            &midiOutputPort
        )

        guard status == noErr else {
            print("[MIDI ERROR] Output port: \(status)")
            return
        }

        let destinationCount = MIDIGetNumberOfDestinations()

        for index in 0..<destinationCount {
            let destination = MIDIGetDestination(index)

            var nameRef: Unmanaged<CFString>?

            MIDIObjectGetStringProperty(
                destination,
                kMIDIPropertyDisplayName,
                &nameRef
            )

            let name = (nameRef?.takeRetainedValue() as String?) ?? ""

            if name.localizedCaseInsensitiveContains("Launch Control XL") {
                midiDestination = destination
                print("[MIDI OUT] Connesso a: \(name)")
                syncAllChannelLEDs()
                return
            }
        }

        print("[MIDI OUT] Launch Control XL non trovato")
    }

    private func sendLED(index: UInt8, value: UInt8) {
        guard midiDestination != 0 else {
            return
        }

        var packetList = MIDIPacketList()
        let packet = MIDIPacketListInit(&packetList)

        let bytes: [UInt8] = [
            0xF0, 0x00, 0x20, 0x29,
            0x02, 0x11, 0x78,
            midiTemplate,
            index,
            value,
            0xF7
        ]

        bytes.withUnsafeBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else {
                return
            }

            MIDIPacketListAdd(
                &packetList,
                MemoryLayout<MIDIPacketList>.size,
                packet,
                0,
                bytes.count,
                baseAddress
            )
        }

        let status = MIDISend(
            midiOutputPort,
            midiDestination,
            &packetList
        )

        if status != noErr {
            print("[MIDI ERROR] LED \(index): \(status)")
        }
    }

    private func updateChannelLEDs(_ channel: AudioChannelStrip) {
        updateMuteLED(
            channel,
            isMuted: channel.isMuted
        )

        updateFXLED(
            channel,
            isInsertActive: channel.isInsertActive
        )
    }

    private func updateMuteLED(
        _ channel: AudioChannelStrip,
        isMuted: Bool
    ) {
        let index = UInt8(24 + channel.index)
        sendLED(
            index: index,
            value: isMuted ? 12 : 60
        )
    }

    private func updateFXLED(
        _ channel: AudioChannelStrip,
        isInsertActive: Bool
    ) {
        let index = UInt8(32 + channel.index)
        sendLED(
            index: index,
            value: isInsertActive ? 63 : 12
        )
    }

    private func syncAllChannelLEDs() {
        for channel in channels {
            updateChannelLEDs(channel)
        }
    }
}