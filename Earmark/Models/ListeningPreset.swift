import Foundation

struct ListeningPreset: Identifiable, Codable, Equatable, Sendable {
    var id: String
    var name: String
    var speed: Float
    var boostQuiet: Bool
    var volumeBoost: Float
    var skipSilence: Bool
    var sleepMinutes: Int
    static let defaults: [Self] = [
        .init(id: "driving", name: "Driving", speed: 1, boostQuiet: true, volumeBoost: 1, skipSilence: false, sleepMinutes: 0),
        .init(id: "bedtime", name: "Bedtime", speed: 1, boostQuiet: false, volumeBoost: 1, skipSilence: false, sleepMinutes: 20),
    ]
    init(id: String, name: String, speed: Float, boostQuiet: Bool, volumeBoost: Float, skipSilence: Bool, sleepMinutes: Int) {
        self.id = id; self.name = name; self.speed = speed; self.boostQuiet = boostQuiet
        self.volumeBoost = volumeBoost; self.skipSilence = skipSilence; self.sleepMinutes = sleepMinutes
    }
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Preset"
        speed = min(3, max(0.5, try c.decodeIfPresent(Float.self, forKey: .speed) ?? 1))
        boostQuiet = try c.decodeIfPresent(Bool.self, forKey: .boostQuiet) ?? false
        volumeBoost = min(3, max(1, try c.decodeIfPresent(Float.self, forKey: .volumeBoost) ?? 1))
        skipSilence = try c.decodeIfPresent(Bool.self, forKey: .skipSilence) ?? false
        sleepMinutes = min(180, max(0, try c.decodeIfPresent(Int.self, forKey: .sleepMinutes) ?? 0))
    }
}
