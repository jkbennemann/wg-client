import Foundation

struct HelperError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

enum Shell {
    struct Result {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    /// Runs a short-lived command via `posix_spawn`. Foundation's `Process` costs
    /// ~70-80ms per spawn (dispatch sources, KVO, a reaper thread) — and more in a
    /// launchd daemon — which dominated activation when multiplied across every
    /// ifconfig/route call. posix_spawn is a thin syscall wrapper (~1-5ms). stdout and
    /// stderr are merged into one pipe (these commands emit little, so no deadlock).
    @discardableResult
    static func run(_ path: String, _ args: [String], stdin input: String? = nil) throws -> Result {
        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }

        var outFDs: [Int32] = [0, 0]
        guard pipe(&outFDs) == 0 else { throw HelperError("pipe() failed") }
        let outRead = outFDs[0], outWrite = outFDs[1]

        var inRead: Int32 = -1, inWrite: Int32 = -1
        if input != nil {
            var inFDs: [Int32] = [0, 0]
            guard pipe(&inFDs) == 0 else {
                close(outRead); close(outWrite)
                throw HelperError("pipe() failed")
            }
            inRead = inFDs[0]; inWrite = inFDs[1]
            posix_spawn_file_actions_adddup2(&fileActions, inRead, 0)
            posix_spawn_file_actions_addclose(&fileActions, inWrite)
        } else {
            posix_spawn_file_actions_addopen(&fileActions, 0, "/dev/null", O_RDONLY, 0)
        }
        posix_spawn_file_actions_adddup2(&fileActions, outWrite, 1)
        posix_spawn_file_actions_adddup2(&fileActions, outWrite, 2)
        posix_spawn_file_actions_addclose(&fileActions, outRead)

        let argv: [UnsafeMutablePointer<CChar>?] = ([path] + args).map { strdup($0) } + [nil]
        let envp: [UnsafeMutablePointer<CChar>?] = [strdup("PATH=/usr/sbin:/sbin:/usr/bin:/bin"), nil]
        defer {
            for a in argv where a != nil { free(a) }
            for e in envp where e != nil { free(e) }
        }

        var pid: pid_t = 0
        let rc = posix_spawn(&pid, path, &fileActions, nil, argv, envp)
        close(outWrite)
        if inRead >= 0 { close(inRead) }
        guard rc == 0 else {
            close(outRead)
            if inWrite >= 0 { close(inWrite) }
            throw HelperError("posix_spawn(\(path)) failed: \(String(cString: strerror(rc)))")
        }

        if let input, inWrite >= 0 {
            _ = input.utf8CString.dropLast().withUnsafeBytes { raw in
                write(inWrite, raw.baseAddress, raw.count)
            }
            close(inWrite)
        }

        var output = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(outRead, &buffer, buffer.count)
            if n <= 0 { break }
            output.append(contentsOf: buffer[0..<n])
        }
        close(outRead)

        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
        let exitCode: Int32 = (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)

        let text = String(data: output, encoding: .utf8) ?? ""
        return Result(status: exitCode, stdout: text, stderr: "")
    }

    /// Runs several invocations of the same binary concurrently, ignoring individual
    /// failures (callers use this for best-effort, independent operations like route
    /// installation). Blocks until all have finished.
    static func runParallel(_ path: String, _ commands: [[String]]) {
        guard !commands.isEmpty else { return }
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "shell-parallel", attributes: .concurrent)
        for args in commands {
            group.enter()
            queue.async {
                _ = try? run(path, args)
                group.leave()
            }
        }
        group.wait()
    }

    /// Runs `body` concurrently for each item, blocking until all finish. Used for
    /// independent best-effort operations (e.g. route cutover with change/add fallback).
    static func runParallelForEach<T>(_ items: [T], _ body: @escaping (T) -> Void) {
        guard !items.isEmpty else { return }
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "shell-parallel-each", attributes: .concurrent)
        for item in items {
            group.enter()
            queue.async {
                body(item)
                group.leave()
            }
        }
        group.wait()
    }

    @discardableResult
    static func runChecked(_ path: String, _ args: [String], stdin input: String? = nil) throws -> String {
        let result = try run(path, args, stdin: input)
        guard result.status == 0 else {
            let detail = result.stderr.isEmpty ? result.stdout : result.stderr
            throw HelperError("\(URL(fileURLWithPath: path).lastPathComponent) \(args.joined(separator: " ")) failed: \(detail.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return result.stdout
    }
}

func log(_ message: String) {
    let formatter = ISO8601DateFormatter()
    print("[\(formatter.string(from: Date()))] \(message)")
    fflush(stdout)
}
