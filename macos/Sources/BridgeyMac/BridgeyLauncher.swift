import Foundation

/// The program entry. `BridgeyMac --bench quick|full` runs the integrity benchmark without any
/// window, prints the JSON report and exits. `BridgeyMac --update-all [--json]` hands "check now,
/// then Update all" to the running app (starting it if needed), prints the plan and the result and
/// exits (UpdateControl.swift). `BridgeyMac --handoff off|on|status [--json]` turns Apple Handoff off or back on
/// through the running app, or by itself when the app is not running; it never starts the app
/// (HandoffControl.swift). Every other launch starts the app as before.
@main
enum BridgeyLauncher {
    static func main() {
        let args = CommandLine.arguments
        if args.contains("--local-codes") {
            exit(LocalAgentCodesCLI.run(arguments: args))
        }
        if args.contains("--update-all") {
            exit(UpdateControlCLI.run(arguments: args))
        }
        if args.contains("--handoff") {
            exit(HandoffControl.run(arguments: args))
        }
        if let at = args.firstIndex(of: "--bench") {
            let size = at + 1 < args.count ? args[at + 1] : "quick"
            exit(HashBenchmarkCLI.run(full: size == "full"))
        }
        BridgeyApp.main()
    }
}
