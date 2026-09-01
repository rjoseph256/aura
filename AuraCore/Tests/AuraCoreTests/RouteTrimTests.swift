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

    // Tolerance, not ==: quantized values are computed Doubles and many inputs
    // produce representation error (0.0724 → 0.07200000000000001).
    //
    // Expectations track the 0.001 default (0.005 left the dim boundary ~150 m
    // behind the puck on a 30 km route — see `RouteTrim.quantized`).
    @Test func quantizedSnapsDown() {
        #expect(abs(RouteTrim.quantized(0.4239) - 0.423) < 1e-9)
        #expect(abs(RouteTrim.quantized(0.9999) - 0.999) < 1e-9)
        #expect(abs(RouteTrim.quantized(1.0) - 1.0) < 1e-9)
    }
}
