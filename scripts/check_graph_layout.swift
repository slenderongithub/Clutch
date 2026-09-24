// Self-check for ForceDirectedLayout: no two node footprints may overlap.
// Run: swiftc -O -parse-as-library scripts/check_graph_layout.swift Clutch/ForceDirectedLayout.swift -o /tmp/layoutcheck && /tmp/layoutcheck
import CoreGraphics

struct GraphNode { let id: String; let label: String; let type: String }
struct GraphEdge { let source: String; let target: String; let relationship: String }

func hasOverlap(_ positions: [String: CGPoint], _ footprints: [String: CGSize]) -> Bool {
    let ids = Array(positions.keys)
    for i in ids.indices {
        for j in (i + 1)..<ids.count {
            let a = positions[ids[i]]!, b = positions[ids[j]]!
            let sa = footprints[ids[i]]!, sb = footprints[ids[j]]!
            if abs(a.x - b.x) < (sa.width + sb.width) / 2 - 0.5, abs(a.y - b.y) < (sa.height + sb.height) / 2 - 0.5 {
                return true
            }
        }
    }
    return false
}

@main
enum LayoutCheck {
    static func main() {
        // A dense star-heavy graph: 3 hubs, 80 leaves, long labels — the worst case
        // for the old clamped layout.
        var nodes = (0..<3).map { GraphNode(id: "hub\($0)", label: "Company Hub \($0)", type: "Company") }
        var edges: [GraphEdge] = []
        for i in 0..<80 {
            nodes.append(GraphNode(id: "n\(i)", label: "Very Long Skill Name \(i)", type: "Skill"))
            edges.append(GraphEdge(source: "n\(i)", target: "hub\(i % 3)", relationship: "WORKED_AT"))
        }
        let footprints = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, CGSize(width: CGFloat($0.label.count) * 6.5 + 16, height: 44)) })
        let positions = ForceDirectedLayout.computePositions(nodes: nodes, edges: edges, footprints: footprints)

        precondition(positions.count == nodes.count, "every node gets a position")
        precondition(!hasOverlap(positions, footprints), "node footprints overlap")
        print("graph layout self-check passed (\(nodes.count) nodes, no overlaps)")
    }
}
