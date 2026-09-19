import Foundation
import Darwin

public struct ProcessFailure: Error, LocalizedError, Sendable {
    public let command: [String]
    public let status: Int32?
    public let stdout: String
    public let stderr: String
    public let reason: String
    public var errorDescription: String? {
        "\(reason)\nCommand: \(command.map { String(reflecting: $0) }.joined(separator: " "))\nstdout:\n\(stdout)\nstderr:\n\(stderr)"
    }
}

struct ProcessOutput {
    let data: Data
    let stderr: String
    let status: Int32
    var text: String { String(decoding: data, as: UTF8.self) }
}

enum ProcessRunner {
    /// File-backed capture cannot deadlock when either output stream fills a pipe.
    static func run(_ executable: String, _ arguments: [String], directory: String,
                    timeout: TimeInterval = 60, accepted: Set<Int32> = [0], input: Data? = nil) throws -> ProcessOutput {
        let manager = FileManager.default
        let temporary = manager.temporaryDirectory.appendingPathComponent("slopdiff-process-\(UUID())")
        try manager.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: temporary) }
        let outURL = temporary.appendingPathComponent("stdout")
        let errURL = temporary.appendingPathComponent("stderr")
        manager.createFile(atPath: outURL.path, contents: nil)
        manager.createFile(atPath: errURL.path, contents: nil)
        let stdout = try FileHandle(forWritingTo: outURL)
        let stderr = try FileHandle(forWritingTo: errURL)
        defer { try? stdout.close(); try? stderr.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [executable] + arguments
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        var environment = ProcessInfo.processInfo.environment
        // GUI launches do not inherit the user's shell PATH.
        environment["PATH"] = (environment["PATH"] ?? "/usr/bin:/bin") + ":/opt/homebrew/bin:/usr/local/bin"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        environment["GH_PROMPT_DISABLED"] = "1"
        environment["LC_ALL"] = "C"
        process.environment = environment
        var stdin: FileHandle?
        if let input {
            let inputURL = temporary.appendingPathComponent("stdin")
            try input.write(to: inputURL)
            stdin = try FileHandle(forReadingFrom: inputURL)
        }
        defer { try? stdin?.close() }
        process.standardInput = stdin ?? FileHandle.nullDevice
        process.standardOutput = stdout
        process.standardError = stderr
        do { try process.run() }
        catch {
            throw ProcessFailure(command: [executable] + arguments, status: nil, stdout: "", stderr: error.localizedDescription, reason: "Could not start command.")
        }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        let timedOut = process.isRunning
        if timedOut {
            // Foundation normally starts a separate group; terminate helpers such as ssh too.
            let pid = process.processIdentifier
            let recipient = getpgid(pid) == pid ? -pid : pid
            kill(recipient, SIGTERM)
            let grace = ProcessInfo.processInfo.systemUptime + 0.25
            while process.isRunning && ProcessInfo.processInfo.systemUptime < grace { Thread.sleep(forTimeInterval: 0.01) }
            if process.isRunning { kill(recipient, SIGKILL) }
        }
        process.waitUntilExit()
        let output = ProcessOutput(data: try Data(contentsOf: outURL),
                                   stderr: String(decoding: try Data(contentsOf: errURL), as: UTF8.self),
                                   status: process.terminationStatus)
        guard !timedOut && accepted.contains(output.status) else {
            throw ProcessFailure(command: [executable] + arguments, status: output.status,
                                 stdout: output.text, stderr: output.stderr,
                                 reason: timedOut ? "Command timed out after \(timeout) seconds." : "Command failed (exit \(output.status)).")
        }
        return output
    }
}
