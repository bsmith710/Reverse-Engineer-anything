import Foundation

/// sRGB color with alpha, components in 0...1.
public struct RGBA: Equatable, Sendable {
  public var r: Double, g: Double, b: Double, a: Double
}

/// Parses `#rgb`, `#rrggbb`, `#rrggbbaa`, `rgb()/rgba()` and `hsl()` and formats all of them.
public enum ColorConverter {
  public static func parse(_ raw: String) -> RGBA? {
    let s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if s.hasPrefix("#") { return parseHex(String(s.dropFirst())) }
    if let args = functionArgs(s, names: ["rgb", "rgba"]), args.count >= 3 {
      let comps = args.prefix(3).compactMap { component($0, scale: 255) }
      guard comps.count == 3 else { return nil }
      let alpha = args.count > 3 ? component(args[3], scale: 1) ?? 1 : 1
      return RGBA(r: comps[0], g: comps[1], b: comps[2], a: alpha)
    }
    if let args = functionArgs(s, names: ["hsl", "hsla"]), args.count >= 3,
      let h = Double(args[0].replacingOccurrences(of: "deg", with: "")),
      let sat = component(args[1], scale: 100), let l = component(args[2], scale: 100)
    {
      let alpha = args.count > 3 ? component(args[3], scale: 1) ?? 1 : 1
      return hslToRGB(h: h, s: sat, l: l, a: alpha)
    }
    return nil
  }

  private static func parseHex(_ hex: String) -> RGBA? {
    guard [3, 4, 6, 8].contains(hex.count), hex.allSatisfy(\.isHexDigit) else { return nil }
    let expanded = hex.count <= 4 ? hex.map { "\($0)\($0)" }.joined() : hex
    guard let value = UInt64(expanded, radix: 16) else { return nil }
    let hasAlpha = expanded.count == 8
    let v = hasAlpha ? value : (value << 8) | 0xFF
    return RGBA(
      r: Double((v >> 24) & 0xFF) / 255, g: Double((v >> 16) & 0xFF) / 255,
      b: Double((v >> 8) & 0xFF) / 255, a: Double(v & 0xFF) / 255)
  }

  private static func functionArgs(_ s: String, names: [String]) -> [String]? {
    for name in names where s.hasPrefix(name + "(") && s.hasSuffix(")") {
      let inner = s.dropFirst(name.count + 1).dropLast()
      return inner.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "/" }).map(String.init)
    }
    return nil
  }

  private static func component(_ s: String, scale: Double) -> Double? {
    if s.hasSuffix("%"), let v = Double(s.dropLast()) { return clamp(v / 100) }
    guard let v = Double(s) else { return nil }
    return clamp(v / scale)
  }

  private static func clamp(_ v: Double) -> Double { min(1, max(0, v)) }

  static func hslToRGB(h: Double, s: Double, l: Double, a: Double) -> RGBA {
    let c = (1 - abs(2 * l - 1)) * s
    let hp = (h.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 60
    let x = c * (1 - abs(hp.truncatingRemainder(dividingBy: 2) - 1))
    let (r1, g1, b1): (Double, Double, Double) =
      switch hp {
      case 0..<1: (c, x, 0)
      case 1..<2: (x, c, 0)
      case 2..<3: (0, c, x)
      case 3..<4: (0, x, c)
      case 4..<5: (x, 0, c)
      default: (c, 0, x)
      }
    let m = l - c / 2
    return RGBA(r: r1 + m, g: g1 + m, b: b1 + m, a: a)
  }

  public static func hex(_ c: RGBA) -> String {
    let parts = [c.r, c.g, c.b].map { String(format: "%02X", Int(($0 * 255).rounded())) }
    let alpha = c.a < 1 ? String(format: "%02X", Int((c.a * 255).rounded())) : ""
    return "#" + parts.joined() + alpha
  }

  public static func rgb(_ c: RGBA) -> String {
    let (r, g, b) = (Int((c.r * 255).rounded()), Int((c.g * 255).rounded()), Int((c.b * 255).rounded()))
    return c.a < 1 ? "rgba(\(r), \(g), \(b), \(format(c.a)))" : "rgb(\(r), \(g), \(b))"
  }

  public static func hsl(_ c: RGBA) -> String {
    let maxV = max(c.r, c.g, c.b), minV = min(c.r, c.g, c.b)
    let l = (maxV + minV) / 2
    let d = maxV - minV
    var h = 0.0, s = 0.0
    if d > 0 {
      s = d / (1 - abs(2 * l - 1))
      switch maxV {
      case c.r: h = 60 * ((c.g - c.b) / d).truncatingRemainder(dividingBy: 6)
      case c.g: h = 60 * ((c.b - c.r) / d + 2)
      default: h = 60 * ((c.r - c.g) / d + 4)
      }
    }
    if h < 0 { h += 360 }
    let core = "\(Int(h.rounded())), \(Int((s * 100).rounded()))%, \(Int((l * 100).rounded()))%"
    return c.a < 1 ? "hsla(\(core), \(format(c.a)))" : "hsl(\(core))"
  }

  public static func summary(_ raw: String) -> String? {
    guard let c = parse(raw) else { return nil }
    return [hex(c), rgb(c), hsl(c)].joined(separator: "\n")
  }

  private static func format(_ v: Double) -> String {
    let rounded = (v * 100).rounded() / 100
    return rounded == rounded.rounded() ? String(Int(rounded)) : String(rounded)
  }
}

