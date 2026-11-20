import Foundation
import AVFoundation
import SwiftUI
import Darwin

class AudioChannelStrip: ObservableObject, Identifiable {
    let index: Int
    let roleName: String

    let player = AVAudioPlayerNode()
    let eqNode = AVAudioUnitEQ(numberOfBands: 4)

    // Mandate indipendenti
    let sendVolumeNode = AVAudioMixerNode() // PAD FX
    let aux1SendNode = AVAudioMixerNode()
    let aux2SendNode = AVAudioMixerNode()

    let muteGateMixer = AVAudioMixerNode()

    var currentFile: AVAudioFile?
    private var stereoBuffer: AVAudioPCMBuffer?
    var isLooping: Bool = true

    // Posizione da ripristinare dopo una ricostruzione del routing.
    private var pendingResumeFrame: AVAudioFramePosition?

    static let targetFormat = AVAudioFormat(
        standardFormatWithSampleRate: 44100.0,
        channels: 2
    )!

    @Published var faderVolume: Float = 0.8 {
        didSet { updateOutputVolume() }
    }

    @Published var isMuted: Bool = false {
        didSet {
            muteGateMixer.outputVolume = isMuted ? 0.0 : 1.0
        }
    }

    // PAD FX
    @Published var isInsertActive: Bool = false {
        didSet {
            sendVolumeNode.outputVolume = isInsertActive ? 1.0 : 0.0
        }
    }

    // Controlli EQ
    @Published var gainValue: Double = 0.0 {
        didSet { applyEQSettings() }
    }

    @Published var highValue: Double = 0.0 {
        didSet { applyEQSettings() }
    }

    @Published var midValue: Double = 0.0 {
        didSet { applyEQSettings() }
    }

    @Published var lowValue: Double = 0.0 {
        didSet { applyEQSettings() }
    }

    // Mandate AUX indipendenti (0–100)
    @Published var aux1Value: Double = 0.0 {
        didSet {
            aux1SendNode.outputVolume = Float(
                min(100.0, max(0.0, aux1Value)) / 100.0
            )
        }
    }

    @Published var aux2Value: Double = 0.0 {
        didSet {
            aux2SendNode.outputVolume = Float(
                min(100.0, max(0.0, aux2Value)) / 100.0
            )
        }
    }

    @Published var filterValue: Double = 50.0 {
        didSet { applyFilter() }
    }

    @Published var eqSettings = ChannelEQSettings()

    init(index: Int, roleName: String) {
        self.index = index
        self.roleName = roleName

        setupEQBands()

        sendVolumeNode.outputVolume = 0.0
        aux1SendNode.outputVolume = 0.0
        aux2SendNode.outputVolume = 0.0
    }

    // MARK: - Volume

    private func updateOutputVolume() {
        let filterClosed = filterValue <= 0.5 || filterValue >= 99.5
        player.volume = filterClosed ? 0.0 : faderVolume
    }

    // MARK: - EQ

    private func setupEQBands() {
        eqNode.bypass = false
        eqNode.globalGain = 0.0

        let low = eqNode.bands[0]
        low.filterType = .lowShelf
        low.frequency = 80.0
        low.gain = 0.0
        low.bypass = false

        let mid = eqNode.bands[1]
        mid.filterType = .parametric
        mid.frequency = 1000.0
        mid.bandwidth = 1.0
        mid.gain = 0.0
        mid.bypass = false

        let high = eqNode.bands[2]
        high.filterType = .highShelf
        high.frequency = 8000.0
        high.gain = 0.0
        high.bypass = false

        // Quarta banda riservata al Filter
        eqNode.bands[3].bypass = true

        applyEQSettings()
    }

    func applyEQSettings() {
        eqNode.bands[0].gain = Float(lowValue)
        eqNode.bands[1].gain = Float(midValue)
        eqNode.bands[2].gain = Float(highValue)

        // Gain: recupera progressivamente i 12 dB
        // di headroom riservati all'EQ.
        eqNode.globalGain = Float(gainValue) - 12.0
    }

    // MARK: - Filter

    func applyFilter() {
        guard eqNode.bands.count > 3 else { return }

        let filterBand = eqNode.bands[3]
        let val = min(100.0, max(0.0, filterValue))

        if abs(val - 50.0) < 0.5 {
            filterBand.bypass = true
            updateOutputVolume()
            return
        }

        filterBand.bypass = false

        let movement = min(1.0, abs(val - 50.0) / 50.0)
        filterBand.bandwidth = 0.20

        if val < 50.0 {
            filterBand.filterType = .resonantLowPass
            filterBand.frequency = Float(
                18000.0 * pow(20.0 / 18000.0, movement)
            )
        } else {
            filterBand.filterType = .resonantHighPass
            filterBand.frequency = Float(
                40.0 * pow(20000.0 / 40.0, movement)
            )
        }

        updateOutputVolume()
    }

