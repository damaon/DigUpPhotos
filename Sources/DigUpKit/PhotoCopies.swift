import Foundation

/// One photo saved more than once next to itself: IMG_1938.HEIC as shot, IMG_1938.JPG converted, and IMG_E1938.JPG
/// edited in Photos. They all match a search equally, so results showed such a photo two or three times over (1,730
/// names with more than one copy and 651 edited copies in one library, 2026-10-29).
public enum PhotoCopies {
    /// The photo a path is a copy of ("<folder>/<name>", IMG_E… read as IMG_…), and whether it's an edited copy.
    static func shot(_ path: String) -> (key: String, edited: Bool) {
        let folder = (path as NSString).deletingLastPathComponent
        var name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        let number = name.dropFirst(5)
        let edited = name.hasPrefix("IMG_E") && !number.isEmpty && number.allSatisfy(\.isNumber)
        if edited { name = "IMG_" + number }
        return (folder + "/" + name.lowercased(), edited)
    }

    /// `items` with one entry per photo, where it first appears: the edited copy when there is one (that's the one the
    /// user wanted to keep), else the best-placed copy. Videos and other files pass through (a Live Photo's movie
    /// shares the photo's name).
    public static func one<Item>(_ items: [Item], path: (Item) -> String,
                                 isPhoto: (Item) -> Bool = { _ in true }) -> [Item] {
        var chosen: [String: Int] = [:]
        var copies: [String: Int] = [:]
        for (index, item) in items.enumerated() where isPhoto(item) {
            let shot = shot(path(item))
            copies[shot.key, default: 0] += 1
            if let current = chosen[shot.key] {
                if shot.edited, !Self.shot(path(items[current])).edited { chosen[shot.key] = index }
            } else {
                chosen[shot.key] = index
            }
        }
        guard copies.values.contains(where: { $0 > 1 }) else { return items }
        var out: [Item] = []
        var placed = Set<String>()
        for item in items {
            guard isPhoto(item) else {
                out.append(item)
                continue
            }
            let key = shot(path(item)).key
            if placed.insert(key).inserted { out.append(items[chosen[key]!]) }
        }
        return out
    }
}
