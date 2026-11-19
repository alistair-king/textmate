import AppKit

/// Turns files dropped on a terminal into the text a shell user would type for them.
enum TerminalFileDrop {
    private static var readOptions: [NSPasteboard.ReadingOptionKey: Any] { [.urlReadingFileURLsOnly: true] }

    static func canAccept(_ pasteboard: NSPasteboard) -> Bool {
        pasteboard.canReadObject(forClasses: [NSURL.self], options: readOptions)
    }

    static func fileURLs(from pasteboard: NSPasteboard) -> [URL] {
        (pasteboard.readObjects(forClasses: [NSURL.self], options: readOptions) as? [URL] ?? []).filter(\.isFileURL)
    }

    /// Shell-quoted paths separated by spaces, with a trailing space so the next argument can be typed straight away.
    static func text(for urls: [URL]) -> String? {
        let paths = urls.map { quote($0.path) }
        return paths.isEmpty ? nil : paths.joined(separator: " ") + " "
    }

    /// Backslash-escapes shell metacharacters the way Terminal does, which sh, bash, zsh and fish all read back verbatim.
    /// A path with control characters uses zsh/bash `$'…'` quoting with `\xHH` escapes instead: the paste path
    /// replaces raw control bytes and may send a newline as Enter, so only printable text may reach the terminal.
    static func quote(_ path: String) -> String {
        if path.unicodeScalars.contains(where: isControl) {
            var result = "$'"
            for scalar in path.unicodeScalars {
                switch scalar {
                case "\\", "'": result += "\\" + String(scalar)
                case _ where isControl(scalar): result += String(format: "\\x%02X", scalar.value)
                default: result.unicodeScalars.append(scalar)
                }
            }
            return result + "'"
        }
        var result = ""
        for scalar in path.unicodeScalars {
            if scalar.isASCII && !isSafe(scalar) { result.append("\\") }
            result.unicodeScalars.append(scalar)
        }
        return result
    }

    /// C0 controls and DEL; a C1 control is sent as UTF-8, which the paste path leaves alone.
    private static func isControl(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value < 0x20 || scalar.value == 0x7F
    }

    private static func isSafe(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar {
        case "a"..."z", "A"..."Z", "0"..."9", "/", ".", "_", "-", "+", ",", ":", "@", "%", "=": true
        default: false
        }
    }
}
