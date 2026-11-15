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
        .frame(width: 320)
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
            Text(AppInfo.name)
                .font(.system(size: 14, weight: .bold))
                .frame(maxWidth: .infinity)

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
    @State private var search = ""

    private var visibleTeammates: [Teammate] {
        let query = search.trimmed
        guard !query.isEmpty else { return team.sortedTeammates }
        return team.sortedTeammates.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(spacing: 0) {
            Header()
            if team.isEditingName {
                RenameBar()
                    .padding(.horizontal, 12)
                    .padding(.bottom, 6)
            } else {
                SearchField(text: $search)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 6)
            }

            if let invite = team.roomInvite, !team.isInRoom {
                RoomInviteBar(invite: invite)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.green.opacity(0.18)))
                    .padding(.horizontal, 8)
                    .padding(.bottom, 2)
            }

            // The team room: a join row when I'm outside, the controls when I'm inside.
            if team.isInRoom {
                CallBar()
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.green.opacity(0.14)))
                    .padding(.horizontal, 8)
                    .padding(.bottom, 2)
            } else {
                TeamRoomRow()
                    .padding(.horizontal, 6)
            }
            if let notice = team.notice {
                Text(notice)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 4)
            }

            VStack(spacing: 0) {
                if search.trimmed.isEmpty {
                    TeamCodeRow()
                }
                ForEach(visibleTeammates) { teammate in
                    TeammateRow(teammate: teammate)
                }
                if visibleTeammates.isEmpty && !search.trimmed.isEmpty {
                    Text("No teammate matches “\(search.trimmed)”.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 10)
                }
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 8)

            if team.errorMessage != nil {
                ErrorText()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
            }
        }
        .task { await team.reloadTeam() }
    }
}

/// Settings gear on the left, app name centred.
private struct Header: View {
    @EnvironmentObject private var team: TeamStore
    @AppStorage(InkSettings.keepInkKey) private var keepInk = false

    var body: some View {
        ZStack {
            Text(TestTeammate.isActive ? "\(TestTeammate.name) (test)" : AppInfo.name)
                .font(.system(size: 14, weight: .bold))

            HStack {
                Menu {
                    if let me = team.me {
                        Text("You: \(me.name)")
                        Button("Change Name…") { team.isEditingName = true }
                        Divider()
                    }
                    Toggle("Do Not Disturb", isOn: $team.doNotDisturb)
                    Toggle("Keep Drawings Until Cleared", isOn: $keepInk)
                    Divider()
                    if !TestTeammate.isActive {
                        Button("Open Test Teammate") { team.openTestTeammate() }
                        Divider()
                    }
                    Button("Copy Team Code") { team.copyTeamCode() }
                    Button("New Team Code") { Task { await team.regenerateCode() } }
                    Button("Leave Team") { Task { await team.leaveTeam() } }
                    Divider()
                    Button("Quit \(AppInfo.name)") { NSApplication.shared.terminate(nil) }
                        .keyboardShortcut("q")
                } label: {
                    Image(systemName: team.doNotDisturb ? "moon.fill" : "gearshape")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Settings")

                Spacer()
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }
}

/// Replaces the search field while changing your name.
private struct RenameBar: View {
    @EnvironmentObject private var team: TeamStore
    @AppStorage("displayName") private var savedName = ""
    @State private var name = ""
    @State private var isSaving = false
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            TextField("Your name", text: $name)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .focused($isFocused)
                .onSubmit(save)
                .onExitCommand { team.isEditingName = false }
                .padding(.horizontal, 11)
                .frame(height: 34)
                .background(Capsule().fill(Color.primary.opacity(0.06)))
                .overlay(Capsule().strokeBorder(Color.accentColor.opacity(0.8), lineWidth: 2))

            Button("Save", action: save)
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmed.isEmpty || isSaving)
            Button("Cancel") { team.isEditingName = false }
                .buttonStyle(.link)
                .font(.system(size: 11))
        }
        .onAppear {
            name = team.me?.name ?? ""
            isFocused = true
        }
    }

    private func save() {
        let newName = name.trimmed
        guard !newName.isEmpty, !isSaving else { return }
        if newName == team.me?.name {
            team.isEditingName = false
            return
        }
        isSaving = true
        Task {
            await team.rename(to: newName)
            isSaving = false
            // Stay open if the server refused, so the error is visible next to the field.
            if team.me?.name == newName {
                savedName = newName
                team.isEditingName = false
            }
        }
    }
}

private struct SearchField: View {
    @Binding var text: String
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            TextField("Find Teammates", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .focused($isFocused)
        }
        .padding(.horizontal, 11)
        .frame(height: 34)
        .background(Capsule().fill(Color.primary.opacity(0.06)))
        .overlay(
            Capsule().strokeBorder(
                isFocused ? Color.accentColor.opacity(0.8) : Color.primary.opacity(0.12),
                lineWidth: isFocused ? 2 : 1
            )
        )
    }
}

