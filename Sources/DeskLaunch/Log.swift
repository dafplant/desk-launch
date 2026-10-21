import Foundation

enum Log {
    static var verbose = false
    static var color = isatty(STDOUT_FILENO) == 1

    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    private static func paint(_ code: String, _ text: String) -> String {
        color ? "\u{1B}[\(code)m\(text)\u{1B}[0m" : text
    }

    private static var prefix: String {
        paint("2", stamp.string(from: Date()))
    }

    static func info(_ message: String) {
        print("\(prefix)  \(message)")
    }

    static func action(_ message: String) {
        print("\(prefix)  \(paint("36", "→")) \(message)")
    }

    static func ok(_ message: String) {
        print("\(prefix)  \(paint("32", "✓")) \(message)")
    }

    static func skip(_ message: String) {
        print("\(prefix)  \(paint("33", "–")) \(message)")
    }

    static func warn(_ message: String) {
        let line = "\(prefix)  \(paint("33", "warning:")) \(message)\n"
        FileHandle.standardError.write(Data(line.utf8))
    }

    static func fail(_ message: String) {
        let line = "\(prefix)  \(paint("31", "error:")) \(message)\n"
        FileHandle.standardError.write(Data(line.utf8))
    }

    static func debug(_ message: String) {
        guard verbose else { return }
        print("\(prefix)  \(paint("2", message))")
    }

    static func raw(_ text: String) {
        print(text)
    }

    static func heading(_ text: String) {
        print("")
        print(paint("1", text))
    }
}
