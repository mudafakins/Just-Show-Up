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
            if team.isChoosingRingtone {
                RingtonePicker()
            } else {
            if team.isEditingName {
                RenameBar()
                    .padding(.horizontal, 12)
                    .padding(.bottom, 6)
            } else {
                SearchField(text: $search)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 6)
            }

            if let ring = team.incomingRing {
                RingBar(ring: ring)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.2)))
                    .padding(.horizontal, 8)
                    .padding(.bottom, 2)
            }

            // The rooms: controls for the one I'm in, a join row for the others.
            ForEach(Rooms.numbers, id: \.self) { number in
                if team.call?.number == number {
                    CallBar()
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.green.opacity(0.14)))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 1)
                } else {
                    RoomRow(number: number)
                        .padding(.horizontal, 6)
                }
            }
            Divider()
                .padding(.horizontal, 14)
                .padding(.vertical, 4)
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
                    if let me = team.me { MeRow(me: me) }
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
        }
        .overlay(alignment: .topTrailing) {
            if team.isShowingSoundboard && !team.isChoosingRingtone {
                ZStack(alignment: .topTrailing) {
                    // Clicking anywhere else closes it.
                    Color.black.opacity(0.001)
                        .onTapGesture { team.isShowingSoundboard = false }
                    SoundboardCard()
                        .padding(.top, 38)
                        .padding(.trailing, 8)
                }
            }
        }
        .task { await team.reloadTeam() }
    }
}

/// Settings gear on the left, app name centred.
private struct Header: View {
    @EnvironmentObject private var team: TeamStore
    @EnvironmentObject private var updater: Updater
    @AppStorage(InkSettings.keepInkKey) private var keepInk = false
    @AppStorage(Sounds.enabledKey) private var playSounds = true
    @AppStorage(Ringtone.styleKey) private var ringtone = ""
    @AppStorage(Updater.autoKey) private var autoUpdate = true

    private var ringtoneTitle: String {
        _ = ringtone  // redraw when it changes
        return Ringtone.current.title
    }