/// Shows the team code; click to copy it for a teammate.
private struct TeamCodeRow: View {
    @EnvironmentObject private var team: TeamStore
    @State private var copied = false
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: copied ? "checkmark" : "person.badge.plus")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 40, height: 40)
                .background(Circle().fill(Color.primary.opacity(0.1)))

            VStack(alignment: .leading, spacing: 1) {
                Text(copied ? "Code Copied" : "Invite Teammates")
                    .font(.system(size: 15, weight: .medium))
                Text(team.teamCode.map { "Team code \($0)" } ?? "…")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .rowStyle(isHovered: isHovered)
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

/// The always-open voice room. Click to drop in; nobody gets rung.
private struct TeamRoomRow: View {
    @EnvironmentObject private var team: TeamStore
    @State private var isHovered = false

    private var inside: [Teammate] { team.roomTeammates }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "speaker.wave.2.fill")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(inside.isEmpty ? Color.secondary : Color.white)
                .frame(width: 40, height: 40)
                .background(Circle().fill(inside.isEmpty ? Color.primary.opacity(0.1) : Color.green))

            VStack(alignment: .leading, spacing: 1) {
                Text("Team Room")
                    .font(.system(size: 15, weight: .medium))
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)

            Text("Join")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(Capsule().fill(Color.green))
        }
        .rowStyle(isHovered: isHovered)
        .onHover { isHovered = $0 }
        .onTapGesture { team.joinRoom() }
        .help("Join the team's voice room")
    }

    private var subtitle: String {
        if inside.isEmpty { return "Empty · drop in any time" }
        let names = inside.map { $0.name.components(separatedBy: " ")[0] }
        return names.joined(separator: ", ") + (inside.count == 1 ? " is inside" : " are inside")
    }
}

private extension View {
    /// Shared padding and hover highlight for every row in the list.
    func rowStyle(isHovered: Bool) -> some View {
        self
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isHovered ? Color.primary.opacity(0.08) : .clear)
            )
            .contentShape(Rectangle())
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
        HStack(spacing: 12) {
            Avatar(teammate: teammate)

            VStack(alignment: .leading, spacing: 1) {
                Text(teammate.name)
                    .font(.system(size: 15, weight: .medium))
                    .lineLimit(1)
                Text(statusText)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            if canJoinThem {
                // They're in the team room: the button takes me in with them.
                JoinRoomButton()
            } else if canCallIn {
                // I'm in the room and they aren't: ask them to come in.
                CallInButton(teammate: teammate)
            } else if teammate.isOnline, !team.isInRoom,
                      isHovered || isTalking || team.walkiePeer == teammate.id
            {
                TalkButton(teammate: teammate)
            }
        }
        .rowStyle(isHovered: isHovered && (canJoinThem || isSharing))
        .opacity(teammate.isOnline ? 1 : 0.5)
        .onHover { isHovered = $0 }
        .onTapGesture {
            if isSharing {
                team.showSharedScreen(of: teammate)
            } else if canJoinThem {
                team.joinRoom()
            }
        }
        .help(helpText)
        .contextMenu {
            Button("Remove \(teammate.name) from Team") {
                Task { await team.remove(teammate) }
            }
        }
    }

    private var isSharing: Bool { team.sharingTeammates.contains(teammate.id) }
    /// They're in the room and I'm not: clicking their name drops me in with them.
    private var canJoinThem: Bool { !team.isInRoom && team.isInRoom(teammate) }
    /// I'm in the room, they're online and outside it.
    private var canCallIn: Bool { team.isInRoom && teammate.isOnline && !team.isInRoom(teammate) }

    private var helpText: String {
        if !teammate.isOnline { return "\(teammate.name) is offline" }
        if isSharing { return "Click to view \(teammate.name)'s screen" }
        if canJoinThem { return "Click to join \(teammate.name) in the team room" }
        if canCallIn { return "Click Call In to ask \(teammate.name) to join the room" }
        return "Click the button on the right to talk to \(teammate.name)"
    }

    private var statusText: String {
        if isTalking { return team.walkieReady ? "Talking · click the red button to stop" : "Connecting…" }
        if team.walkiePeer == teammate.id {
            return team.speaking.contains(teammate.id) ? "Speaking to you…" : "Walkie-talkie open · click to reply"
        }
        if isSharing { return "Sharing their screen · click to view" }
        if team.invitedTeammates.contains(teammate.id) { return "Calling them into the room…" }
        if team.isInRoom(teammate) {
            if team.isInRoom { return team.speaking.contains(teammate.id) ? "Speaking…" : "In the room with you" }
            return "In the team room · click to join"
        }
        return teammate.isOnline ? "Online" : "Offline"
    }
}

/// Shown on a teammate's row when I'm in the room and they aren't.
private struct CallInButton: View {
    @EnvironmentObject private var team: TeamStore
    let teammate: Teammate

    private var isCalling: Bool { team.invitedTeammates.contains(teammate.id) }

