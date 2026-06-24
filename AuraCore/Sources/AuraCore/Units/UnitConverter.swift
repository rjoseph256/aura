public enum UnitConverter {
    public static func mph(fromMetersPerSecond v: Double) -> Double { v * 2.2369362920544 }
    public static func miles(fromMeters m: Double) -> Double { m / 1609.344 }
    public static func feet(fromMeters m: Double) -> Double { m * 3.280839895013123 }
    public static func km(fromMeters m: Double) -> Double { m / 1000 }
    public static func kmh(fromMetersPerSecond v: Double) -> Double { v * 3.6 }
}
