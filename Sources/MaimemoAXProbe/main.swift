import AppKit
import MaimemoAXCore

@main
@MainActor
struct MaimemoAXProbe {
    static func main() {
        let watch = CommandLine.arguments.contains("--watch")
        let dump = CommandLine.arguments.contains("--dump")
        let reader = MaimemoAccessibilityReader()

        repeat {
            let snapshot = reader.scan()
            print("--- Maimemo AX probe \(snapshot.scannedAt.formatted(.iso8601)) ---")
            print("appFound=\(snapshot.appFound) trusted=\(snapshot.isTrusted) nodes=\(snapshot.nodeCount)")
            print("word=\(snapshot.word ?? "<none>")")
            print(snapshot.diagnostic)
            if dump {
                for (index, candidate) in snapshot.candidates.enumerated() {
                    print("candidate[\(index)] \(candidate.text) score=\(String(format: "%.1f", candidate.score)) role=\(candidate.role) source=\(candidate.sourceAttribute) frame=\(candidate.frame)")
                }
            }
            if watch {
                RunLoop.main.run(until: Date().addingTimeInterval(0.8))
            }
        } while watch
    }
}
