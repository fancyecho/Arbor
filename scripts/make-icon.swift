// Draws the app icon as an Icon Composer document (Resources/AppIcon.icon), then renders from it the
// flat Resources/AppIcon.icns (for macOS 14–25 and builds without Xcode) and Resources/AppIcon-preview.png.
// Usage: swift scripts/make-icon.swift <project root> [folder for a strip of the small sizes]
// Needs Xcode (for Icon Composer's ictool). build-app.sh compiles the document with actool.
//
// The idea: a glass folder with an olive sprig pressed into its front, on the dusk indigo of Arbor's
// default workspace. One object, the "arbor" as an emblem on it. Flat, frontal shapes; the system's
// Liquid Glass adds the depth, highlights and shadows, and the dark, clear and tinted looks.
import Foundation

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let document = root.appendingPathComponent("Resources/AppIcon.icon")

func n(_ value: Double) -> String { String(format: "%.1f", value) }

// MARK: Folder (1024 canvas, y down)

let folderBack = """
    <path d="M 196 342 Q 196 300 238 300 L 404 300 Q 434 300 452 322 L 478 352 L 786 352 \
    Q 828 352 828 394 L 828 778 Q 828 820 786 820 L 238 820 Q 196 820 196 778 Z" fill="url(#g)"/>
    """
let folderFront = #"<rect x="176" y="430" width="672" height="410" rx="54" fill="url(#g)"/>"#

// MARK: Sprig, centered on the folder front. MenuBarIcon.swift draws the same sprig for the menu bar.

typealias Point = (x: Double, y: Double)
let stem: [Point] = [(408, 763), (456, 685), (518, 601), (616, 523)]

/// A point on the stem and the direction it grows there (0° is straight up, positive leans right).
func onStem(_ t: Double) -> (Point, Double) {
    let (p0, p1, p2, p3) = (stem[0], stem[1], stem[2], stem[3])
    let u = 1 - t
    let x = u * u * u * p0.x + 3 * u * u * t * p1.x + 3 * u * t * t * p2.x + t * t * t * p3.x
    let y = u * u * u * p0.y + 3 * u * u * t * p1.y + 3 * u * t * t * p2.y + t * t * t * p3.y
    let dx = 3 * u * u * (p1.x - p0.x) + 6 * u * t * (p2.x - p1.x) + 3 * t * t * (p3.x - p2.x)
    let dy = 3 * u * u * (p1.y - p0.y) + 6 * u * t * (p2.y - p1.y) + 3 * t * t * (p3.y - p2.y)
    return ((x, y), atan2(dx, -dy) * 180 / .pi)
}

/// An olive leaf from `base` along `heading`: fullest near the stem, tapering to a soft tip.
func leaf(at base: Point, heading: Double, length l: Double, width w: Double) -> String {
    let d = "M 0,0 C \(n(w)),\(n(-l * 0.18)) \(n(w * 0.85)),\(n(-l * 0.82)) 0,\(n(-l)) "
        + "C \(n(-w * 0.85)),\(n(-l * 0.82)) \(n(-w)),\(n(-l * 0.18)) 0,0 Z"
    return "<g transform=\"translate(\(n(base.x)) \(n(base.y))) rotate(\(n(heading)))\">"
        + "<path d=\"\(d)\" fill=\"url(#g)\" stroke=\"url(#g)\" stroke-width=\"14\" stroke-linejoin=\"round\"/></g>"
}

var sprig = "<path d=\"M \(n(stem[0].x)),\(n(stem[0].y)) C \(n(stem[1].x)),\(n(stem[1].y)) "
    + "\(n(stem[2].x)),\(n(stem[2].y)) \(n(stem[3].x)),\(n(stem[3].y))\" fill=\"none\" stroke=\"url(#g)\" "
    + "stroke-width=\"16\" stroke-linecap=\"round\"/>"
// Leaves alternate sides at the same angle, each a little smaller than the one below; one more at the tip.
for (index, t) in [0.16, 0.34, 0.52, 0.70].enumerated() {
    let (point, heading) = onStem(t)
    let scale = 1 - Double(index) * 0.08
    sprig += leaf(at: point, heading: heading + (index % 2 == 0 ? -46 : 46), length: 104 * scale, width: 38 * scale)
}
let (tip, tipHeading) = onStem(1)
sprig += leaf(at: tip, heading: tipHeading + 4, length: 82, width: 30)