    var body: some View {
        ZStack {
            Text(AppInfo.name)
                .font(.system(size: 14, weight: .bold))

            HStack {
                Menu {
                    if let me = team.me {
                        Text("You: \(me.name)")
                        Button("Change Name…") { team.isEditingName = true }
                        Button(me.avatarPath == nil ? "Add Photo…" : "Change Photo…") { team.choosePhoto() }
                        if me.avatarPath != nil {
                            Button("Remove Photo") { Task { await team.removePhoto() } }
                        }
                        Divider()
                    }
                    Toggle("Keep Drawings Until Cleared", isOn: $keepInk)
                    Toggle("Sounds", isOn: $playSounds)
                    Button("Ringtone: \(ringtoneTitle)…") {
                        team.isShowingSoundboard = false
                        team.isChoosingRingtone = true
                    }
                    Divider()
                    Button("Copy Team Code") { team.copyTeamCode() }
                    Button("New Team Code") { Task { await team.regenerateCode() } }
                    Button("Leave Team") { Task { await team.leaveTeam() } }
                    Divider()
                    if let release = updater.available {
                        if team.call != nil {
                            Button("Update to \(release.version) (leave the room first)") {}
                                .disabled(true)
                        } else {
                            Button("Update to \(release.version)…") { Task { await updater.install() } }
                                .disabled(updater.isBusy)
                        }
                    } else {
                        Button("Check for Updates") { Task { await updater.check(userInitiated: true) } }
                            .disabled(updater.isBusy)
                    }
                    Toggle("Update Automatically", isOn: $autoUpdate)
                    Text("Version \(Updater.currentVersion)")
                    Divider()
                    Button("Quit \(AppInfo.name)") { NSApplication.shared.terminate(nil) }
                        .keyboardShortcut("q")
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Settings")
                // A dot on the gear when an update is ready (on the menu, since
                // menu labels drop overlays).
                .overlay(alignment: .topTrailing) {
                    if updater.available != nil {
                        Circle().fill(.red).frame(width: 7, height: 7).offset(x: 3, y: -2)
                            .allowsHitTesting(false)
                    }
                }

                Spacer()

                Button { team.isShowingSoundboard.toggle() } label: {
                    Image(systemName: "music.quarternote.3")
                        .font(.system(size: 13))
                        .foregroundStyle(team.isShowingSoundboard ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Soundboard")

                Button { team.doNotDisturb.toggle() } label: {
                    Image(systemName: team.doNotDisturb ? "moon.fill" : "moon")
                        .font(.system(size: 14))
                        .foregroundStyle(team.doNotDisturb ? AnyShapeStyle(Color.purple) : AnyShapeStyle(.secondary))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(team.doNotDisturb ? "Do Not Disturb is on. Click to turn it off." : "Do Not Disturb")
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }
}

/// The soundboard grid: click a sound to play it (for the whole room when in one).
private struct SoundboardCard: View {
    @EnvironmentObject private var team: TeamStore
    @State private var hovered: String?

    private let columns = Array(repeating: GridItem(.fixed(64), spacing: 4), count: 4)

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Soundboard")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Button { team.stopSoundboard() } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "stop.fill").font(.system(size: 9))
                        Text("Stop").font(.system(size: 11, weight: .medium))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.primary.opacity(0.1)))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(team.call == nil ? "Stop the sound" : "Stop the sound for everyone in the room")
            }
            Text(team.call.map { "Everyone in Room \($0.number) hears it." } ?? "Only you hear it. Join a room to play it for others.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            ScrollView {
                LazyVGrid(columns: columns, spacing: 4) {
                    ForEach(Soundboard.clips) { clip in
                        Button { team.playSoundboard(clip.id) } label: {
                            VStack(spacing: 2) {
                                Text(Soundboard.emoji(for: clip.title))
                                    .font(.system(size: 22))
                                Text(clip.title)
                                    .font(.system(size: 9))
                                    .lineLimit(2)
                                    .multilineTextAlignment(.center)
                                    .foregroundStyle(.primary)
                            }
                            .frame(width: 64, height: 58)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Color.primary.opacity(hovered == clip.id ? 0.14 : 0.06))
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .onHover { hovered = $0 ? clip.id : (hovered == clip.id ? nil : hovered) }
                        .help(clip.title)
                    }
                }
            }
            .frame(height: 252)
        }
        .padding(10)
        .frame(width: 292)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
        )
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.1)))
        .onExitCommand { team.isShowingSoundboard = false }
    }
}

/// Settings → Ringtone: every sound, with a preview when you point at one.
private struct RingtonePicker: View {
    @EnvironmentObject private var team: TeamStore
    @AppStorage(Ringtone.styleKey) private var saved = ""
    @State private var hovered: String?
    @State private var pendingPreview: Task<Void, Never>?

