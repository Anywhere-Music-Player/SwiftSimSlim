import Foundation
import Observation

/// Reservations are acquired synchronously on the main actor before any await.
/// Each device has one owner, including while waiting for a heavy-operation slot.
@MainActor
@Observable
final class OperationCoordinator {
  struct Ticket: Sendable, Equatable, Identifiable {
    let id = UUID()
    let reservedAt = ContinuousClock.now
    let device: SimulatorDevice
    let action: SimulatorAction
  }

  struct Entry {
    let ticket: Ticket
    var stage: String
    var started: Date?
  }

  private(set) var entries: [String: Entry] = [:]
  let heavyLimit: Int
  @ObservationIgnored private var waiting: [(Ticket, CheckedContinuation<Void, Error>)] = []

  init(heavyLimit: Int = 2) {
    precondition(heavyLimit > 0)
    self.heavyLimit = heavyLimit
  }

  var runningCount: Int { entries.values.filter { $0.started != nil }.count }
  var queuedCount: Int { entries.count - runningCount }
  private var heavyCount: Int {
    entries.values.filter { $0.started != nil && $0.ticket.action.isHeavy }.count
  }

  func canReserve(_ devices: [SimulatorDevice]) -> Bool {
    !devices.isEmpty && devices.allSatisfy { entries[$0.udid] == nil }
  }

  func reserve(_ devices: [SimulatorDevice], action: SimulatorAction) throws -> [Ticket] {
    guard !devices.isEmpty, Set(devices.map(\.udid)).count == devices.count else {
      throw SimulatorError("Choose a nonempty selection of distinct simulators.")
    }
    guard canReserve(devices) else {
      throw SimulatorError(
        "One or more selected simulators already have an operation. Select free simulators to continue."
      )
    }
    return devices.map { device in
      let ticket = Ticket(device: device, action: action)
      entries[device.udid] = Entry(
        ticket: ticket, stage: "Queued — \(action.title.lowercased())", started: nil)
      return ticket
    }
  }

  func acquire(_ ticket: Ticket) async throws {
    try await withTaskCancellationHandler {
      try Task.checkCancellation()
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Void, Error>) in
        guard entries[ticket.device.udid]?.ticket.id == ticket.id else {
          continuation.resume(throwing: CancellationError())
          return
        }
        if !ticket.action.isHeavy || heavyCount < heavyLimit {
          start(ticket)
          continuation.resume()
        } else {
          waiting.append((ticket, continuation))
        }
      }
      try Task.checkCancellation()
    } onCancel: {
      Task { @MainActor [weak self] in self?.cancelWaiting(ticket) }
    }
  }

  private func start(_ ticket: Ticket) {
    entries[ticket.device.udid]?.started = Date()
    entries[ticket.device.udid]?.stage = ticket.action.title
  }

  func update(_ stage: String, for ticket: Ticket) {
    guard entries[ticket.device.udid]?.ticket.id == ticket.id,
      entries[ticket.device.udid]?.started != nil
    else { return }
    entries[ticket.device.udid]?.stage = stage
  }

  func finish(_ ticket: Ticket) {
    guard entries[ticket.device.udid]?.ticket.id == ticket.id else { return }
    entries.removeValue(forKey: ticket.device.udid)
    if let index = waiting.firstIndex(where: { $0.0.id == ticket.id }) {
      waiting.remove(at: index).1.resume(throwing: CancellationError())
    }
    while heavyCount < heavyLimit, !waiting.isEmpty {
      let (next, continuation) = waiting.removeFirst()
      guard entries[next.device.udid]?.ticket.id == next.id else {
        continuation.resume(throwing: CancellationError())
        continue
      }
      start(next)
      continuation.resume()
    }
  }

  private func cancelWaiting(_ ticket: Ticket) {
    // A running operation owns its reservation until backend recovery completes.
    guard entries[ticket.device.udid]?.ticket.id == ticket.id,
      entries[ticket.device.udid]?.started == nil
    else { return }
    finish(ticket)
  }
}

struct ServiceProfileSnapshot: Sendable, Equatable {
  let categories: Set<String>
  let labels: Set<String>
  let preserveBootState: Bool
  let disabledCount: Int
  var reviewedStates: [String: Set<String>] = [:]

  init(categories: Set<String>, labels: Set<String>, preserveBootState: Bool) throws {
    self.categories = categories
    self.labels = labels
    self.preserveBootState = preserveBootState
    disabledCount = try ServiceCatalog.desired(except: categories, keep: labels).count
  }
}

enum SimulatorAction: Sendable, Equatable {
  case slim(ServiceProfileSnapshot)
  case preview(ServiceProfileSnapshot)
  case restoreSaved(ServiceStateBackup)
  case restore(preserveBootState: Bool)
  case clean(categories: Set<String>, preserveBootState: Bool)
  case boot, shutdown, erase, delete, measure, analyze
  case rename(String)
  case clone(String)

  var isHeavy: Bool {
    switch self {
    case .rename, .shutdown: false
    default: true
    }
  }

  var isClone: Bool { if case .clone = self { true } else { false } }
  var title: String {
    switch self {
    case .slim: "Applying service profile…"
    case .preview: "Previewing service changes…"
    case .restoreSaved: "Restoring saved state…"
    case .restore: "Restoring services…"
    case .clean: "Cleaning disk data…"
    case .boot: "Booting simulator…"
    case .shutdown: "Shutting down simulator…"
    case .erase: "Erasing simulator…"
    case .delete: "Deleting simulator…"
    case .measure: "Measuring memory…"
    case .analyze: "Analyzing disk usage…"
    case .rename: "Renaming simulator…"
    case .clone: "Cloning simulator…"
    }
  }
}