func svg(_ body: String, top light: String, bottom deep: String) -> String {
    """
    <svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">\
    <defs><linearGradient id="g" x1="0" y1="0" x2="0" y2="1">\
    <stop offset="0" stop-color="\(light)"/><stop offset="1" stop-color="\(deep)"/></linearGradient></defs>\
    \(body)</svg>
    """
}

let assets = [
    "back.svg": svg(folderBack, top: "#B9C0FF", bottom: "#8E97F0"),
    "front.svg": svg(folderFront, top: "#FFFFFF", bottom: "#E4E8FF"),
    "sprig.svg": svg(sprig, top: "#7279FF", bottom: "#3A3BC0"),
]

// MARK: Document

func group(_ file: String, translucency: Double, shadow: Double, darkFill: String? = nil) -> [String: Any] {
    var layer: [String: Any] = ["glass": true, "image-name": file, "name": String(file.dropLast(4))]
    if let darkFill {
        layer["fill-specializations"] = [["appearance": "dark", "value": ["solid": darkFill]]]
    }
    return ["layers": [layer], "lighting": "individual", "specular": true,
            "shadow": ["kind": "layer-color", "opacity": shadow],
            "translucency": ["enabled": translucency > 0, "value": translucency]]
}

let icon: [String: Any] = [
    // Dusk indigo: the app's default workspace color, deepened toward the bottom.
    "fill": ["linear-gradient": ["display-p3:0.290,0.330,0.840,1.000", "display-p3:0.100,0.080,0.330,1.000"]],
    // Front to back: the sprig pressed into the folder front, the front, the back with its tab.
    "groups": [
        group("sprig.svg", translucency: 0, shadow: 0.35),
        // On the dark background the white front would pick up the background's indigo.
        group("front.svg", translucency: 0.3, shadow: 0.5, darkFill: "display-p3:0.930,0.945,1.000,1.000"),
        group("back.svg", translucency: 0.4, shadow: 0.5),
    ],
    "supported-platforms": ["circles": ["watchOS"], "squares": "shared"],
]

let fm = FileManager.default
try? fm.removeItem(at: document)
try! fm.createDirectory(at: document.appendingPathComponent("Assets"), withIntermediateDirectories: true)
for (name, content) in assets {
    try! content.write(to: document.appendingPathComponent("Assets/\(name)"), atomically: true, encoding: .utf8)
}
let json = try! JSONSerialization.data(withJSONObject: icon, options: [.prettyPrinted, .sortedKeys])
try! json.write(to: document.appendingPathComponent("icon.json"))

// MARK: Renders

@discardableResult
func run(_ tool: String, _ arguments: [String]) -> String {
    let pipe = Pipe()
    let task = Process()
    task.executableURL = URL(fileURLWithPath: tool)
    task.arguments = arguments
    task.standardOutput = pipe
    try! task.run()
    let output = pipe.fileHandleForReading.readDataToEndOfFile()
    task.waitUntilExit()
    precondition(task.terminationStatus == 0, "\(tool) failed")
    return String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
}

let ictool = run("/usr/bin/xcode-select", ["-p"]) + "/../Applications/Icon Composer.app/Contents/Executables/ictool"
func render(points: Int, scale: Int, to output: URL) {
    run(ictool, [document.path, "--export-image", "--output-file", output.path, "--platform", "macOS",
                 "--rendition", "Default", "--width", "\(points)", "--height", "\(points)", "--scale", "\(scale)"])
}

let iconset = fm.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? fm.removeItem(at: iconset)
try! fm.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    render(points: base, scale: 1, to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    render(points: base, scale: 2, to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
run("/usr/bin/iconutil", ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("Resources/AppIcon.icns").path])
let preview = root.appendingPathComponent("Resources/AppIcon-preview.png")
try? fm.removeItem(at: preview)
try! fm.copyItem(at: iconset.appendingPathComponent("icon_512x512@2x.png"), to: preview)
// A strip of the small sizes, to check the icon still reads in the Dock and in Finder lists.
if CommandLine.arguments.count > 2 {
    try? fm.removeItem(atPath: CommandLine.arguments[2])
    try? fm.copyItem(at: iconset, to: URL(fileURLWithPath: CommandLine.arguments[2]))
}
print("wrote \(document.path), AppIcon.icns and AppIcon-preview.png")
