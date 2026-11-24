import Foundation

public struct GraphPoint: Hashable, Sendable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
}

/// Force-directed placement for the document "universe": linked documents pull together, all push apart a little.
/// Deterministic (start points come from the ids), so the map looks the same every time it opens.
public enum GraphLayout {
    public static func layout(nodes: [String], links: [(String, String)], groups: [String: String] = [:],
                              size: Double = 1000, iterations: Int = 300) -> [String: GraphPoint] {
        guard !nodes.isEmpty else { return [:] }
        let index = Dictionary(uniqueKeysWithValues: nodes.enumerated().map { ($1, $0) })
        let edges = links.compactMap { a, b -> (Int, Int)? in
            guard let i = index[a], let j = index[b], i != j else { return nil }
            return (i, j)
        }
        // Each group starts in its own sector so groups read as clusters.
        let groupNames = Array(Set(groups.values)).sorted()
        var xs = [Double](repeating: 0, count: nodes.count)
        var ys = [Double](repeating: 0, count: nodes.count)
        for (i, id) in nodes.enumerated() {
            let h = stableHash(id)
            var angle = Double(h % 3600) / 3600 * 2 * .pi
            if let g = groups[id], let gi = groupNames.firstIndex(of: g), groupNames.count > 1 {
                let sector = 2 * .pi / Double(groupNames.count)
                angle = Double(gi) * sector + (Double(h % 1000) / 1000) * sector * 0.8
            }
            let radius = size * (0.15 + Double((h / 3600) % 1000) / 1000 * 0.3)
            xs[i] = cos(angle) * radius
            ys[i] = sin(angle) * radius
        }
        let k = size / sqrt(Double(nodes.count)) * 0.9
        var temperature = size / 10
        for _ in 0..<iterations {
            var dx = [Double](repeating: 0, count: nodes.count)
            var dy = [Double](repeating: 0, count: nodes.count)
            for i in 0..<nodes.count {
                for j in (i + 1)..<nodes.count {
                    var ddx = xs[i] - xs[j], ddy = ys[i] - ys[j]
                    var dist = sqrt(ddx * ddx + ddy * ddy)
                    if dist < 0.01 { ddx = 0.01; ddy = 0; dist = 0.01 }
                    let force = k * k / dist
                    dx[i] += ddx / dist * force; dy[i] += ddy / dist * force
                    dx[j] -= ddx / dist * force; dy[j] -= ddy / dist * force
                }
            }
            for (i, j) in edges {
                let ddx = xs[i] - xs[j], ddy = ys[i] - ys[j]
                let dist = max(sqrt(ddx * ddx + ddy * ddy), 0.01)
                let force = dist * dist / k
                dx[i] -= ddx / dist * force; dy[i] -= ddy / dist * force
                dx[j] += ddx / dist * force; dy[j] += ddy / dist * force
            }
            for i in 0..<nodes.count {
                // A soft pull to the middle keeps lonely documents from drifting away.
                dx[i] -= xs[i] * 0.02; dy[i] -= ys[i] * 0.02
                let len = max(sqrt(dx[i] * dx[i] + dy[i] * dy[i]), 0.01)
                xs[i] += dx[i] / len * min(len, temperature)
                ys[i] += dy[i] / len * min(len, temperature)
            }
            temperature = max(temperature * 0.97, 0.5)
        }
        // Fit each axis into [-size/2, size/2] so the map fills the screen.
        let scaleX = (size / 2) / max(xs.map(abs).max() ?? 1, 1)
        let scaleY = (size / 2) / max(ys.map(abs).max() ?? 1, 1)
        var result: [String: GraphPoint] = [:]
        for (i, id) in nodes.enumerated() { result[id] = GraphPoint(x: xs[i] * scaleX, y: ys[i] * scaleY) }
        return result
    }

    /// FNV-1a; `hashValue` changes between launches.
    static func stableHash(_ text: String) -> Int {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        return Int(hash % UInt64(Int32.max))
    }
}

public struct GraphPoint3: Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var z: Double
    public init(x: Double, y: Double, z: Double) { self.x = x; self.y = y; self.z = z }
}

