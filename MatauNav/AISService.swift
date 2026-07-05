import Foundation

// MARK: - AIS target
//
// Carries the data the chart and detail sheet display. CPA/TCPA are computed
// on the Pi (state_server.py) and arrive pre-populated via PiStateService.
// The phone never talks to aisstream.io directly any more — one WebSocket on
// the boat feeds every phone over the local network.

struct AISTarget: Identifiable, Equatable {
    var id: Int { mmsi }              // MMSI is unique per vessel
    let mmsi: Int
    var name: String?
    var callSign: String?
    var shipType: Int?
    var latitude: Double
    var longitude: Double
    var cog: Double                   // degrees true
    var sog: Double                   // knots
    var heading: Double?              // degrees true; nil if not broadcast
    var rateOfTurn: Double?
    var navStatus: Int?
    var length: Double?               // metres
    var beam: Double?
    var draft: Double?
    var destination: String?
    var cpaNm: Double?                // pre-computed on the Pi
    var tcpaMin: Double?
    var lastUpdate: Date

    /// Plain-English ship type from ITU code.
    var shipTypeLabel: String {
        guard let t = shipType else { return "Vessel" }
        switch t {
        case 30: return "Fishing"
        case 31, 32: return "Towing"
        case 33: return "Dredging"
        case 34: return "Diving"
        case 35: return "Military"
        case 36: return "Sailing"
        case 37: return "Pleasure craft"
        case 40...49: return "High-speed craft"
        case 50: return "Pilot"
        case 51: return "Search & rescue"
        case 52: return "Tug"
        case 55: return "Law enforcement"
        case 58: return "Medical"
        case 60...69: return "Passenger"
        case 70...79: return "Cargo"
        case 80...89: return "Tanker"
        default: return "Vessel"
        }
    }
}
