import Foundation

/// Turns the runner's JSON UI tree into a short, indented outline an agent can read:
///
///     application "VOFocus Demo"
///       staticText "Sign Up" [16,78,96,42]
///       button "Submit" #submit [16,186,54,24]
///
/// Containers with no identifier, label or value are left out and their children
/// moved up, which removes most of the noise.
public enum TreeFormatter {
    struct Node: Decodable {
        let type: String
        let identifier: String?
        let label: String?
        let value: String?
        let frame: [Double]
        let children: [Node]?
    }

    public static func outline(fromJSON data: Data) throws -> String {
        let root = try JSONDecoder().decode(Node.self, from: data)
        var lines: [String] = []
        append(root, depth: 0, to: &lines)
        return lines.joined(separator: "\n")
    }

    private static func append(_ node: Node, depth: Int, to lines: inout [String]) {
        let isNoise = node.identifier == nil && node.label == nil && node.value == nil
            && ["other", "window", "scrollView"].contains(node.type)
        var childDepth = depth
        if !isNoise {
            var line = String(repeating: "  ", count: depth) + node.type
            if let label = node.label { line += " \"\(label)\"" }
            if let identifier = node.identifier { line += " #\(identifier)" }
            if let value = node.value { line += " = \(value)" }
            line += " [" + node.frame.map { String(Int($0.rounded())) }.joined(separator: ",") + "]"
            lines.append(line)
            childDepth += 1
        }
        for child in node.children ?? [] {
            append(child, depth: childDepth, to: &lines)
        }
    }
}
