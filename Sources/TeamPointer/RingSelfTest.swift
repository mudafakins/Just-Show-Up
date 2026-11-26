#if DEBUG
import Foundation
import Supabase

/// `--ring-selftest`: a pretend teammate on a second connection to the team channel
/// checks that rings repeat until acknowledged, that "couldn't reach" shows when no
/// one answers, that repeats don't ring twice or after a cancel, and that a caller
/// briefly dropping out of presence doesn't stop my ring. Joins Room 3 for it.
@MainActor
enum RingSelfTest {
    static func runIfAsked(team: TeamStore) {
        guard CommandLine.arguments.contains("--ring-selftest") else { return }
        Task { @MainActor in
            var failures = 0
            func check(_ ok: Bool, _ what: String) {
                print("RING-SELFTEST \(ok ? "PASS" : "FAIL"): \(what)")
                if !ok { failures += 1 }
            }
            func wait(_ s: Double) async { try? await Task.sleep(for: .seconds(s)) }

            for _ in 0 ..< 60 where team.me == nil || team.debugTeamTopic == nil { await wait(0.5) }
            guard let me = team.me, let topic = team.debugTeamTopic, let config = AppConfig.load() else {
                print("RING-SELFTEST not signed in"); exit(2)
            }
            team.doNotDisturb = false
            team.joinRoom(3)
            for _ in 0 ..< 40 where team.call?.isConnecting != false { await wait(0.5) }
            check(team.call?.number == 3, "joined Room 3")

            let fakeID = UUID()
            let fake = Teammate(id: fakeID, name: "Ring Test", isOnline: true, colorIndex: 0, avatarPath: nil)
            let client = makeSupabaseClient(config)
            let channel = client.realtimeV2.channel(topic) { $0.presence.key = fakeID.uuidString.lowercased() }
            let stream = channel.broadcastStream(event: "call")
            try? await channel.subscribeWithError()

            var received: [CallSignal] = []
            var answerRings = false
            var dropFirstRing = true
            let listener = Task { @MainActor in
                for await message in stream {
                    guard let payload = message["payload"]?.objectValue,
                          let signal = try? payload.decode(as: CallSignal.self), signal.to == fakeID
                    else { continue }
                    received.append(signal)
                    if signal.kind == .ring, answerRings {
                        if dropFirstRing { dropFirstRing = false; continue }
                        await say(.ringing, room: signal.roomNumber, callID: signal.callID)
                    }
                }
            }
            func say(_ kind: CallSignal.Kind, room: Int?, callID: String?) async {
                let signal = CallSignal(kind: kind, from: fakeID, to: me.id, room: "", name: "Ring Test",
                                        roomNumber: room, callID: callID)
                try? await channel.broadcast(event: "call", message: signal)
            }
            func count(_ kind: CallSignal.Kind) -> Int { received.filter { $0.kind == kind }.count }

            // A. The first ring is lost: it is repeated, then stops repeating once acknowledged.
            answerRings = true
            team.ring(fake, to: 3)
            await wait(10)
            check(count(.ring) == 2, "lost ring was repeated, then stopped once acknowledged (rings: \(count(.ring)))")
            check(team.ringingTeammates[fakeID] == 3 && team.notice == nil, "still calling after acknowledgement")
            let callA = received.last { $0.kind == .ring }?.callID
            await say(.decline, room: 3, callID: callA)
            await wait(1.5)
            check(team.ringingTeammates[fakeID] == nil && team.notice?.contains("declined") == true,
                  "decline ends the call (\(team.notice ?? "-"))")

            // B. Nobody answers at all: "couldn't reach" after about 8 seconds.
            received = []
            answerRings = false
            team.ring(fake, to: 3)
            await wait(10)
            check(count(.ring) == 3, "unanswered ring sent 3 times (\(count(.ring)))")
            check(count(.cancel) == 1, "caller sent cancel")
            check(team.ringingTeammates[fakeID] == nil && team.notice?.contains("Couldn't reach") == true,
                  "shows couldn't reach (\(team.notice ?? "-"))")

            // C. Being called: repeats ring once, each is acknowledged; after cancel a late repeat stays silent.
            received = []
            let callC = UUID().uuidString
            for _ in 0 ..< 3 { await say(.ring, room: 2, callID: callC); await wait(1) }
            await wait(1)
            check(team.incomingRing?.callID == callC, "incoming call is ringing")
            check(count(.ringing) == 3, "each repeat acknowledged (\(count(.ringing)))")
            await say(.cancel, room: 2, callID: callC)
            await wait(1.5)
            check(team.incomingRing == nil, "cancel stops ringing")
            await say(.ring, room: 2, callID: callC)
            await wait(1.5)
            check(team.incomingRing == nil, "late repeat after cancel doesn't ring")

            // D. The caller drops out of presence for a moment: keep ringing. Gone for good: stop.
            try? await channel.track(PresenceState(userID: fakeID.uuidString.lowercased(), room: nil))
            await wait(2)
            let callD = UUID().uuidString
            await say(.ring, room: 2, callID: callD)
            await wait(1)
            await channel.untrack()
            await wait(1.5)
            try? await channel.track(PresenceState(userID: fakeID.uuidString.lowercased(), room: nil))
            await wait(6)
            check(team.incomingRing?.callID == callD, "brief dropout keeps ringing")
            await channel.untrack()
            await wait(7)
            check(team.incomingRing == nil, "caller gone for good stops ringing")

            listener.cancel()
            await client.realtimeV2.removeChannel(channel)
            team.leaveRoom()
            await wait(1)
            print("RING-SELFTEST done, \(failures) failed")
            exit(failures == 0 ? 0 : 1)
        }
    }
}
#endif
