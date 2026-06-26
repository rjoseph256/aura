import Testing
import AuraCore

struct TrackSimplifierTests {
    private func line(_ n: Int) -> [Coordinate] {
        (0..<n).map { Coordinate(latitude: Double($0), longitude: Double($0)) }
    }

    @Test func underCapReturnsInputUnchanged() {
        let input = line(40)
        #expect(TrackSimplifier.thumbnail(from: input, maxPoints: 60) == input)
    }

    @Test func atCapReturnsInputUnchanged() {
        let input = line(60)
        #expect(TrackSimplifier.thumbnail(from: input, maxPoints: 60) == input)
    }

    @Test func overCapDownsamplesToCapAndKeepsEndpoints() {
        let input = line(500)
        let out = TrackSimplifier.thumbnail(from: input, maxPoints: 60)
        #expect(out.count == 60)
        #expect(out.first == input.first)
        #expect(out.last == input.last)
    }

    @Test func emptyAndSinglePassThrough() {
        #expect(TrackSimplifier.thumbnail(from: [], maxPoints: 60) == [])
        let one = line(1)
        #expect(TrackSimplifier.thumbnail(from: one, maxPoints: 60) == one)
    }
}
