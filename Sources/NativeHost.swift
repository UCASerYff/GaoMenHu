import Foundation
import Darwin

@main struct NativeHost {
    static func main() {
        signal(SIGPIPE, SIG_IGN)
        let resource = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/extension-id.txt")
        guard let id = try? String(contentsOf: resource, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
              CommandLine.arguments.dropFirst().contains("chrome-extension://\(id)/") else { exit(1) }
        guard let parent = processPath(getppid()) else { exit(1) }
        let browser: String
        if parent.contains("/Google Chrome.app/") { browser = "chrome" }
        else if parent.contains("/Microsoft Edge.app/") { browser = "edge" }
        else { exit(1) }
        while var request = readFrame(STDIN_FILENO) {
            request["browser"] = browser
            request["extension"] = id
            var response = exchangeWithApp(request)
            response["rid"] = request["rid"]
            if !writeFrame(STDOUT_FILENO, object: response) { break }
        }
    }
}
