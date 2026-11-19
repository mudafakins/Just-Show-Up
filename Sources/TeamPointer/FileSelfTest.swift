import AppKit

/// `TeamPointer --file-selftest <file>...`: sends the files between two copies of the
/// transfer engine on this Mac, over a real WebRTC connection, and checks they arrive
/// intact. No UI, no Supabase. Used while developing file sending.
@MainActor
enum FileSelfTest {
    static func runIfAsked() {
        let args = CommandLine.arguments
        guard let flag = args.firstIndex(of: "--file-selftest") else { return }
        let urls = args[(flag + 1)...].map { URL(fileURLWithPath: $0) }
        let alice = FileTransfers(), bob = FileTransfers()
        let aliceID = UUID(), bobID = UUID()
        alice.myID = { aliceID }; alice.myName = { "Alice Test" }
        bob.myID = { bobID }; bob.myName = { "Bob" }
        // Signals go straight across, like the team channel would carry them.
        alice.sendSignal = { signal in await MainActor.run { bob.receive(signal) } }
        bob.sendSignal = { signal in await MainActor.run { alice.receive(signal) } }
        var finished = false
        alice.onMessage = { print("alice:", $0); if $0.hasPrefix("Sent") || $0.contains("intact") || $0.contains("Couldn't") { finished = true } }
        bob.onMessage = { print("bob:", $0) }
        let start = Date()
        alice.send(urls, to: Teammate(id: bobID, name: "Bob", isOnline: true, colorIndex: 0))
        Task { @MainActor in
            // Bob says Save as soon as the offer shows up.
            while bob.incoming.isEmpty { try? await Task.sleep(for: .milliseconds(50)) }
            bob.accept(bob.incoming[0].id)
            while !finished && Date().timeIntervalSince(start) < 120 { try? await Task.sleep(for: .milliseconds(100)) }
            try? await Task.sleep(for: .milliseconds(300))
            print("saved:", bob.lastSaved?.path ?? "nothing", String(format: "in %.1fs", Date().timeIntervalSince(start)))
            exit(bob.lastSaved == nil ? 1 : 0)
        }
    }
}
