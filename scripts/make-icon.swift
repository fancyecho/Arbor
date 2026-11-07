// Draws the app icon as an Icon Composer document (Resources/AppIcon.icon), then renders from it the
// flat Resources/AppIcon.icns (for macOS 14–25 and builds without Xcode) and Resources/AppIcon-preview.png.
// Usage: swift scripts/make-icon.swift <project root> [folder for a strip of the small sizes]
// Needs Xcode (for Icon Composer's ictool). build-app.sh compiles the document with actool.
//
// The idea: one bold indigo folder on a light background, with three sheets in Arbor's workspace colors
// (coral, amber, teal) peeking over its front. Flat, frontal shapes; the system's Liquid Glass adds the
// depth, highlights and shadows, and the dark, clear and tinted looks.
import Foundation

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let document = root.appendingPathComponent("Resources/AppIcon.icon")

// MARK: Shapes (1024 canvas, y down). MenuBarIcon.swift draws the same folder for the menu bar.

// The folder is 724 wide, about 1.25:1, its tab a third of the width, centered a touch low.
let left = 150, right = 874
let back = """
    <path d="M \(left) 286 Q \(left) 210 226 210 L 366 210 Q 402 210 424 238 L 444 262 Q 456 276 476 276 \
    L \(right - 70) 276 Q \(right) 276 \(right) 346 L \(right) 742 Q \(right) 812 \(right - 70) 812 \
    L 220 812 Q \(left) 812 \(left) 742 Z" fill="url(#g)"/>
    """
let front = "<rect x=\"\(left)\" y=\"334\" width=\"\(right - left)\" height=\"484\" rx=\"76\" fill=\"url(#g)\"/>"

/// A sheet tucked into the folder; only its top shows above the front.
func sheet(from x0: Double, to x1: Double, top: Double, angle: Double, fill: String) -> String {
    "<g transform=\"rotate(\(angle) \((x0 + x1) / 2) 600)\"><rect x=\"\(x0)\" y=\"\(top)\" width=\"\(x1 - x0)\" "
        + "height=\"400\" rx=\"34\" fill=\"url(#\(fill))\"/></g>"
}
let sheets = sheet(from: 222, to: 560, top: 266, angle: -5, fill: "coral")
    + sheet(from: 400, to: 700, top: 250, angle: 1, fill: "amber")
    + sheet(from: 560, to: 812, top: 272, angle: 6, fill: "teal")

func gradient(_ id: String, _ top: String, _ bottom: String) -> String {
    "<linearGradient id=\"\(id)\" x1=\"0\" y1=\"0\" x2=\"0\" y2=\"1\">"
        + "<stop offset=\"0\" stop-color=\"\(top)\"/><stop offset=\"1\" stop-color=\"\(bottom)\"/></linearGradient>"
}

func svg(_ body: String, _ defs: String) -> String {
    "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"1024\" height=\"1024\" viewBox=\"0 0 1024 1024\">"
        + "<defs>\(defs)</defs>\(body)</svg>"
}

let assets = [
    "back.svg": svg(back, gradient("g", "#5A63F2", "#3E40C9")),
    "sheets.svg": svg(sheets, gradient("coral", "#FF9A7A", "#F2734F") + gradient("amber", "#FFD36B", "#F5B23A")
                          + gradient("teal", "#6FE0C8", "#2FB79E")),
    "front.svg": svg(front, gradient("g", "#939BFF", "#5A61F0")),
]

// MARK: Document

func group(_ file: String, translucency: Double, shadow: Double) -> [String: Any] {
    ["layers": [["glass": true, "image-name": file, "name": String(file.dropLast(4))]],
     "lighting": "individual", "specular": true,
     "shadow": ["kind": "layer-color", "opacity": shadow],
     "translucency": ["enabled": translucency > 0, "value": translucency]]
}

let icon: [String: Any] = [
    // A light, cool background, so the color stays on the folder.
    "fill": ["linear-gradient": ["display-p3:0.985,0.988,1.000,1.000", "display-p3:0.900,0.910,0.945,1.000"]],
    // Front to back: the front (frosted just enough to glow, not to show the sheets through), the sheets, the back.
    "groups": [
        group("front.svg", translucency: 0.12, shadow: 0.5),
        group("sheets.svg", translucency: 0, shadow: 0.3),
        group("back.svg", translucency: 0, shadow: 0.5),
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
