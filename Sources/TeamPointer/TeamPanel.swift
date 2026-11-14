import SwiftUI

/// The panel that drops down from the menu bar icon.
struct TeamPanel: View {
    @EnvironmentObject private var team: TeamStore

    var body: some View {
        VStack(spacing: 0) {
            if !team.callMembers.isEmpty {
                CallBar()
                Divider()
            }

            VStack(spacing: 2) {
                ForEach(team.sortedTeammates) { teammate in
                    TeammateRow(teammate: teammate)
                }
            }
            .padding(6)

            Divider()
            Footer()
        }
        .frame(width: 280)
    }
}

private struct TeammateRow: View {
    @EnvironmentObject private var team: TeamStore
    let teammate: Teammate
    @State private var isHovered = false

    private var isTalking: Bool { team.talkingTo == teammate.id }

    var body: some View {
        HStack(spacing: 10) {
            Avatar(teammate: teammate)

            VStack(alignment: .leading, spacing: 1) {
                Text(teammate.name)
                    .font(.system(size: 13, weight: .medium))
                Text(statusText)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            if teammate.isOnline && (isHovered || isTalking) {
                TalkButton(teammate: teammate)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(isHovered && teammate.isOnline ? Color.primary.opacity(0.08) : .clear)
        )
        .contentShape(Rectangle())
        .opacity(teammate.isOnline ? 1 : 0.45)
        .onHover { isHovered = $0 }
        .onTapGesture { team.call(teammate) }
        .help(teammate.isOnline ? "Click to call \(teammate.name)" : "\(teammate.name) is offline")
    }

    private var statusText: String {
        if isTalking { return "Talking…" }
        if team.isInCall(teammate) { return "In call with you" }
        return teammate.isOnline ? "Online" : "Offline"
    }
}

/// Walkie-talkie: hold to talk, release to stop.
private struct TalkButton: View {
    @EnvironmentObject private var team: TeamStore
    let teammate: Teammate

    private var isTalking: Bool { team.talkingTo == teammate.id }

    var body: some View {
        Image(systemName: "dot.radiowaves.left.and.right")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(isTalking ? Color.white : Color.secondary)
            .frame(width: 26, height: 26)
            .background(Circle().fill(isTalking ? Color.red : Color.primary.opacity(0.1)))
            .scaleEffect(isTalking ? 1.15 : 1)
            .animation(.easeOut(duration: 0.12), value: isTalking)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        if !isTalking { team.setTalking(true, to: teammate) }
                    }
                    .onEnded { _ in team.setTalking(false, to: teammate) }
            )
            .help("Hold to talk to \(teammate.name)")
    }
}

private struct Avatar: View {
    let teammate: Teammate

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Circle()
                .fill(teammate.color.gradient)
                .frame(width: 28, height: 28)
                .overlay(
                    Text(teammate.initials)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                )
            if teammate.isOnline {
                Circle()
                    .fill(.green)
                    .frame(width: 8, height: 8)
                    .overlay(Circle().stroke(.background, lineWidth: 1.5))
            }
        }
    }
}

/// Shown at the top of the panel while a call is active.
private struct CallBar: View {
    @EnvironmentObject private var team: TeamStore

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(team.callMembers.map { $0.name.components(separatedBy: " ")[0] }.joined(separator: ", "))
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text(team.isSharingScreen ? "Sharing your screen" : "In call")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            RoundButton(
                symbol: team.isMuted ? "mic.slash.fill" : "mic.fill",
                tint: team.isMuted ? .orange : nil,
                help: team.isMuted ? "Unmute" : "Mute"
            ) { team.isMuted.toggle() }

            RoundButton(
                symbol: "rectangle.inset.filled.and.person.filled",
                tint: team.isSharingScreen ? .green : nil,
                help: team.isSharingScreen ? "Stop sharing" : "Share screen"
            ) { team.isSharingScreen.toggle() }

            RoundButton(symbol: "phone.down.fill", tint: .red, help: "Hang up") {
                team.hangUp()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

private struct RoundButton: View {
    let symbol: String
    var tint: Color?
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint == nil ? Color.primary : Color.white)
                .frame(width: 28, height: 28)
                .background(Circle().fill(tint ?? Color.primary.opacity(0.1)))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

private struct Footer: View {
    @EnvironmentObject private var team: TeamStore

    var body: some View {
        HStack(spacing: 12) {
            Toggle(isOn: $team.doNotDisturb) {
                Label("Do Not Disturb", systemImage: "moon.fill")
                    .font(.system(size: 11))
            }
            .toggleStyle(.switch)
            .controlSize(.mini)

            Spacer(minLength: 0)

            Button("Quit") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .keyboardShortcut("q")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }
}
