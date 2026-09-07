import Foundation

struct UpdateOffer: Equatable {
    let build: String
    let version: String
    let notesURL: URL?
    var informationOnly = false
}