    var body: some View {
        Button { team.callIntoRoom(teammate) } label: {
            HStack(spacing: 4) {
                Image(systemName: "phone.fill")
                    .font(.system(size: 10, weight: .semibold))
                Text(isCalling ? "Calling…" : "Call In")
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(isCalling ? Color.secondary : Color.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(isCalling ? Color.primary.opacity(0.1) : Color.blue))
        }
        .buttonStyle(.plain)
        .disabled(isCalling)
        .help("Ask \(teammate.name) to join you in the team room")
    }
}

/// Someone in the room is calling me in.
private struct RoomInviteBar: View {
    @EnvironmentObject private var team: TeamStore
    let invite: RoomInvite

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(invite.fromName)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text("is calling you into the Team Room")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button("Not now") { team.dismissRoomInvite() }
                .buttonStyle(.link)
                .font(.system(size: 11))
            Button { team.acceptRoomInvite() } label: {
                Text("Join")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Color.green))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}

/// Shown on a teammate's row when they're in the team room.
private struct JoinRoomButton: View {
    @EnvironmentObject private var team: TeamStore

    var body: some View {
        Button { team.joinRoom() } label: {
            Text("Join")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(Capsule().fill(Color.green))
        }
        .buttonStyle(.plain)
        .help("Join them in the team room")
    }
}

/// Walkie-talkie: click to talk, click again to stop.
private struct TalkButton: View {
    @EnvironmentObject private var team: TeamStore
    let teammate: Teammate

    private var isTalking: Bool { team.talkingTo == teammate.id }

    var body: some View {
        Button {
            team.toggleTalking(to: teammate)
        } label: {
            Image(systemName: isTalking ? "phone.down.fill" : "phone.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isTalking ? Color.white : Color.secondary)
                .frame(width: 30, height: 30)
                .background(Circle().fill(isTalking ? Color.red : Color.primary.opacity(0.1)))
                .scaleEffect(isTalking ? 1.15 : 1)
                .animation(.easeOut(duration: 0.12), value: isTalking)
        }
        .buttonStyle(.plain)
        .help(isTalking ? "Click to stop talking" : "Click to talk to \(teammate.name)")
    }
}

private struct Avatar: View {
    let teammate: Teammate

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Circle()
                .fill(teammate.color.gradient)
                .frame(width: 40, height: 40)
                .overlay(
                    Text(teammate.initials)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                )
            if teammate.isOnline {
                Circle()
                    .fill(.green)
                    .frame(width: 11, height: 11)
                    .overlay(Circle().stroke(.background, lineWidth: 2))
            }
        }
    }
}

/// Shown at the top of the panel while I'm in the team room.
private struct CallBar: View {
    @EnvironmentObject private var team: TeamStore

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text(status)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            RoundButton(
                symbol: team.isMuted ? "mic.slash.fill" : "mic.fill",
                tint: team.isMuted ? .orange : nil,
                help: team.isMuted ? "Unmute" : "Mute"
            ) { team.toggleMute() }

            ShareButton()

            if team.isSharingScreen {
                RoundButton(
                    symbol: "pencil.tip",
                    tint: team.isDrawingOnOwnScreen ? .blue : nil,
                    help: team.isDrawingOnOwnScreen
                        ? "Stop drawing (Esc)"
                        : "Draw on your own screen"
                ) { team.toggleDrawMode() }

                RoundButton(symbol: "eraser", tint: nil, help: "Clear all drawings") {
                    team.clearDrawings()
                }
            }

            RoundButton(symbol: "phone.down.fill", tint: .red, help: "Leave the room") {
                team.leaveRoom()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var title: String { "Team Room" }

    private var status: String {
        guard let call = team.call else { return "" }
        if call.isConnecting { return "Connecting…" }
        if team.isDrawingOnOwnScreen { return "Drawing · Esc to stop" }
        if team.isSharingScreen { return "Sharing your screen" }
        let names = team.roomTeammates.map { $0.name.components(separatedBy: " ")[0] }
        let who = names.isEmpty ? "Just you so far" : "With " + names.joined(separator: ", ")
        return team.isMuted ? who + " · muted" : who
    }
}

/// Share button: a menu of screens and windows to share, or a stop button while sharing.
private struct ShareButton: View {
    @EnvironmentObject private var team: TeamStore
    @State private var sources: [ShareSource] = []

    private let symbol = "rectangle.inset.filled.and.person.filled"

    var body: some View {
        if team.isSharingScreen {
            RoundButton(symbol: symbol, tint: .green, help: "Stop sharing") {
                team.stopSharing()
            }
        } else {
            Menu {
                if !team.hasScreenRecordingPermission {
                    Button("1. Allow Screen Recording…") { team.requestScreenRecordingPermission() }
                    Button("2. Restart App (after switching it on)") { team.restartApp() }
                } else if sources.isEmpty {
                    Text("Loading…")
                } else {
                    ForEach(sources.filter(\.isDisplay)) { source in
                        Button(source.title) { team.startSharing(source) }
                    }
                    let windows = sources.filter { !$0.isDisplay }
                    if !windows.isEmpty {
                        Divider()
                        Text("Share One Window")
                        ForEach(windows) { source in
                            Button(source.title) { team.startSharing(source) }
                        }
                    }
                }
            } label: {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.primary)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Color.primary.opacity(0.1)))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Share your screen")
            .task { sources = await team.shareSources() }
            // Refresh as the pointer approaches, so the window list is current.
            .onHover { inside in
                if inside { Task { sources = await team.shareSources() } }
            }
        }
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

