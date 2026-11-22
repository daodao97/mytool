import Foundation

public enum WindowMatcher {
    /// Strong identities are assigned first, so an ordinal fallback cannot steal an exact match.
    public static func match(saved: [WindowRecord], live: [WindowRecord],
                             recoveringLayout: Bool = false, displays: [DisplayInfo] = []) -> [(saved: Int, live: Int)] {
        var candidates: [(saved: Int, live: Int, score: Int)] = []
        for (s, old) in saved.enumerated() {
            for (l, current) in live.enumerated() where old.bundleID == current.bundleID {
                var score = 0
                if let systemID = old.systemID, systemID == current.systemID { score = 2000 }
                else if old.id == current.id { score = 1000 }
                else if !documentsAgree(old, current, recoveringLayout: recoveringLayout) { continue }
                else if !old.document.isEmpty && old.document == current.document {
                    score = 800 + (old.title == current.title ? 40 : 0) + (old.ordinal == current.ordinal ? 1 : 0)
                }
                else if !old.axIdentifier.isEmpty && old.axIdentifier == current.axIdentifier &&
                            saved.filter({ $0.bundleID == old.bundleID && $0.axIdentifier == old.axIdentifier }).count == 1 &&
                            live.filter({ $0.bundleID == old.bundleID && $0.axIdentifier == old.axIdentifier }).count == 1 { score = 600 }
                else if !old.title.isEmpty && old.title == current.title { score = 400 }
                else if old.ordinal == current.ordinal {
                    // Titled/document windows with conflicting identities should never be swapped blindly.
                    let conflictingDocument = !documentsAgree(old, current, recoveringLayout: recoveringLayout)
                    let conflictingTitle = !old.title.isEmpty && !current.title.isEmpty && old.title != current.title
                    if !conflictingDocument && !conflictingTitle { score = 100 }
                }
                if score > 0 { candidates.append((s, l, score)) }
            }
        }
        candidates.sort {
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.saved != $1.saved { return $0.saved < $1.saved }
            return $0.live < $1.live
        }
        var usedSaved = Set<Int>(), usedLive = Set<Int>()
        var result: [(saved: Int, live: Int)] = candidates.compactMap { candidate in
            guard !usedSaved.contains(candidate.saved), !usedLive.contains(candidate.live) else { return nil }
            usedSaved.insert(candidate.saved); usedLive.insert(candidate.live)
            return (candidate.saved, candidate.live)
        }
        guard recoveringLayout else { return result }
        // Browser tabs, terminals and chat windows change titles without creating a new
        // window. Only after all strong matches are reserved, recover remaining app slots.
        for bundle in Set(saved.map(\.bundleID)).sorted() {
            var old = saved.indices.filter { saved[$0].bundleID == bundle && !usedSaved.contains($0) }
            var current = live.indices.filter { live[$0].bundleID == bundle && !usedLive.contains($0) }
            // Different-sized windows can be recognized after macOS clamps them onto the
            // laptop display. Require a unique size on both sides before using this clue.
            for s in old {
                let compatible = current.filter { l in
                    documentsAgree(saved[s], live[l], recoveringLayout: true) && sizeAgrees(saved[s], live[l], displays: displays)
                }
                guard compatible.count == 1, let l = compatible.first,
                      old.filter({ !usedSaved.contains($0) && documentsAgree(saved[$0], live[l], recoveringLayout: true) &&
                          sizeAgrees(saved[$0], live[l], displays: displays) }).count == 1 else { continue }
                result.append((s, l)); usedSaved.insert(s); usedLive.insert(l)
                current.removeAll { $0 == l }
            }
            old.removeAll { usedSaved.contains($0) }
            current.removeAll { usedLive.contains($0) }
            // A closed/new window must not prevent all remaining app slots from
            // recovering after titles and sizes change. Use only unique ordinals;
            // strong identities and unique sizes have already reserved their matches.
            if old.count != current.count {
                for s in old {
                    let ordinal = saved[s].ordinal
                    guard old.filter({ saved[$0].ordinal == ordinal }).count == 1 else { continue }
                    let slots = current.filter { live[$0].ordinal == ordinal }
                    guard slots.count == 1, let l = slots.first,
                          documentsAgree(saved[s], live[l], recoveringLayout: true) else { continue }
                    result.append((s, l)); usedSaved.insert(s); usedLive.insert(l)
                    current.removeAll { $0 == l }
                }
                continue
            }
            // Equal remaining counts allow app window order to migrate legacy slots
            // once; subsequent restore passes bind the resolved runtime identities.
            old.sort { saved[$0].ordinal < saved[$1].ordinal }
            current.sort { live[$0].ordinal < live[$1].ordinal }
            for (s, l) in zip(old, current) where documentsAgree(saved[s], live[l], recoveringLayout: true) {
                result.append((s, l)); usedSaved.insert(s); usedLive.insert(l)
            }
        }
        return result
    }

    private static func documentsAgree(_ old: WindowRecord, _ live: WindowRecord, recoveringLayout: Bool = false) -> Bool {
        if old.document.isEmpty || live.document.isEmpty || old.document == live.document { return true }
        // Browsers expose the current tab URL as AXDocument. Navigating that tab does
        // not replace the browser window; file documents retain strict identity checks.
        let browsers: Set<String> = ["com.google.Chrome", "com.apple.Safari", "org.mozilla.firefox",
            "com.brave.Browser", "com.microsoft.edgemac", "com.operasoftware.Opera", "com.vivaldi.Vivaldi", "company.thebrowser.Browser"]
        return recoveringLayout && browsers.contains(old.bundleID) &&
            !old.document.lowercased().hasPrefix("file:") && !live.document.lowercased().hasPrefix("file:")
    }

    private static func sizeAgrees(_ old: WindowRecord, _ live: WindowRecord, displays: [DisplayInfo]) -> Bool {
        let clamped = displays.first(where: { $0.id == live.displayID }).map { old.frame.constrained(to: $0.workArea) } ?? old.frame
        return [old.frame, clamped].contains { abs($0.width - live.frame.width) < 3 && abs($0.height - live.frame.height) < 3 }
    }
}