    private var selectedID: String {
        _ = saved  // redraw when it changes
        return Ringtone.current.id
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(action: close) {
                    HStack(spacing: 3) {
                        Image(systemName: "chevron.left")
                        Text("Back")
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Spacer()
            }
            .overlay(Text("Ringtone").font(.system(size: 12, weight: .semibold)))
            .padding(.horizontal, 14)
            .padding(.bottom, 4)

            Text("Point at a sound to hear it. Click to choose it.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.bottom, 4)

            ScrollView {
                VStack(spacing: 0) {
                    if !Ringtone.clips.isEmpty { section("Sounds", Ringtone.clips) }
                    section("Tones", Ringtone.tones)
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 8)
            }
            .frame(height: 400)
        }
        .onExitCommand(perform: close)
        .onDisappear {
            pendingPreview?.cancel()
            Ringtone.stopPreview()
        }
    }

    private func section(_ title: String, _ choices: [Ringtone.Choice]) -> some View {
        VStack(spacing: 0) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.top, 8)
                .padding(.bottom, 2)
            ForEach(choices) { row($0) }
        }
    }

    private func row(_ choice: Ringtone.Choice) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .opacity(choice.id == selectedID ? 1 : 0)
                .frame(width: 14)
            Text(choice.title)
                .font(.system(size: 13))
            Spacer()
            if hovered == choice.id {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(hovered == choice.id ? Color.primary.opacity(0.08) : .clear)
        )
        .contentShape(Rectangle())
        .onHover { inside in
            if inside {
                hovered = choice.id
                // A short wait, so sweeping the pointer down the list stays quiet.
                pendingPreview?.cancel()
                pendingPreview = Task {
                    try? await Task.sleep(for: .milliseconds(150))
                    guard !Task.isCancelled else { return }
                    Ringtone.playPreview(choice)
                }
            } else if hovered == choice.id {
                hovered = nil
                pendingPreview?.cancel()
                Ringtone.stopPreview()
            }
        }
        .onTapGesture { saved = choice.id }
    }

    private func close() {
        team.isChoosingRingtone = false
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

/// One always-open voice room. Click to drop in; nobody gets rung.
private struct RoomRow: View {
    @EnvironmentObject private var team: TeamStore
    let number: Int
    @State private var isHovered = false

    private var inside: [Teammate] { team.teammates(in: number) }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "speaker.wave.2.fill")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(inside.isEmpty ? Color.secondary : Color.white)
                .frame(width: 30, height: 30)
                .background(Circle().fill(inside.isEmpty ? Color.primary.opacity(0.1) : Color.green))

            VStack(alignment: .leading, spacing: 0) {
                Text(Rooms.name(number))
                    .font(.system(size: 13, weight: .medium))
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)

            if isHovered || !inside.isEmpty {
                JoinRoomButton(number: number)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isHovered ? Color.primary.opacity(0.08) : .clear)
        )
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture { team.joinRoom(number) }
        .help("Join \(Rooms.name(number))")
    }

    private var subtitle: String {
        if inside.isEmpty { return "Empty" }
        return inside.map { $0.name.components(separatedBy: " ")[0] }.joined(separator: ", ")
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

/// Me, at the top of the team: my photo, name and what I'm doing. Clicking it
/// changes my photo; right-click for the name and photo options.
private struct MeRow: View {
    @EnvironmentObject private var team: TeamStore
    let me: Teammate
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 12) {
            Avatar(teammate: me)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(me.name)
                        .font(.system(size: 15, weight: .medium))
                        .lineLimit(1)
                    Text("(You)")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                Text(status)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .rowStyle(isHovered: isHovered)
        .onHover { isHovered = $0 }
        .onTapGesture { team.choosePhoto() }
        .help(me.avatarPath == nil ? "Click to add your photo" : "Click to change your photo")
        .contextMenu {
            Button("Change Name…") { team.isEditingName = true }
            Button(me.avatarPath == nil ? "Add Photo…" : "Change Photo…") { team.choosePhoto() }
            if me.avatarPath != nil {
                Button("Remove Photo") { Task { await team.removePhoto() } }
            }
        }
    }

    private var status: String {
        if let call = team.call { return call.isConnecting ? "Joining \(Rooms.name(call.number))…" : "In \(Rooms.name(call.number))" }
        if team.doNotDisturb { return "Do Not Disturb" }
        return "Online"
    }
}

private struct TeammateRow: View {
    @EnvironmentObject private var team: TeamStore
    let teammate: Teammate
    @State private var isHovered = false

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

