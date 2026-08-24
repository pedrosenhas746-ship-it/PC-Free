import Foundation

final class CampaignState {
    static let shared = CampaignState()

    private let defaults = UserDefaults.standard
    private let chapterKey = "iamcat.stage2.chapter"
    private let collectedKey = "iamcat.stage2.collected"

    let chapterNames = [
        "Tutorial",
        "Secret Room",
        "Wardrobe",
        "Granny House",
        "Granny Garage",
        "Outside",
        "Butcher Shop",
        "Finale"
    ]

    private(set) var chapter: Int
    private(set) var collectedToyIDs: Set<String>

    private init() {
        chapter = max(0, min(7, defaults.integer(forKey: chapterKey)))
        let saved = defaults.stringArray(forKey: collectedKey) ?? []
        collectedToyIDs = Set(saved)
    }

    var currentTitle: String {
        chapterNames[chapter]
    }

    var progressText: String {
        "Chapter \(chapter + 1)/8 — \(currentTitle) — toys \(collectedToyIDs.count)/3"
    }

    @discardableResult
    func collectToy(id: String) -> Bool {
        guard !collectedToyIDs.contains(id) else { return false }
        collectedToyIDs.insert(id)

        if collectedToyIDs.count >= 3 {
            if chapter < chapterNames.count - 1 {
                chapter += 1
            }
            collectedToyIDs.removeAll()
        }

        save()
        return true
    }

    func resetProgress() {
        chapter = 0
        collectedToyIDs.removeAll()
        save()
    }

    private func save() {
        defaults.set(chapter, forKey: chapterKey)
        defaults.set(Array(collectedToyIDs).sorted(), forKey: collectedKey)
    }
}
