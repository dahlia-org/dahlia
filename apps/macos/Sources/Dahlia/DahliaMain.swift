/// Starts the app, or runs `--install-pi` without opening it so `pi update` can call Dahlia.
@main
enum DahliaMain {
    @MainActor
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.first == PiInstaller.commandLineFlag {
            PiInstaller.runCommandLine(Array(arguments.dropFirst()))
        }
        DahliaApp.main()
    }
}
