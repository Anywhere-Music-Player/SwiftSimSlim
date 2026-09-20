import Darwin
import Foundation

struct OperationEvent: Sendable {
  enum Kind: Sendable { case stage, command, output, finished }
  let kind: Kind
  let udid: String?
  let message: String
}
typealias OperationReporter = @Sendable (OperationEvent) -> Void

struct SimulatorError: LocalizedError, Sendable {
  let message: String
  let isTimeout: Bool
  init(_ message: String, isTimeout: Bool = false) {
    self.message = message
    self.isTimeout = isTimeout
  }
  var errorDescription: String? { message }
}

struct CommandResult: Sendable {
  let data: Data
  let errorData: Data
  let status: Int32
  var text: String {
    String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
  }
  var diagnostic: String {
    String(decoding: errorData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
  }
  func checked() throws -> CommandResult {
    guard status == 0 else {
      throw SimulatorError("Command exited with status \(status).\n\(diagnostic)\n\(text)")
    }
    return self
  }
}

struct CommandRunner: Sendable {
  var report: OperationReporter = { _ in }
  var executor: (@Sendable (String, [String]) async throws -> CommandResult)?

  func run(
    _ executable: String, _ arguments: [String], timeout: TimeInterval = 60,
    udid: String? = nil, log: Bool = true
  ) async throws -> CommandResult {
    if let executor { return try await executor(executable, arguments) }
    let eventReporter: OperationReporter
    if log { eventReporter = report } else { eventReporter = { _ in } }
    let execution = CommandExecution(
      executable: executable, arguments: arguments,
      timeout: timeout, udid: udid, report: eventReporter)
    return try await withTaskCancellationHandler {
      try Task.checkCancellation()
      return try await withCheckedThrowingContinuation { execution.start($0) }
    } onCancel: {
      execution.cancel()
    }
  }
}

/// Every mutable property is confined to `queue`. Process completion and pipe
/// readiness schedule brief callbacks; no worker thread waits for a process.
private final class CommandExecution: @unchecked Sendable {
  private let queue = DispatchQueue(label: "SwiftSimSlim.command", qos: .userInitiated)
  private let process = Process()
  private let pipes = [Pipe(), Pipe()]
  private let timeout: TimeInterval
  private let udid: String?
  private let report: OperationReporter
  private let command: String
  private var readers: [DispatchSourceRead?] = [nil, nil]
  private var buffers = [Data(), Data()]
  private var readClosed = [false, false]
  private var continuation: CheckedContinuation<CommandResult, Error>?
  private var deadline: DispatchWorkItem?
  private var cancelled = false
  private var timedOut = false
  private var completed = false
  private var readError: Error?
  private var outputTooLarge = false

  init(
    executable: String, arguments: [String], timeout: TimeInterval,
    udid: String?, report: @escaping OperationReporter
  ) {
    self.timeout = timeout
    self.udid = udid
    self.report = report
    command = ([executable] + arguments).map { argument in
      argument.contains(where: { $0.isWhitespace || "'\"$;".contains($0) })
        ? "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'" : argument
    }.joined(separator: " ")
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardInput = FileHandle.nullDevice
    // Retain explicit ownership of closing the parent's write handles.
    process.standardOutput = pipes[0].fileHandleForWriting
    process.standardError = pipes[1].fileHandleForWriting
  }

  func start(_ continuation: CheckedContinuation<CommandResult, Error>) {
    queue.async { [self] in
      self.continuation = continuation
      if cancelled {
        finish(error: CancellationError())
        return
      }
      report(.init(kind: .command, udid: udid, message: command))
      do {
        for index in 0..<2 {
          let descriptor = pipes[index].fileHandleForReading.fileDescriptor
          let flags = fcntl(descriptor, F_GETFL)
          guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
          }
          let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
          source.setEventHandler { [self] in drain(index) }
          let handle = pipes[index].fileHandleForReading
          source.setCancelHandler { try? handle.close() }
          readers[index] = source
          source.activate()
        }
        process.terminationHandler = { [self] _ in queue.async { [self] in finish() } }
        try process.run()
        for pipe in pipes { try? pipe.fileHandleForWriting.close() }
        let work = DispatchWorkItem { [self] in
          guard !completed else { return }
          timedOut = true
          terminate()
        }
        deadline = work
        queue.asyncAfter(deadline: .now() + timeout, execute: work)
      } catch { finish(error: error) }
    }
  }

  func cancel() {
    queue.async { [self] in
      guard !completed else { return }
      cancelled = true
      terminate()
    }
  }

  private func terminate() {
    guard process.isRunning else { return }
    process.terminate()
    queue.asyncAfter(deadline: .now() + 2) { [self] in
      if !completed && process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }
  }

  private func drain(_ index: Int) {
    guard !readClosed[index] else { return }
    let descriptor = pipes[index].fileHandleForReading.fileDescriptor
    var bytes = [UInt8](repeating: 0, count: 16_384)
    while true {
      let count = read(descriptor, &bytes, bytes.count)
      if count > 0 {
        let chunk = Data(bytes.prefix(count))
        if buffers[index].count + count <= 16 * 1024 * 1024 {
          buffers[index].append(chunk)
        } else {
          outputTooLarge = true
        }
        report(.init(kind: .output, udid: udid, message: String(decoding: chunk, as: UTF8.self)))
      } else if count == 0 {
        closeReader(index)
        return
      } else if errno == EINTR {
        continue
      } else if errno == EAGAIN {
        return
      } else {
        readError = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        closeReader(index)
        terminate()
        return
      }
    }
  }

  private func closeReader(_ index: Int) {
    readClosed[index] = true
    if let reader = readers[index] {
      reader.cancel()
    } else {
      try? pipes[index].fileHandleForReading.close()
    }
  }

  private func finish(error: Error? = nil) {
    guard !completed else { return }
    completed = true
    deadline?.cancel()
    deadline = nil
    // Completion is observed before this final drain, so trailing bytes cannot
    // race an EAGAIN/exit check. Inherited pipes never keep us waiting for EOF.
    for index in 0..<2 {
      if error == nil { drain(index) }
      closeReader(index)
    }
    readers = [nil, nil]
    for pipe in pipes { try? pipe.fileHandleForWriting.close() }
    process.terminationHandler = nil
    let failure: Error?
    if cancelled {
      failure = CancellationError()
    } else if timedOut {
      failure = SimulatorError(
        "Command timed out after \(Int(timeout)) seconds.\n\(command)", isTimeout: true)
    } else if outputTooLarge {
      failure = SimulatorError("Command output exceeded the 16 MB limit.\n\(command)")
    } else {
      failure = error ?? readError
    }
    if let failure {
      report(.init(kind: .finished, udid: udid, message: failure.localizedDescription))
      continuation?.resume(throwing: failure)
    } else {
      let result = CommandResult(
        data: buffers[0], errorData: buffers[1], status: process.terminationStatus)
      report(.init(kind: .finished, udid: udid, message: "Exit \(result.status)"))
      continuation?.resume(returning: result)
    }
    continuation = nil
  }
}