    // MARK: - Audio Loading

    func loadAndPlay(url: URL, loop: Bool = true) {
        loadFile(url: url, loop: loop, autoPlay: true)
    }

    private func ensureEngineReady(_ eng: AVAudioEngine) -> Bool {
        guard player.engine === eng else { return false }

        if !eng.isRunning {
            do {
                eng.prepare()
                try eng.start()
            } catch {
                print("[AUDIO ENGINE ERROR] Impossibile avviare l'engine sul canale \(index + 1): \(error)")
                return false
            }
        } else {
            eng.prepare()
        }

        return eng.isRunning && player.engine === eng
    }

    private func convertBufferToTargetFormat(
        _ sourceBuffer: AVAudioPCMBuffer,
        from sourceFormat: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        let target = Self.targetFormat

        if sourceFormat == target {
            return sourceBuffer
        }

        guard let converter = AVAudioConverter(
            from: sourceFormat,
            to: target
        ) else {
            print("[AUDIO CONVERT ERROR] Impossibile creare AVAudioConverter per CH \(index + 1)")
            return nil
        }

        let ratio = target.sampleRate / sourceFormat.sampleRate

        let outCapacity = AVAudioFrameCount(
            max(
                1.0,
                ceil(Double(sourceBuffer.frameLength) * ratio)
            )
        )

        guard let outBuffer = AVAudioPCMBuffer(
            pcmFormat: target,
            frameCapacity: outCapacity
        ) else {
            return nil
        }

        var error: NSError?
        var provided = false

        let status = converter.convert(
            to: outBuffer,
            error: &error
        ) { _, outStatus in
            if provided {
                outStatus.pointee = .noDataNow
                return nil
            }

            provided = true
            outStatus.pointee = .haveData
            return sourceBuffer
        }

        if status == .error || error != nil {
            print("[AUDIO CONVERT ERROR] CH \(index + 1): \(error?.localizedDescription ?? "errore sconosciuto")")
            return nil
        }

        return outBuffer
    }

    func clearAudio() {
        player.stop()
        currentFile = nil
        stereoBuffer = nil
        pendingResumeFrame = nil
    }

    func loadFile(
        url: URL,
        loop: Bool = true,
        autoPlay: Bool = true
    ) {
        player.stop()
        pendingResumeFrame = nil
        self.isLooping = loop
        self.stereoBuffer = nil

        do {
            let file = try AVAudioFile(forReading: url)
            let frameCount = AVAudioFrameCount(file.length)

            guard frameCount > 0,
                  let rawBuffer = AVAudioPCMBuffer(
                    pcmFormat: file.processingFormat,
                    frameCapacity: frameCount
                  ) else {
                print("[ERRORE AUDIO] Buffer vuoto o non leggibile per \(url.lastPathComponent)")
                return
            }

            try file.read(into: rawBuffer)

            guard let converted = convertBufferToTargetFormat(
                rawBuffer,
                from: file.processingFormat
            ) else {
                return
            }

            self.currentFile = file
            self.stereoBuffer = converted

            schedulePlayback()

            if autoPlay,
               let eng = player.engine,
               ensureEngineReady(eng) {
                player.play()
            }

        } catch {
            print("[ERRORE AUDIO] \(error)")
        }
    }

    // MARK: - Playback Position Preservation

    /// Salva la posizione di tutti i player usando lo stesso riferimento temporale.
    /// Va chiamato prima di fermare l'AVAudioEngine.
    func pauseForGraphRebuild(atHostTime hostTime: UInt64) {
        pendingResumeFrame = nil

        guard let buffer = stereoBuffer,
              buffer.frameLength > 0 else {
            return
        }

        if player.isPlaying {
            let nodeTime = AVAudioTime(hostTime: hostTime)

            if let playerTime = player.playerTime(forNodeTime: nodeTime),
               playerTime.isSampleTimeValid {

                let totalFrames = AVAudioFramePosition(buffer.frameLength)
                let currentFrame = playerTime.sampleTime % totalFrames

                pendingResumeFrame = max(0, currentFrame)
            }
        }

        player.pause()
    }

    /// Prepara il buffer dalla posizione salvata senza avviare il player.
    /// Restituisce true se il canale è pronto per la ripartenza.
    func prepareResumeAfterGraphRebuild() -> Bool {
        guard stereoBuffer != nil,
              let eng = player.engine,
              eng.isRunning,
              let resumeFrame = pendingResumeFrame else {
            return false
        }

        player.stop()

        schedulePlayback(fromFrame: resumeFrame)

        pendingResumeFrame = nil

        print("[AUDIO] CH \(index + 1): preparato dal frame \(resumeFrame)")

        return true
    }