/// Converts a single measurement to its common counterpart.
/// Supported: temperature, length, mass, volume, speed, data size, and CSS px/pt/rem.
public enum UnitConverter {
  public struct Quantity: Equatable, Sendable {
    public var value: Double
    public var unit: String
  }

  /// Unit alias → (canonical unit, dimension, factor to the dimension's base unit).
  private static let table: [String: (unit: String, dimension: String, factor: Double)] = {
    var t: [String: (String, String, Double)] = [:]
    func add(_ aliases: [String], _ unit: String, _ dim: String, _ factor: Double) {
      for a in aliases { t[a] = (unit, dim, factor) }
    }
    add(["mm", "millimeter", "millimeters"], "mm", "length", 0.001)
    add(["cm", "centimeter", "centimeters"], "cm", "length", 0.01)
    add(["m", "meter", "meters", "metre", "metres"], "m", "length", 1)
    add(["km", "kilometer", "kilometers", "kilometre", "kilometres"], "km", "length", 1000)
    add(["in", "inch", "inches", "\""], "in", "length", 0.0254)
    add(["ft", "foot", "feet", "'"], "ft", "length", 0.3048)
    add(["yd", "yard", "yards"], "yd", "length", 0.9144)
    add(["mi", "mile", "miles"], "mi", "length", 1609.344)
    add(["g", "gram", "grams"], "g", "mass", 0.001)
    add(["kg", "kilogram", "kilograms", "kgs"], "kg", "mass", 1)
    add(["oz", "ounce", "ounces"], "oz", "mass", 0.028349523125)
    add(["lb", "lbs", "pound", "pounds"], "lb", "mass", 0.45359237)
    add(["ml", "milliliter", "milliliters"], "ml", "volume", 0.001)
    add(["l", "liter", "liters", "litre", "litres"], "L", "volume", 1)
    add(["gal", "gallon", "gallons"], "gal", "volume", 3.785411784)
    add(["floz", "fl oz", "fluid ounce", "fluid ounces"], "fl oz", "volume", 0.0295735295625)
    add(["km/h", "kmh", "kph"], "km/h", "speed", 1 / 3.6)
    add(["mph"], "mph", "speed", 0.44704)
    add(["b", "byte", "bytes"], "B", "data", 1)
    add(["kb"], "KB", "data", 1e3)
    add(["mb"], "MB", "data", 1e6)
    add(["gb"], "GB", "data", 1e9)
    add(["tb"], "TB", "data", 1e12)
    add(["kib"], "KiB", "data", 1024)
    add(["mib"], "MiB", "data", 1_048_576)
    add(["gib"], "GiB", "data", 1_073_741_824)
    add(["px"], "px", "css", 1)
    add(["pt"], "pt", "css", 4.0 / 3.0)
    add(["rem", "em"], "rem", "css", 16)
    add(["°c", "c", "celsius", "ºc"], "°C", "temperature", 1)
    add(["°f", "f", "fahrenheit", "ºf"], "°F", "temperature", 1)
    add(["k", "kelvin"], "K", "temperature", 1)
    return t.mapValues { (unit: $0.0, dimension: $0.1, factor: $0.2) }
  }()

