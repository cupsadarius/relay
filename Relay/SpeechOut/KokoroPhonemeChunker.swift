import Foundation

/// Pure deterministic segmenter for Kokoro's resolved phoneme stream. It never phonemizes text;
/// callers must pass the full-text frontend result so normalization/G2P happens exactly once.
struct KokoroPhonemeChunker: Sendable {
    let preferredTarget: Int
    let hardMaximum: Int

    init(preferredTarget: Int = 480, hardMaximum: Int = 510) {
        precondition(preferredTarget > 0)
        precondition(hardMaximum >= preferredTarget)
        self.preferredTarget = preferredTarget
        self.hardMaximum = hardMaximum
    }

    func chunks(from phonemes: String) -> [String] {
        let characters = Array(phonemes)
        guard !characters.isEmpty else { return [] }

        var result: [String] = []
        var offset = 0
        while characters.count - offset > hardMaximum {
            let remaining = characters.count - offset
            let target = min(preferredTarget, remaining)
            let maximum = min(hardMaximum, remaining)
            let relativeSplit = bestSplit(
                in: Array(characters[offset..<(offset + maximum)]),
                target: target
            )
            let split = max(1, relativeSplit)
            result.append(String(characters[offset..<(offset + split)]))
            offset += split
        }

        if offset < characters.count {
            result.append(String(characters[offset...]))
        }
        return result
    }

    private func bestSplit(in window: [Character], target: Int) -> Int {
        let targetIndex = min(max(target, 1), window.count)
        let sentence: Set<Character> = [".", "!", "?", "…"]
        let clause: Set<Character> = [";", ":", ",", "—", "–"]

        if let split = findBoundary(in: window, target: targetIndex, matching: { sentence.contains($0) }) {
            return split
        }
        if let split = findBoundary(in: window, target: targetIndex, matching: { clause.contains($0) }) {
            return split
        }
        if let split = findBoundary(in: window, target: targetIndex, matching: { $0.isWhitespace }) {
            return split
        }
        return targetIndex
    }

    private func findBoundary(
        in window: [Character],
        target: Int,
        matching predicate: (Character) -> Bool
    ) -> Int? {
        if target > 0 {
            for index in stride(from: min(target, window.count) - 1, through: 0, by: -1) {
                if predicate(window[index]) { return index + 1 }
            }
        }
        if target < window.count {
            for index in target..<window.count {
                if predicate(window[index]) { return index + 1 }
            }
        }
        return nil
    }
}
