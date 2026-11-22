import Foundation

public enum LayoutRecovery {
    case remembered(LayoutProfile)
    case adapted(LayoutProfile)

    /// Known window positions win; newer desk layouts supply windows absent from that memory.
    public static func resolve(displays: [DisplayInfo], profiles: [LayoutProfile], previous: LayoutProfile?) -> LayoutRecovery? {
        guard !displays.isEmpty else { return nil }
        let topology = DisplayInfo.topologyKey(displays)
        if let remembered = profiles.filter({ $0.isAutomatic && $0.topologyKey == topology && !$0.windows.isEmpty })
            .max(by: { $0.updatedAt < $1.updatedAt }) {
            let source = comparableDesk(displays: displays, profiles: profiles, previous: previous,
                                        excluding: topology)
            return .remembered(supplement(remembered, from: source, on: displays))
        }
        // A commute can include a laptop-only session or an app restart. Reuse the latest
        // comparable desk layout rather than copying the intervening laptop arrangement.
        if let source = comparableDesk(displays: displays, profiles: profiles, previous: previous) {
            return .adapted(source)
        }
        if let previous, !previous.windows.isEmpty { return .adapted(previous) }
        return nil
    }

    private static func comparableDesk(displays: [DisplayInfo], profiles: [LayoutProfile],
                                       previous: LayoutProfile?, excluding topology: String? = nil) -> LayoutProfile? {
        let builtInIDs = Set(displays.filter(\.isBuiltIn).map(\.id))
        let externalCount = displays.filter { !$0.isBuiltIn }.count
        guard externalCount > 0 else { return nil }
        var candidates = profiles.filter(\.isAutomatic)
        if let previous { candidates.append(previous) }
        return candidates.filter {
            !$0.windows.isEmpty && $0.topologyKey != topology &&
            Set($0.displays.filter(\.isBuiltIn).map(\.id)) == builtInIDs &&
            $0.displays.filter { !$0.isBuiltIn }.count == externalCount
        }.max(by: { $0.updatedAt < $1.updatedAt })
    }

    private static func supplement(_ remembered: LayoutProfile, from source: LayoutProfile?,
                                   on displays: [DisplayInfo]) -> LayoutProfile {
        guard let source, source.updatedAt > remembered.updatedAt else { return remembered }
        let pairs = WindowMatcher.match(saved: remembered.windows, live: source.windows,
                                       recoveringLayout: true, displays: displays)
        let used = Set(pairs.map(\.live))
        var result = remembered
        // Normalize both sets into the current coordinate space before combining them.
        func projected(_ window: WindowRecord, from profile: LayoutProfile) -> WindowRecord? {
            guard let frame = profile.destination(for: window, on: displays),
                  let display = DisplayInfo.containing(frame, in: displays) else { return nil }
            var copy = window; copy.frame = frame; copy.displayID = display.id
            return copy
        }
        result.windows = remembered.windows.compactMap { projected($0, from: remembered) }
        result.displays = displays
        for index in source.windows.indices where !used.contains(index) {
            guard let window = projected(source.windows[index], from: source),
                  !result.windows.contains(where: { $0.id == window.id }) else { continue }
            result.windows.append(window)
        }
        return result
    }
}
