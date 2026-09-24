import Foundation

let args = Array(CommandLine.arguments.dropFirst())
if args.isEmpty {
    MenuApp.main()
} else {
    exit(Headless.run(args))
}
