import Testing
@testable import AuraCore

struct RouteTrimTests {
    @Test func sanitizedClampsToUnitRange() {
        #expect(RouteTrim.sanitized(-0.2) == 0)
        #expect(RouteTrim.sanitized(1.7) == 1)
        #expect(RouteTrim.sanitized(0.42) == 0.42)
    }

    @Test func sanitizedRejectsNonFinite() {
        #expect(RouteTrim.sanitized(.nan) == nil)
        #expect(RouteTrim.sanitized(.infinity) == nil)
        #expect(RouteTrim.sanitized(nil) == nil)
    }

    // Tolerance, not ==: quantized values are computed Doubles and some steps
    // produce representation error (0.3 → 0.30000000000000004).
    @Test func quantizedSnapsDown() {
        #expect(abs(RouteTrim.quantized(0.4239) - 0.42) < 1e-9)
        #expect(abs(RouteTrim.quantized(0.9999) - 0.995) < 1e-9)
        #expect(abs(RouteTrim.quantized(1.0) - 1.0) < 1e-9)
    }
}