  /// Target unit for each source unit (metric ↔ imperial, decimal ↔ binary, px ↔ pt/rem).
  private static let counterparts: [String: [String]] = [
    "mm": ["in"], "cm": ["in"], "m": ["ft"], "km": ["mi"],
    "in": ["cm"], "ft": ["m"], "yd": ["m"], "mi": ["km"],
    "g": ["oz"], "kg": ["lb"], "oz": ["g"], "lb": ["kg"],
    "ml": ["fl oz"], "L": ["gal"], "gal": ["L"], "fl oz": ["ml"],
    "km/h": ["mph"], "mph": ["km/h"],
    "B": ["KB"], "KB": ["KiB"], "MB": ["MiB"], "GB": ["GiB"], "TB": ["GiB"],
    "KiB": ["KB"], "MiB": ["MB"], "GiB": ["GB"],
    "px": ["pt", "rem"], "pt": ["px"], "rem": ["px"],
    "°C": ["°F"], "°F": ["°C"], "K": ["°C"],
  ]

  public static func parse(_ raw: String) -> Quantity? {
    let s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      .replacingOccurrences(of: ",", with: "")
    guard
      let match = s.range(of: #"^-?\d+(\.\d+)?\s*[a-zº°/"' ]+$"#, options: .regularExpression),
      match == s.startIndex..<s.endIndex
    else { return nil }
    let numberEnd = s.firstIndex(where: { !($0.isNumber || $0 == "." || $0 == "-") }) ?? s.endIndex
    guard let value = Double(s[..<numberEnd]) else { return nil }
    let unitText = s[numberEnd...].trimmingCharacters(in: .whitespaces)
    guard let entry = table[unitText] else { return nil }
    return Quantity(value: value, unit: entry.unit)
  }

  public static func convert(_ q: Quantity, to target: String) -> Quantity? {
    guard let from = table.values.first(where: { $0.unit == q.unit }),
      let to = table.values.first(where: { $0.unit == target }),
      from.dimension == to.dimension
    else { return nil }
    if from.dimension == "temperature" {
      let kelvin: Double =
        switch q.unit {
        case "°C": q.value + 273.15
        case "°F": (q.value - 32) * 5 / 9 + 273.15
        default: q.value
        }
      let out: Double =
        switch target {
        case "°C": kelvin - 273.15
        case "°F": (kelvin - 273.15) * 9 / 5 + 32
        default: kelvin
        }
      return Quantity(value: out, unit: target)
    }
    return Quantity(value: q.value * from.factor / to.factor, unit: target)
  }

  public static func summary(_ raw: String) -> String? {
    guard let q = parse(raw), let targets = counterparts[q.unit] else { return nil }
    let results = targets.compactMap { convert(q, to: $0) }.map(format)
    return results.isEmpty ? nil : results.joined(separator: "\n")
  }

  public static func format(_ q: Quantity) -> String {
    let magnitude = abs(q.value)
    // ≥1: fixed decimals; <1: three significant digits so 0.907 kg and 0.00123 in both read sensibly.
    let digits = magnitude >= 100 ? 1 : magnitude >= 1 ? 2 : max(3, 2 - Int(floor(log10(max(magnitude, 1e-12)))))
    var number = String(format: "%.\(digits)f", q.value)
    if number.contains(".") {
      while number.hasSuffix("0") { number.removeLast() }
      if number.hasSuffix(".") { number.removeLast() }
    }
    let joiner = q.unit.hasPrefix("°") ? "" : " "
    return number + joiner + q.unit
  }
}