            if let theirs = joinableRoom {
                // They're in a room I'm not in: one click takes me there.
                JoinRoomButton(number: theirs)
            }
            if canRing {
                RingButton(teammate: teammate)
            }
        }
        .rowStyle(isHovered: isHovered && (joinableRoom != nil || isSharing))
        .opacity(teammate.isOnline ? 1 : 0.5)
        .onHover { isHovered = $0 }
        .onTapGesture {
            if isSharing {
                team.showSharedScreen(of: teammate)
            } else if let theirs = joinableRoom {
                team.joinRoom(theirs)
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
    private var theirRoom: Int? { team.room(of: teammate) }
    /// The room they're in, when it isn't mine.
    private var joinableRoom: Int? {
        guard let theirRoom, theirRoom != team.call?.number else { return nil }
        return theirRoom
    }
    private var canRing: Bool { teammate.isOnline && !team.isInMyRoom(teammate) }

    private var helpText: String {
        if !teammate.isOnline { return "\(teammate.name) is offline" }
        if isSharing { return "Click to view \(teammate.name)'s screen" }
        if let room = joinableRoom { return "Click to join \(teammate.name) in \(Rooms.name(room))" }
        if team.isInMyRoom(teammate) { return "\(teammate.name) is in the room with you" }
        return "Click the bell to call \(teammate.name) to a room"
    }

    private var statusText: String {
        if isSharing { return "Sharing their screen · click to view" }
        if let number = team.ringingTeammates[teammate.id] { return "Calling to \(Rooms.name(number))…" }
        if team.isInMyRoom(teammate) {
            return team.speaking.contains(teammate.id) ? "Speaking…" : "In the room with you"
        }
        if let theirRoom { return "In \(Rooms.name(theirRoom))" }
        return teammate.isOnline ? "Online" : "Offline"
    }
}

/// A teammate is calling me to a room: Accept or Decline.
private struct RingBar: View {
    @EnvironmentObject private var team: TeamStore
    let ring: IncomingRing

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "phone.arrow.down.left.fill")
                .font(.system(size: 13))
                .foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 1) {
                Text(ring.fromName)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text("is calling you to \(Rooms.name(ring.roomNumber))")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            RoundButton(symbol: "phone.down.fill", tint: .red, help: "Decline") {
                team.declineRing()
            }
            RoundButton(symbol: "phone.fill", tint: .green, help: "Accept") {
                team.acceptRing()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}

/// Green Join button for a room.
private struct JoinRoomButton: View {
    @EnvironmentObject private var team: TeamStore
    let number: Int

    var body: some View {
        Button { team.joinRoom(number) } label: {
            Text("Join")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(Capsule().fill(Color.green))
        }
        .buttonStyle(.plain)
        .help("Join \(Rooms.name(number))")
    }
}

/// The bell: choose a room to call a teammate to. While calling, it becomes a stop button.
private struct RingButton: View {
    @EnvironmentObject private var team: TeamStore
    let teammate: Teammate

    private var callingTo: Int? { team.ringingTeammates[teammate.id] }

    var body: some View {
        if callingTo != nil {
            Button { team.stopCalling(teammate) } label: {
                Image(systemName: "phone.down.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(Color.red))
            }
            .buttonStyle(.plain)
            .help("Stop calling \(teammate.name)")
        } else {
            Menu {
                ForEach(Rooms.numbers, id: \.self) { number in
                    Button("Call to \(Rooms.name(number))") { team.ring(teammate, to: number) }
                        .disabled(team.room(of: teammate) == number)
                }
            } label: {
                Image(systemName: "bell.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.secondary)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(Color.primary.opacity(0.1)))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Call \(teammate.name) to a room")
        }
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
                .overlay {
                    // Their photo, when they've set one (initials show while it loads).
                    if let url = teammate.avatarURL {
                        AsyncImage(url: url) { image in
                            image.resizable().scaledToFill()
                        } placeholder: {
                            Color.clear
                        }
                        .frame(width: 40, height: 40)
                        .clipShape(Circle())
                    }
                }
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

    private var title: String { team.call.map { Rooms.name($0.number) } ?? "Room" }

    private var status: String {
        guard let call = team.call else { return "" }
        if call.isConnecting { return "Connecting…" }
        if team.isDrawingOnOwnScreen { return "Drawing · Esc to stop" }
        if team.isSharingScreen { return "Sharing your screen" }
        let names = team.teammates(in: call.number).map { $0.name.components(separatedBy: " ")[0] }
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

