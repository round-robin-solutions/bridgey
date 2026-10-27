import Foundation

/*
 * Which feature defaults this install uses, decided once at launch and stored, so an update never
 * changes an existing install's settings. Fresh installs (0.10 beta 2 on) start with every optional
 * feature off until setup, a bundle or Settings turns it on; installs from before keep the old
 * defaults. The key is outside `settings.` and `setup.`, so Settings > Reset > Settings keeps it and
 * a reset goes back to this install's own defaults. Android has the same rule (DefaultsGeneration.kt).
 */
enum DefaultsGeneration {
    static let key = "install.defaultsGeneration"

    /// Installs from before 0.10 beta 2: most features on by default, as they always were.
    static let featuresOn = 1
    /// Every optional feature off until it is chosen.
    static let offUntilChosen = 2

    /// `stored`: the generation recorded earlier, if any. `priorInstall`: Bridgey ran on this Mac
    /// before (settings, its device ID or pairings exist), from a build that recorded no generation.
    static func resolve(stored: Int?, priorInstall: Bool) -> Int {
        stored ?? (priorInstall ? featuresOn : offUntilChosen)
    }

    /// Reads the stored generation, or decides and stores it. Call at launch before anything writes settings.
    @discardableResult
    static func settle(_ defaults: UserDefaults, priorInstall: Bool) -> Int {
        let stored = defaults.object(forKey: key) as? Int
        let generation = resolve(stored: stored, priorInstall: priorInstall)
        if stored == nil { defaults.set(generation, forKey: key) }
        return generation
    }

    /// The generation in use; an install that never settled one (tests, the old build) keeps the old defaults.
    static func current(_ defaults: UserDefaults) -> Int {
        defaults.object(forKey: key) as? Int ?? featuresOn
    }

    /// A feature's value when nothing is stored for it.
    static func featureDefault(_ feature: BridgeyFeature, generation: Int) -> Bool {
        generation >= offUntilChosen ? false : feature != .media && !feature.needsDeviceGrant
    }

    /// Every global feature switch: the stored value, else this generation's default.
    static func globalFeatures(_ defaults: UserDefaults) -> [BridgeyFeature: Bool] {
        let generation = current(defaults)
        return Dictionary(uniqueKeysWithValues: BridgeyFeature.allCases.map {
            ($0, defaults.object(forKey: "settings.global.\($0.rawValue)") as? Bool ?? featureDefault($0, generation: generation))
        })
    }
}
