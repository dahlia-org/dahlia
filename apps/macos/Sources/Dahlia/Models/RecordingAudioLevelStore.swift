import Combine

@MainActor
final class RecordingAudioLevelStore: ObservableObject {
    @Published private(set) var levels: [RecordingAudioSource: Double] = [:]

    func level(for source: RecordingAudioSource) -> Double {
        levels[source] ?? 0
    }

    func update(source: RecordingAudioSource, level: Double) {
        let level = min(1, max(0, level))
        if levels[source] != level { levels[source] = level }
    }

    func reset(source: RecordingAudioSource) {
        levels[source] = nil
    }

    func retain(sources: Set<RecordingAudioSource>) {
        levels = levels.filter { sources.contains($0.key) }
    }

    func reset() {
        levels.removeAll()
    }
}
