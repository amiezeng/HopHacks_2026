import CoreGraphics
import Foundation

struct TextReading {
    let text: String
    let midY: CGFloat // Vision coordinates: larger is higher up
    let minX: CGFloat
}

/// Merges the last few OCR scans into one clean list of lines. The same printed text is read slightly
/// differently from scan to scan ("BYE", "6YE", "BYE!"), so lines are grouped, voted on, and only kept
/// if they keep showing up.
struct TextConsolidator {
    var windowSize = 8
    var minAppearances = 3
    var maxLines = 30
    var maxCharacters = 800

    private struct Reading {
        let text: String
        let key: String
        let midY: CGFloat
        let minX: CGFloat
    }

    private struct Cluster {
        let anchor: String
        var members: [Reading]
        var scans: Set<Int>
    }

    private var window: [[Reading]] = []

    mutating func add(_ readings: [TextReading]) {
        window.append(readings.compactMap { reading in
            let key = Self.normalize(reading.text)
            return key.isEmpty ? nil : Reading(text: reading.text, key: key, midY: reading.midY, minX: reading.minX)
        })
        if window.count > windowSize { window.removeFirst(window.count - windowSize) }
    }

    mutating func reset() {
        window.removeAll()
    }

    func consolidated() -> [String] {
        var clusters: [Cluster] = []
        for (scan, readings) in window.enumerated() {
            for reading in readings {
                if let i = clusters.firstIndex(where: { Self.similar($0.anchor, reading.key) }) {
                    clusters[i].members.append(reading)
                    clusters[i].scans.insert(scan)
                } else {
                    clusters.append(Cluster(anchor: reading.key, members: [reading], scans: [scan]))
                }
            }
        }

        struct Line {
            let text: String
            let y: CGFloat
            let x: CGFloat
            let scans: Int
        }

        let lines = clusters.filter { $0.scans.count >= minAppearances }.map { cluster -> Line in
            // The version read most often wins; on a tie, the longer (more complete) one.
            let counts = Dictionary(grouping: cluster.members, by: \.text).mapValues(\.count)
            let best = counts.max { lhs, rhs in
                (lhs.value, lhs.key.count, lhs.key) < (rhs.value, rhs.key.count, rhs.key)
            }!.key
            let n = CGFloat(cluster.members.count)
            return Line(
                text: best,
                y: cluster.members.reduce(0) { $0 + $1.midY } / n,
                x: cluster.members.reduce(0) { $0 + $1.minX } / n,
                scans: cluster.scans.count
            )
        }

        // If there is too much, keep the lines seen most consistently.
        var budget = maxCharacters
        var chosen: [Line] = []
        for line in lines.sorted(by: { $0.scans > $1.scans }) where chosen.count < maxLines {
            guard line.text.count <= budget else { continue }
            budget -= line.text.count
            chosen.append(line)
        }

        // Reading order: top to bottom, then left to right. Rows are bucketed so slight height jitter
        // doesn't shuffle lines that sit on the same row.
        return chosen
            .sorted { (-($0.y * 50).rounded(), $0.x) < (-($1.y * 50).rounded(), $1.x) }
            .map(\.text)
    }

    private static func normalize(_ text: String) -> String {
        let allowed = CharacterSet.letters.union(.decimalDigits)
        return text.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .components(separatedBy: allowed.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func similar(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        // Two different numbers ("b6" and "b12") must never be merged as one misread.
        if a.contains(where: \.isNumber) && b.contains(where: \.isNumber) { return false }

        let (short, long) = a.count <= b.count ? (a, b) : (b, a)
        if short.count >= 4, long.contains(short) { return true } // a partial read of a longer line

        let tolerance = long.count > 8 ? 2 : 1
        guard short.count >= 3, long.count - short.count <= tolerance else { return false }
        return editDistance(Array(a), Array(b)) <= tolerance
    }

    private static func editDistance(_ a: [Character], _ b: [Character]) -> Int {
        var previous = Array(0...b.count)
        for i in 1...a.count {
            var current = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            previous = current
        }
        return previous[b.count]
    }
}
