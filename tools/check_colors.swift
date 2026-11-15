// Selbsttest der Farbwahl. Ausführen:
// swiftc -o /tmp/check_colors tools/check_colors.swift LegoScanner/Rebrickable.swift && /tmp/check_colors
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
print("ok")
