import SwiftUI

/// The panel that drops down from the menu bar icon.
struct TeamPanel: View {
    @EnvironmentObject private var team: TeamStore

    var body: some View {
        Group {
            switch team.phase {
            case .needsConfig:
                MessageView(
                    symbol: "wrench.and.screwdriver",
                    title: "Setup needed",
                    detail: "Add your Supabase URL and key to Config.local.json, then rebuild."
                )
            case .loading:
                ProgressView().controlSize(.small).padding(30)
            case .welcome:
                WelcomeView()
            case .inTeam:
                TeamList()
            }
        }
        .frame(width: 280)
    }
}

private struct MessageView: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 22)).foregroundStyle(.secondary)
            Text(title).font(.system(size: 13, weight: .semibold))
            Text(detail)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .controlSize(.small)
                .padding(.top, 6)
        }
        .padding(20)
    }
}

/// First launch: your name, then start a team or join one with its code.
private struct WelcomeView: View {
    @EnvironmentObject private var team: TeamStore
    @AppStorage("displayName") private var name = ""
    @State private var code = ""
    @State private var isJoining = false
    @State private var isWorking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(AppInfo.name).font(.system(size: 15, weight: .bold))

            TextField("Your name", text: $name)
                .textFieldStyle(.roundedBorder)
                .textContentType(.name)

            if isJoining {
                TextField("Team code, e.g. MANGO-482913", text: $code)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(join)
                HStack {
                    Button("Join Team", action: join)
                        .keyboardShortcut(.defaultAction)
                        .disabled(name.trimmed.isEmpty || code.trimmed.isEmpty || isWorking)
                    Button("Back") {
                        isJoining = false
                        team.errorMessage = nil
                    }
                    .buttonStyle(.link)
                    .font(.system(size: 11))
                }
            } else {
                HStack {
                    Button("Join a Team") {
                        isJoining = true
                        team.errorMessage = nil
                    }
                    .keyboardShortcut(.defaultAction)
                    Button("Start a Team", action: start)
                }
                .disabled(name.trimmed.isEmpty || isWorking)
                Text("Joining? Ask a teammate for the team code.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            ErrorText()

            HStack {
                if isWorking { ProgressView().controlSize(.small) }
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
    }

    private func start() {
        guard !isWorking else { return }
        isWorking = true
        Task {
            await team.startTeam(name: name.trimmed)
            isWorking = false
        }
    }

    private func join() {
        guard !isWorking, !name.trimmed.isEmpty, !code.trimmed.isEmpty else { return }
        isWorking = true
        Task {
            await team.joinTeam(name: name.trimmed, code: code.trimmed)
            isWorking = false
        }
    }
}

private struct ErrorText: View {
    @EnvironmentObject private var team: TeamStore

    var body: some View {
        if let message = team.errorMessage {
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct TeamList: View {
    @EnvironmentObject private var team: TeamStore

    var body: some View {
        VStack(spacing: 0) {
            if !team.callMembers.isEmpty {
                CallBar()
                Divider()
            }

            VStack(spacing: 2) {
                if team.teammates.isEmpty {
                    Text("No teammates yet. Send them the team code below.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 8)
                }
                ForEach(team.sortedTeammates) { teammate in
                    TeammateRow(teammate: teammate)
                }
                TeamCodeRow()
            }
            .padding(6)

            if team.errorMessage != nil {
                ErrorText()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
            }

            Divider()
            Footer()
        }
        .task { await team.reloadTeam() }
    }
}

/// Shows the team code; click to copy it for a teammate.
private struct TeamCodeRow: View {
    @EnvironmentObject private var team: TeamStore
    @State private var copied = false
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: copied ? "checkmark" : "plus")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .background(Circle().fill(Color.primary.opacity(0.08)))

            VStack(alignment: .leading, spacing: 1) {
                Text(copied ? "Copied" : "Invite with team code")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Text(team.teamCode ?? "…")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(isHovered ? Color.primary.opacity(0.08) : .clear)
        )
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture {
            team.copyTeamCode()
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                copied = false
            }
        }
        .help("Click to copy the code, then send it to a teammate")
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
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
        .contextMenu {
            Button("Remove \(teammate.name) from Team") {
                Task { await team.remove(teammate) }
            }
        }
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

            Menu {
                if let me = team.me {
                    Text("You: \(me.name)")
                    Divider()
                }
                Button("Copy Team Code") { team.copyTeamCode() }
                Button("New Team Code") { Task { await team.regenerateCode() } }
                Button("Leave Team") { Task { await team.leaveTeam() } }
                Divider()
                Button("Quit \(AppInfo.name)") { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q")
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }
}
