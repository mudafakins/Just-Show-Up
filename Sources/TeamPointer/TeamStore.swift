import SwiftUI

/// What the app is doing right now. Step 1 only simulates these states;
/// real calls arrive with LiveKit in step 3.
enum Activity: Equatable {
    case idle
    case inCall(with: Set<UUID>)
}

@MainActor
final class TeamStore: ObservableObject {
    @Published var teammates: [Teammate] = TeamStore.sampleTeam
    @Published var activity: Activity = .idle
    @Published var doNotDisturb = false
    @Published var isMuted = false
    @Published var isSharingScreen = false
    @Published var talkingTo: UUID?

    var menuBarSymbol: String {
        if talkingTo != nil { return "dot.radiowaves.left.and.right" }
        if case .inCall = activity { return "phone.fill" }
        return doNotDisturb ? "moon.fill" : "hand.point.up.left.fill"
    }

    var sortedTeammates: [Teammate] {
        teammates.sorted {
            if $0.isOnline != $1.isOnline { return $0.isOnline }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    var callMembers: [Teammate] {
        guard case .inCall(let ids) = activity else { return [] }
        return teammates.filter { ids.contains($0.id) }
    }

    func isInCall(_ teammate: Teammate) -> Bool {
        guard case .inCall(let ids) = activity else { return false }
        return ids.contains(teammate.id)
    }

    /// Starts a call, or adds the teammate to the current one (group calls).
    func call(_ teammate: Teammate) {
        guard teammate.isOnline else { return }
        if case .inCall(var ids) = activity {
            ids.insert(teammate.id)
            activity = .inCall(with: ids)
        } else {
            activity = .inCall(with: [teammate.id])
        }
    }

    func hangUp() {
        activity = .idle
        isMuted = false
        isSharingScreen = false
    }

    func setTalking(_ talking: Bool, to teammate: Teammate) {
        guard teammate.isOnline else { return }
        talkingTo = talking ? teammate.id : nil
    }

    private static let sampleTeam: [Teammate] = [
        Teammate(id: UUID(), name: "Maya Chen", email: "maya@example.com", isOnline: true, colorIndex: 0),
        Teammate(id: UUID(), name: "Arjun Patel", email: "arjun@example.com", isOnline: true, colorIndex: 3),
        Teammate(id: UUID(), name: "Sofia Rossi", email: "sofia@example.com", isOnline: true, colorIndex: 5),
        Teammate(id: UUID(), name: "Leo Müller", email: "leo@example.com", isOnline: false, colorIndex: 1),
        Teammate(id: UUID(), name: "Noor Hassan", email: "noor@example.com", isOnline: false, colorIndex: 2),
    ]
}
