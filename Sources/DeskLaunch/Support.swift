import Foundation

/// Case-insensitive glob match (`*` = any run of characters, `?` = one character).
func globMatch(_ pattern: String, _ value: String) -> Bool {
    var regex = "^"
    for ch in pattern {
        switch ch {
        case "*": regex += ".*"
        case "?": regex += "."
        default: regex += NSRegularExpression.escapedPattern(for: String(ch))
        }
    }
    regex += "$"
    return value.range(of: regex, options: [.regularExpression, .caseInsensitive]) != nil
}

struct ProcessResult {
    var status: Int32
    var stdout: String
    var stderr: String
}

@discardableResult
func runProcess(_ executable: String, _ arguments: [String]) -> ProcessResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments

    let out = Pipe()
    let err = Pipe()
    process.standardOutput = out
    process.standardError = err

    do {
        try process.run()
    } catch {
        return ProcessResult(status: -1, stdout: "", stderr: "\(error)")
    }

    let outData = out.fileHandleForReading.readDataToEndOfFile()
    let errData = err.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()

    return ProcessResult(
        status: process.terminationStatus,
        stdout: String(decoding: outData, as: UTF8.self),
        stderr: String(decoding: errData, as: UTF8.self)
    )
}

func expandPath(_ path: String) -> String {
    (path as NSString).expandingTildeInPath
}

func wait(seconds: Double) {
    guard seconds > 0 else { return }
    Thread.sleep(forTimeInterval: seconds)
}

struct ConfigError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
