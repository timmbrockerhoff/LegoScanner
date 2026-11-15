// Selbsttest der Farbwahl. Ausführen:
// mkdir -p /tmp/cc && cp tools/check_colors.swift /tmp/cc/main.swift && swiftc -o /tmp/cc/check /tmp/cc/main.swift LegoScanner/Rebrickable.swift && /tmp/cc/check
func c(_ n: String, _ r: Double, _ g: Double, _ b: Double, _ sets: Int) -> LegoColor {
    LegoColor(id: 0, name: n, rgb: SIMD3(r, g, b), isTrans: false, bricklinkID: nil, sets: sets)
}
// echte Häufigkeiten für Teil 3795 (Auszug)
let plate = [c("Black", 5, 19, 29, 900), c("Dark Bluish Gray", 108, 110, 104, 800), c("White", 255, 255, 255, 700),
             c("Light Bluish Gray", 160, 165, 169, 650), c("Yellow", 242, 205, 55, 533),
             c("Bright Light Orange", 248, 187, 61, 60), c("Vibrant Yellow", 235, 216, 0, 12)]
assert(plate.best(for: SIMD3(238, 221, 3))?.name == "Yellow")          // übersättigtes Kamerafoto
assert(plate.best(for: SIMD3(108, 110, 104))?.name == "Dark Bluish Gray") // selten genug, trotzdem klar
assert(plate.best(for: SIMD3(150, 158, 165))?.name == "Light Bluish Gray")
assert(plate.best(for: SIMD3(240, 240, 235))?.name == "White")
assert(plate.best(for: SIMD3(30, 30, 35))?.name == "Black")
// Farbmessung: gelbe Platte schräg auf Holztisch. Der Rahmen um das Teil enthält dann viel Tisch.
import CoreGraphics
import simd
func scene(part: SIMD3<Double>, table: SIMD3<Double>) -> CGImage {
    let size = 300
    let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(red: table.x / 255, green: table.y / 255, blue: table.z / 255, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: size, height: size))
    context.translateBy(x: 150, y: 150)
    context.rotate(by: .pi / 5)
    context.setFillColor(red: part.x / 255, green: part.y / 255, blue: part.z / 255, alpha: 1)
    context.fill(CGRect(x: -110, y: -22, width: 220, height: 44)) // lange, schmale Platte, ~36° gedreht
    return context.makeImage()!
}
let wood = SIMD3<Double>(170, 130, 85), yellow = SIMD3<Double>(242, 205, 55)
let box = CGRect(x: 0.12, y: 0.17, width: 0.76, height: 0.66) // Brickognize-Rahmen um die schräge Platte
let measured = partColor(in: scene(part: yellow, table: wood), box: box)!
assert(simd_length(measured - yellow) < 20, "gemessen \(measured), erwartet Gelb")
assert(plate.best(for: measured)?.name == "Yellow")
// Farbgedächtnis: Nutzer korrigiert "Tan" (warmes Licht) zu "White" → nächster ähnlicher Scan wird White.
import Foundation
MainActor.assumeIsolated {
    ColorMemory.fileURL = FileManager.default.temporaryDirectory.appending(path: "color-memory-test-\(UUID()).json")
    let partColors = [LegoColor(id: 19, name: "Tan", rgb: SIMD3(228, 205, 158), isTrans: false, bricklinkID: 2, sets: 300),
                      LegoColor(id: 15, name: "White", rgb: SIMD3(255, 255, 255), isTrans: false, bricklinkID: 1, sets: 500)]
    let warmWhite = SIMD3<Double>(222, 215, 176)
    assert(partColors.best(for: warmWhite)?.name == "Tan")                     // ohne Lernen: falsch
    assert(ColorMemory.choose(warmWhite, among: partColors) == nil)             // noch nichts gelernt
    ColorMemory.learn(measured: warmWhite, colorID: 15)
    assert(ColorMemory.choose(SIMD3(225, 212, 172), among: partColors)?.name == "White") // ähnliches Licht → gelernt
    assert(ColorMemory.choose(SIMD3(160, 165, 169), among: partColors) == nil)  // ganz andere Farbe → nicht anfassen
    assert(ColorMemory.choose(warmWhite, among: [partColors[0]]) == nil)        // Teil gibt es nicht in White → nicht wählen
    try? FileManager.default.removeItem(at: ColorMemory.fileURL)
}
print("ok")
