import CcinnOpenRTBKit
import Foundation
import Observation
import RTBKit

/// What the Client needs from the simulator: the session's network gate, its device and mode, and a way to show an
/// exchange. `AdSession` adopts it; tests use a recording stand-in.
@MainActor
protocol ClientSimulatorTarget: AnyObject {
    /// The window's network monitor: the request goes through its dispatch policy and appears in its Network log.
    var monitor: NetworkMonitor { get }
    /// The simulated device: its User-Agent goes with the request.
    var device: DeviceProfile { get }
    var mode: TrackingMode { get }
    /// Puts `request` and `response` into the editors (on `device`, when given) and renders when `render` is set.
    func loadExchange(request: String, response: String, device: DeviceProfile?, render: Bool) async
}

/// The Client tab of one main window (bid-client B4): the request being composed, the exchange it produced or that was
/// opened from the library, and Send, Cancel, Render, Save and Open.
///
/// - A response is shown on the device as soon as it arrives when it carries one (a 2xx with a body): in Real mode the
///   editors get it and the device waits for an explicit Render, so no tracker is sent without one.
/// - What the simulator gets is the body that was sent, never a draft edited while the request was in flight.
/// - Each Send starts a generation; a cancelled or superseded request never updates the tab.
@MainActor
@Observable
final class ClientModel {
    enum Phase: Equatable, Sendable {
        case idle
        case sending
        /// `exchange` holds the response (sent now, or opened from the library).
        case received
        case failed(String)
    }

    enum ExchangeOrigin: Equatable, Sendable {
        case sent
        case saved
    }

    var request = ClientRequest()
    /// The name the request is saved under; blank saves it under `SavedRequest.defaultName(for:)`.
    var name = ""
    private(set) var savedID: UUID?
    private(set) var exchange: ClientExchange?
    private(set) var exchangeOrigin: ExchangeOrigin?
    private(set) var phase: Phase = .idle
    /// A non-blocking note about the request just sent (a body that is not JSON).
    private(set) var sendWarning: String?
    /// What happened to the simulator after the last response or Render.
    private(set) var simulatorNote: String?

    @ObservationIgnored let library: SavedRequestLibrary
    @ObservationIgnored private let target: any ClientSimulatorTarget
    @ObservationIgnored private let now: @MainActor () -> Date
    @ObservationIgnored private var sendTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0

    init(target: any ClientSimulatorTarget, library: SavedRequestLibrary = .shared, now: @escaping @MainActor () -> Date = { Date() }) {
        self.target = target
        self.library = library
        self.now = now
    }

    // MARK: Derived

    var problems: [ClientRequest.Problem] { request.problems() }
    var canSend: Bool { phase != .sending && problems.isEmpty }
    var isSending: Bool { phase == .sending }
    var canRender: Bool { exchange?.response.carriesAResponseToRender == true }

    /// Something differs from the saved request (or, for a request never saved, there is something to save).
    var hasUnsavedChanges: Bool {
        guard let savedID, let saved = library.request(id: savedID) else { return !request.trimmedURL.isEmpty || exchange != nil }
        return saved.request != request || saved.exchange != exchange || saved.name != effectiveName
    }