extension GraphLayout {
    /// The same force layout in three dimensions, for the 3D document universe. Groups start in their own region
    /// (spread over a sphere) so companies read as clusters. Result fits in a sphere of radius `size / 2`.
    public static func layout3D(nodes: [String], links: [(String, String)], groups: [String: String] = [:],
                                size: Double = 1000, iterations: Int = 260) -> [String: GraphPoint3] {
        guard !nodes.isEmpty else { return [:] }
        let index = Dictionary(uniqueKeysWithValues: nodes.enumerated().map { ($1, $0) })
        let edges = links.compactMap { a, b -> (Int, Int)? in
            guard let i = index[a], let j = index[b], i != j else { return nil }
            return (i, j)
        }
        let groupNames = Array(Set(groups.values)).sorted()
        var p = [[Double]](repeating: [0, 0, 0], count: nodes.count)
        for (i, id) in nodes.enumerated() {
            let h = stableHash(id)
            var theta = Double(h % 3600) / 3600 * 2 * .pi
            var phi = acos(1 - 2 * Double((h / 3600) % 1000) / 1000)
            if let g = groups[id], let gi = groupNames.firstIndex(of: g), groupNames.count > 1 {
                // Fibonacci-sphere centre per group, jittered.
                let k = Double(gi) + 0.5
                phi = acos(1 - 2 * k / Double(groupNames.count)) + (Double(h % 100) / 100 - 0.5) * 0.6
                theta = Double(gi) * .pi * (3 - sqrt(5)) + (Double((h / 100) % 100) / 100 - 0.5) * 0.9
            }
            let r = size * (0.25 + Double((h / 7) % 100) / 100 * 0.2)
            p[i] = [r * sin(phi) * cos(theta), r * sin(phi) * sin(theta), r * cos(phi)]
        }
        let k = size / cbrt(Double(nodes.count)) * 0.55
        var temperature = size / 10
        for _ in 0..<iterations {
            var d = [[Double]](repeating: [0, 0, 0], count: nodes.count)
            for i in 0..<nodes.count {
                for j in (i + 1)..<nodes.count {
                    var v = [p[i][0] - p[j][0], p[i][1] - p[j][1], p[i][2] - p[j][2]]
                    var dist = sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2])
                    if dist < 0.01 { v = [0.01, 0, 0]; dist = 0.01 }
                    let f = k * k / dist
                    for a in 0..<3 { d[i][a] += v[a] / dist * f; d[j][a] -= v[a] / dist * f }
                }
            }
            for (i, j) in edges {
                let v = [p[i][0] - p[j][0], p[i][1] - p[j][1], p[i][2] - p[j][2]]
                let dist = max(sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]), 0.01)
                let f = dist * dist / k
                for a in 0..<3 { d[i][a] -= v[a] / dist * f; d[j][a] += v[a] / dist * f }
            }
            for i in 0..<nodes.count {
                for a in 0..<3 { d[i][a] -= p[i][a] * 0.03 }
                let len = max(sqrt(d[i][0] * d[i][0] + d[i][1] * d[i][1] + d[i][2] * d[i][2]), 0.01)
                for a in 0..<3 { p[i][a] += d[i][a] / len * min(len, temperature) }
            }
            temperature = max(temperature * 0.97, 0.5)
        }
        // Centre and fit.
        var c = [0.0, 0.0, 0.0]
        for q in p { for a in 0..<3 { c[a] += q[a] / Double(nodes.count) } }
        // Each axis is stretched to fill the space (a long chain of documents would otherwise be a thin line),
        // then the whole cloud is pulled inside the sphere.
        var q = p.map { [$0[0] - c[0], $0[1] - c[1], $0[2] - c[2]] }
        for a in 0..<3 {
            let extent = max(q.map { abs($0[a]) }.max() ?? 1, 1)
            for i in q.indices { q[i][a] = q[i][a] / extent * (size / 2) }
        }
        let radius = max(q.map { sqrt($0[0] * $0[0] + $0[1] * $0[1] + $0[2] * $0[2]) }.max() ?? 1, 1)
        let s = (size / 2) / radius
        var out: [String: GraphPoint3] = [:]
        for (i, id) in nodes.enumerated() { out[id] = GraphPoint3(x: q[i][0] * s, y: q[i][1] * s, z: q[i][2] * s) }
        return out
    }
}
