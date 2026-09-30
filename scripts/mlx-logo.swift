// Writes Resources/mlx-logo.pdf, the Models table's Standard-row icon, from the MLX logo of ml-explore/mlx (MIT;
// THIRD_PARTY_NOTICES.md names the exact source). Usage:
//   curl -sLO https://raw.githubusercontent.com/ml-explore/mlx/9c3d35571ac450a8ecf5c17b4d0e3fac52c08bc8/docs/logo/mlx_logo_dark.svg
//   xcrun swift scripts/mlx-logo.swift mlx_logo_dark.svg Resources/mlx-logo.pdf
// The dark variant's two fills (white "ML", 57 % grey "X") become black at 100 % and 57 % opacity, so the PDF works as a
// template image: the table tints it with the text colour and the X keeps its lighter weight. The glyph outlines and their
// placement are the SVG's, unchanged.
import CoreGraphics
import Foundation

let args = CommandLine.arguments
guard args.count == 3, let svg = try? String(contentsOfFile: args[1], encoding: .utf8) else {
    FileHandle.standardError.write("usage: mlx-logo.swift mlx_logo_dark.svg out.pdf\n".data(using: .utf8)!); exit(2)
}
func matches(_ pattern: String, _ text: String) -> [[String]] {
    let re = try! NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators])
    return re.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { m in
        (0..<m.numberOfRanges).map { Range(m.range(at: $0), in: text).map { String(text[$0]) } ?? "" }
    }
}
let size = matches(#"viewBox="0 0 ([0-9.]+) ([0-9.]+)""#, svg).first!.dropFirst().map { Double($0)! }
// Glyph id → outline (M/L/Z commands only), and each fill group's glyph uses with their offsets.
var glyphs: [String: String] = [:]
for g in matches(#"<g id="(glyph-[0-9-]+)">\s*<path d="([^"]+)""#, svg) { glyphs[g[1]] = g[2] }
let groups = matches(#"<g fill="rgb\(([0-9.]+)%, [0-9.]+%, [0-9.]+%\)" fill-opacity="1">(.*?)</g>"#, svg)
guard groups.count == 2 else { FileHandle.standardError.write("unexpected SVG structure\n".data(using: .utf8)!); exit(1) }

var box = CGRect(x: 0, y: 0, width: size[0], height: size[1])
let data = NSMutableData()
let context = CGContext(consumer: CGDataConsumer(data: data)!, mediaBox: &box, nil)!
context.beginPDFPage(nil)
// SVG y grows downwards.
context.translateBy(x: 0, y: size[1]); context.scaleBy(x: 1, y: -1)
for group in groups {
    let opacity = Double(group[1])! / 100 // white → 1.0, 57 % grey → 0.57
    context.setFillColor(CGColor(gray: 0, alpha: opacity))
    for use in matches(##"<use xlink:href="#(glyph-[0-9-]+)" x="([0-9.-]+)" y="([0-9.-]+)"/>"##, group[2]) {
        let (dx, dy) = (Double(use[2])!, Double(use[3])!)
        let path = CGMutablePath()
        let tokens = glyphs[use[1]]!.split(separator: " ").map(String.init)
        var i = 0
        while i < tokens.count {
            switch tokens[i] {
            case "M", "L":
                let p = CGPoint(x: Double(tokens[i + 1])! + dx, y: Double(tokens[i + 2])! + dy)
                if tokens[i] == "M" { path.move(to: p) } else { path.addLine(to: p) }
                i += 3
            case "Z": path.closeSubpath(); i += 1
            default: fatalError("unexpected path command \(tokens[i])")
            }
        }
        context.addPath(path)
        context.fillPath()
    }
}
context.endPDFPage()
context.closePDF()
try! (data as Data).write(to: URL(fileURLWithPath: args[2]))
print("wrote \(args[2]) (\(data.length) bytes, \(size[0])×\(size[1]) pt)")
