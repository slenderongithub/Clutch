import CoreGraphics
import Foundation

/// Fruchterman-Reingold force layout followed by a collision pass.
///
/// Two deliberate choices keep nodes from overlapping at any zoom level:
/// 1. No clamping to a fixed canvas. Clamping piled repelled nodes onto the
///    same border coordinates, and since zoom scales positions uniformly,
///    stacked nodes stayed stacked however far you zoomed in. A weak pull
///    toward the center keeps the graph compact instead.
/// 2. After the simulation, every node's footprint (dot + label, measured by
///    the caller) is pushed apart until no two footprints intersect. The
///    view scales labels with zoom, so "no overlap at scale 1" means no
///    overlap at every scale.
///
/// ponytail: O(n²) per iteration is fine for the tens-to-low-hundreds of
/// nodes a career graph has; add a spatial grid if it ever needs thousands.
enum ForceDirectedLayout {
    static func computePositions(
        nodes: [GraphNode],
        edges: [GraphEdge],
        footprints: [String: CGSize],
        iterations: Int = 400
    ) -> [String: CGPoint] {
        guard !nodes.isEmpty else { return [:] }

        let ids = nodes.map(\.id)
        let indexOf = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, $0) })
        let links = edges.compactMap { edge -> (Int, Int)? in
            guard let a = indexOf[edge.source], let b = indexOf[edge.target], a != b else { return nil }
            return (a, b)
        }

        // Ideal spacing grows with the average footprint so long labels get room.
        let averageWidth = footprints.values.map(\.width).reduce(0, +) / CGFloat(max(footprints.count, 1))
        let k = max(averageWidth, 60) * 1.1

        // Deterministic golden-angle spiral start: stable layouts across
        // refreshes, and no two nodes ever start at the same point.
        var positions = ids.indices.map { index -> CGPoint in
            let radius = k * 0.6 * sqrt(CGFloat(index) + 0.5)
            let angle = CGFloat(index) * 2.399963
            return CGPoint(x: radius * cos(angle), y: radius * sin(angle))
        }

        var temperature = k * 2
        for _ in 0..<iterations {
            var displacement = [CGPoint](repeating: .zero, count: ids.count)

            for i in ids.indices {
                for j in (i + 1)..<ids.count {
                    var dx = positions[i].x - positions[j].x
                    var dy = positions[i].y - positions[j].y
                    if dx == 0, dy == 0 { dx = 0.1; dy = 0.1 }
                    let distance = max(sqrt(dx * dx + dy * dy), 0.01)
                    let force = k * k / distance
                    let fx = dx / distance * force
                    let fy = dy / distance * force
                    displacement[i].x += fx; displacement[i].y += fy
                    displacement[j].x -= fx; displacement[j].y -= fy
                }
            }

            for (a, b) in links {
                let dx = positions[a].x - positions[b].x
                let dy = positions[a].y - positions[b].y
                let distance = max(sqrt(dx * dx + dy * dy), 0.01)
                let force = distance * distance / k
                let fx = dx / distance * force
                let fy = dy / distance * force
                displacement[a].x -= fx; displacement[a].y -= fy
                displacement[b].x += fx; displacement[b].y += fy
            }

            for i in ids.indices {
                // Center gravity keeps disconnected components (common in resumes:
                // separate projects share no skills) from drifting far apart.
                displacement[i].x -= positions[i].x * 0.35
                displacement[i].y -= positions[i].y * 0.35

                let length = max(sqrt(displacement[i].x * displacement[i].x + displacement[i].y * displacement[i].y), 0.01)
                let step = min(length, temperature)
                positions[i].x += displacement[i].x / length * step
                positions[i].y += displacement[i].y / length * step
            }
            temperature = max(temperature * 0.985, 1)
        }

        resolveCollisions(&positions, sizes: ids.map { footprints[$0] ?? CGSize(width: 60, height: 40) })
        return Dictionary(uniqueKeysWithValues: zip(ids, positions))
    }

    /// Pushes intersecting footprints apart along the axis of least overlap
    /// until none intersect (or the pass budget runs out).
    static func resolveCollisions(_ positions: inout [CGPoint], sizes: [CGSize], gap: CGFloat = 8, maxPasses: Int = 300) {
        for _ in 0..<maxPasses {
            var moved = false
            for i in positions.indices {
                for j in (i + 1)..<positions.count {
                    let overlapX = (sizes[i].width + sizes[j].width) / 2 + gap - abs(positions[i].x - positions[j].x)
                    let overlapY = (sizes[i].height + sizes[j].height) / 2 + gap - abs(positions[i].y - positions[j].y)
                    guard overlapX > 0, overlapY > 0 else { continue }
                    moved = true
                    if overlapX < overlapY {
                        let push = overlapX / 2 * (positions[i].x < positions[j].x ? -1 : 1)
                        positions[i].x += push
                        positions[j].x -= push
                    } else {
                        let push = overlapY / 2 * (positions[i].y < positions[j].y ? -1 : 1)
                        positions[i].y += push
                        positions[j].y -= push
                    }
                }
            }
            if !moved { return }
        }
    }

}