    /// Avvia il player a un istante host condiviso con gli altri canali.
    func resumeAfterGraphRebuild(atHostTime hostTime: UInt64) {
        guard let eng = player.engine,
              eng.isRunning else {
            return
        }

        player.play(at: AVAudioTime(hostTime: hostTime))

        print("[AUDIO] CH \(index + 1): ripartenza sincronizzata")
    }

    /// Crea un buffer circolare che inizia dalla posizione salvata.
    /// In questo modo il loop continua senza ripartire dall'inizio.
    private func makeRotatedBuffer(
        startingAt frame: AVAudioFramePosition
    ) -> AVAudioPCMBuffer? {
        guard let source = stereoBuffer,
              let sourceChannels = source.floatChannelData else {
            return nil
        }

        let totalFrames = Int(source.frameLength)
        guard totalFrames > 0 else { return nil }

        let startFrame = min(
            totalFrames - 1,
            max(0, Int(frame))
        )

        guard let rotated = AVAudioPCMBuffer(
            pcmFormat: source.format,
            frameCapacity: AVAudioFrameCount(totalFrames)
        ),
        let destinationChannels = rotated.floatChannelData else {
            return nil
        }

        let channelCount = Int(source.format.channelCount)
        let firstPartFrames = totalFrames - startFrame
        let secondPartFrames = startFrame

        for channel in 0..<channelCount {
            let sourcePointer = sourceChannels[channel]
            let destinationPointer = destinationChannels[channel]

            // Parte dalla posizione corrente fino alla fine.
            if firstPartFrames > 0 {
                memcpy(
                    destinationPointer,
                    sourcePointer.advanced(by: startFrame),
                    firstPartFrames * MemoryLayout<Float>.size
                )
            }

            // Poi riprende dall'inizio del brano.
            if secondPartFrames > 0 {
                memcpy(
                    destinationPointer.advanced(by: firstPartFrames),
                    sourcePointer,
                    secondPartFrames * MemoryLayout<Float>.size
                )
            }
        }

        rotated.frameLength = AVAudioFrameCount(totalFrames)
        return rotated
    }

    // MARK: - Playback
    // Prepara il player senza avviarlo.
    func prepareForSynchronizedStart() -> Bool {
        guard stereoBuffer != nil,
            let eng = player.engine,
            eng.isRunning else {
            return false
        }

        player.stop()
        schedulePlayback()

        return true
    }

    // Avvia il player usando il riferimento temporale condiviso.
    func startAtHostTime(_ hostTime: UInt64) {
        guard let eng = player.engine,
            eng.isRunning else {
            return
        }

        player.play(at: AVAudioTime(hostTime: hostTime))
    }

    func restart() {
        guard stereoBuffer != nil else {
            print("[AUDIO SKIP] CH \(index + 1): nessun buffer.")
            return
        }

        guard let eng = player.engine, eng.isRunning else {
            print("[AUDIO ERROR] CH \(index + 1): engine non pronto.")
            return
        }

        let playerToEQ = eng.outputConnectionPoints(
            for: player,
            outputBus: 0
        ).contains { $0.node === eqNode }

        let eqToMute = eng.outputConnectionPoints(
            for: eqNode,
            outputBus: 0
        ).contains { $0.node === muteGateMixer }

        print("""
        [AUDIO DEBUG] CH \(index + 1)
          Engine running: \(eng.isRunning)
          Player attached: \(player.engine === eng)
          EQ attached: \(eqNode.engine === eng)
          Mute attached: \(muteGateMixer.engine === eng)
          Send attached: \(sendVolumeNode.engine === eng)
          Player -> EQ: \(playerToEQ)
          EQ -> Mute: \(eqToMute)
        """)

        guard playerToEQ && eqToMute else {
            print("[AUDIO ERROR] CH \(index + 1): routing iniziale non valido.")
            return
        }

        player.stop()

        print("[AUDIO DEBUG] CH \(index + 1): scheduling...")
        schedulePlayback()

        print("[AUDIO DEBUG] CH \(index + 1): buffer rischedulato.")
        print("[AUDIO DEBUG] CH \(index + 1): play...")

        player.play()

        print("[AUDIO DEBUG] CH \(index + 1): play completato.")
    }

    private func schedulePlayback(fromFrame frame: AVAudioFramePosition? = nil) {
        guard let buffer = stereoBuffer else { return }

        let options: AVAudioPlayerNodeBufferOptions =
            isLooping ? .loops : []

        if let frame = frame, frame > 0,
           let rotatedBuffer = makeRotatedBuffer(startingAt: frame) {
            player.scheduleBuffer(
                rotatedBuffer,
                at: nil,
                options: options,
                completionHandler: nil
            )
        } else {
            player.scheduleBuffer(
                buffer,
                at: nil,
                options: options,
                completionHandler: nil
            )
        }
    }
}