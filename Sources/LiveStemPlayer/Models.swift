import Foundation

struct ChannelEQSettings: Codable {
    var gainDB: Float = 0.0
    var lowGainDB: Float = 0.0
    var midGainDB: Float = 0.0
    var highGainDB: Float = 0.0
}

struct StemPackMetadata: Codable {
    var packName: String
    var bpm: Double
    var channelSettings: [ChannelEQSettings]
}

struct StemPackItem: Identifiable {
    let id = UUID()
    let folderURL: URL
    var metadata: StemPackMetadata
}