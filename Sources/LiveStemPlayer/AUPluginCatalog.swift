
import Foundation
import Combine
import AVFoundation
import AudioToolbox

final class AUPluginCatalog: ObservableObject {

    static let shared = AUPluginCatalog()

    @Published private(set) var components: [AVAudioUnitComponent] = []
    @Published private(set) var isScanning = false

    private init() {}

    func refresh() {
        guard !isScanning else { return }

        isScanning = true

        DispatchQueue.global(qos: .userInitiated).async {
            let description = AudioComponentDescription(
                componentType: kAudioUnitType_Effect,
                componentSubType: 0,
                componentManufacturer: 0,
                componentFlags: 0,
                componentFlagsMask: 0
            )

            let foundComponents =
                AVAudioUnitComponentManager.shared()
                    .components(matching: description)
                    .sorted {
                        if $0.manufacturerName == $1.manufacturerName {
                            return $0.name.localizedCaseInsensitiveCompare(
                                $1.name
                            ) == .orderedAscending
                        }

                        return $0.manufacturerName.localizedCaseInsensitiveCompare(
                            $1.manufacturerName
                        ) == .orderedAscending
                    }

            DispatchQueue.main.async {
                self.components = foundComponents
                self.isScanning = false
            }
        }
    }
}
