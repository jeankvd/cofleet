import CoFleetCore
import Foundation

public protocol CodexProcessTransport: Sendable {
    func start() async throws -> AsyncThrowingStream<Data, Error>
    func send(_ frame: Data) async throws
    func stop() async
}

public enum CodexProcessError: Error, LocalizedError, Sendable {
    case unavailableOnPlatform
    case alreadyRunning
    case notRunning
    case launchFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unavailableOnPlatform: "The local Codex process is only available on macOS hosts."
        case .alreadyRunning: "The Codex app-server process is already running."
        case .notRunning: "The Codex app-server process is not running."
        case let .launchFailed(message): "Codex app-server failed to launch: \(message)"
        }
    }
}

#if os(macOS)
public actor CodexStdioProcess: CodexProcessTransport {
    private let executableURL: URL
    private let arguments: [String]
    private var process: Process?
    private var inputHandle: FileHandle?
    private var readerTask: Task<Void, Never>?

    public init(
        executableURL: URL = URL(fileURLWithPath: "/usr/bin/env"),
        arguments: [String] = ["codex", "app-server"]
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
    }

    public func start() throws -> AsyncThrowingStream<Data, Error> {
        guard process == nil else { throw CodexProcessError.alreadyRunning }
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors

        let (stream, continuation) = AsyncThrowingStream.makeStream(of: Data.self)
        let outputHandle = output.fileHandleForReading
        do {
            try process.run()
        } catch {
            throw CodexProcessError.launchFailed(error.localizedDescription)
        }
        self.process = process
        inputHandle = input.fileHandleForWriting
        readerTask = Task.detached {
            var buffer = Data()
            while !Task.isCancelled {
                let chunk = outputHandle.availableData
                if chunk.isEmpty { break }
                buffer.append(chunk)
                while let newline = buffer.firstIndex(of: 0x0A) {
                    let frame = buffer.prefix(upTo: newline)
                    buffer.removeSubrange(...newline)
                    if !frame.isEmpty { continuation.yield(Data(frame)) }
                }
            }
            if !buffer.isEmpty { continuation.yield(buffer) }
            continuation.finish()
        }
        continuation.onTermination = { _ in
            if process.isRunning { process.terminate() }
        }
        return stream
    }

    public func send(_ frame: Data) throws {
        guard let inputHandle else { throw CodexProcessError.notRunning }
        var line = frame
        if line.last != 0x0A { line.append(0x0A) }
        try inputHandle.write(contentsOf: line)
    }

    public func stop() {
        readerTask?.cancel()
        readerTask = nil
        try? inputHandle?.close()
        inputHandle = nil
        if process?.isRunning == true { process?.terminate() }
        process = nil
    }
}
#else
public actor CodexStdioProcess: CodexProcessTransport {
    public init() {}
    public func start() throws -> AsyncThrowingStream<Data, Error> { throw CodexProcessError.unavailableOnPlatform }
    public func send(_ frame: Data) throws { throw CodexProcessError.unavailableOnPlatform }
    public func stop() {}
}
#endif

public enum CodexJSONRPCCodec {
    public static func encode<Params: Encodable & Sendable>(_ request: CodexRPCRequest<Params>) throws -> Data {
        try JSONEncoder().encode(request)
    }

    public static func decode<Result: Decodable & Sendable>(
        _ type: Result.Type,
        from frame: Data
    ) throws -> CodexRPCResponse<Result> {
        try JSONDecoder().decode(CodexRPCResponse<Result>.self, from: frame)
    }
}