    var effectiveName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? SavedRequest.defaultName(for: request) : trimmed
    }

    // MARK: Send

    /// Sends the request through the session's monitor with the device's User-Agent. Returns the task (tests await it);
    /// `nil` when the request cannot be sent (the reason is in `phase`).
    @discardableResult
    func send() -> Task<Void, Never>? {
        guard phase != .sending else { return nil }
        let composed: ComposedRequest
        do {
            composed = try request.composed()
        } catch {
            phase = .failed(error.message)
            return nil
        }
        generation &+= 1
        let token = generation
        let draft = request
        let sentBody = request.body
        let device = target.device
        let monitor = target.monitor
        phase = .sending
        sendWarning = nil
        simulatorNote = nil
        // The JSON check parses the whole body: off the main actor, while the request is on its way.
        Task { [weak self] in
            let warning = await Task.detached(priority: .utility) { draft.jsonWarning }.value
            guard let self, token == self.generation else { return }
            self.sendWarning = warning
        }
        let task = Task { [weak self] in
            do {
                let response = try await monitor.send(composed, userAgent: device.userAgent)
                guard let self, token == self.generation else { return }
                await self.received(ClientExchange(requestBody: sentBody, response: ClientResponse(response, receivedAt: self.now()),
                                                   deviceID: device.id),
                                    device: device)
            } catch {
                guard let self, token == self.generation else { return }
                self.phase = .failed(Self.message(for: error))
            }
        }
        sendTask = task
        return task
    }

    /// Stops the request in flight; a response that still arrives is dropped.
    func cancel() {
        guard phase == .sending else { return }
        generation &+= 1
        sendTask?.cancel()
        sendTask = nil
        phase = .failed("Cancelled")
    }

    private func received(_ exchange: ClientExchange, device: DeviceProfile) async {
        self.exchange = exchange
        exchangeOrigin = .sent
        phase = .received
        sendTask = nil
        guard exchange.response.carriesAResponseToRender else {
            simulatorNote = exchange.response.isSuccess
                ? "No bid: the response has no body. The simulator was left as it was."
                : "HTTP \(exchange.response.status): the simulator was left as it was."
            return
        }
        await show(exchange, on: device)
    }

    // MARK: Simulator

    /// Shows the current exchange's response on its device (a saved one, or the last one sent), without sending anything.
    func render() async {
        guard let exchange, exchange.response.carriesAResponseToRender else { return }
        await show(exchange, on: exchange.deviceID.flatMap(DeviceCatalog.device(id:)))
    }

    private func show(_ exchange: ClientExchange, on device: DeviceProfile?) async {
        let renders = target.mode != .real
        await target.loadExchange(request: exchange.requestBody, response: exchange.response.body, device: device, render: renders)
        simulatorNote = renders
            ? nil
            : "Loaded into the Response and Request editors. Real mode: press Render to show it; its trackers will be sent."
    }

    // MARK: Library

    /// Saves the request and its exchange: over the request it was opened from, or (`asNew`, or never saved) as a new one.
    @discardableResult
    func save(asNew: Bool = false) async -> Bool {
        let date = now()
        let id = asNew ? UUID() : (savedID ?? UUID())
        let existing = asNew ? nil : library.request(id: id)
        let item = SavedRequest(id: id, name: effectiveName, createdAt: existing?.createdAt ?? date, updatedAt: date, request: request,
                                exchange: exchange)
        guard await library.save(item) else { return false }
        savedID = item.id
        name = item.name
        return true
    }

    /// Opens a saved request with its exchange (nothing is sent).
    func open(_ saved: SavedRequest) {
        stopSending()
        request = saved.request
        name = saved.name
        savedID = saved.id
        exchange = saved.exchange
        exchangeOrigin = saved.exchange == nil ? nil : .saved
        phase = saved.exchange == nil ? .idle : .received
        sendWarning = nil
        simulatorNote = nil
    }

    func newRequest() {
        stopSending()
        request = ClientRequest()
        name = ""
        savedID = nil
        exchange = nil
        exchangeOrigin = nil
        phase = .idle
        sendWarning = nil
        simulatorNote = nil
    }

    /// The library deleted `id`: the tab keeps its content as an unsaved request.
    func forget(_ id: UUID) {
        if savedID == id { savedID = nil }
    }

    private func stopSending() {
        generation &+= 1
        sendTask?.cancel()
        sendTask = nil
    }

    static func message(for error: any Error) -> String {
        switch error {
        case NetworkMonitorError.offline:
            "Offline: the request was recorded in the Network window and not sent. Switch to Simulated or Real to send it."
        case let error as NetworkMonitorError:
            error.errorDescription ?? "The request failed."
        case is CancellationError:
            "Cancelled"
        default:
            error.localizedDescription
        }
    }
}

extension AdSession: ClientSimulatorTarget {
    /// The Client's exchange in the editors: a different device first (the ad on the old one is removed, nothing is sent),
    /// then the request and response, parsed at once, so the bid's format and placement come from both; rendered when
    /// `render` is set (never in Real mode: the Client asks only outside it).
    func loadExchange(request: String, response: String, device: DeviceProfile?, render shouldRender: Bool) async {
        if let device, device != self.device {
            if phase != .idle { reset() }
            self.device = device
        }
        requestText = request
        responseText = response
        await parseNow()
        if shouldRender { render() }
    }
}
