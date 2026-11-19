import AppKit
import CcinnOpenRTBKit
import RTBKit
import SwiftUI

/// The Client tab: compose a bid request, send it to an endpoint, read the response and see it on the device; save it
/// to the library and open it later (bid-client). Small views, so each builder type-checks quickly (CI runs Swift 6.2).
struct ClientPane: View {
    @Bindable var client: ClientModel
    let session: AdSession

    var body: some View {
        VStack(spacing: 0) {
            ClientTitleBar(client: client, session: session)
            Divider()
            ClientURLBar(client: client)
            ClientNotices(client: client)
            Divider()
            VSplitView {
                ClientRequestEditor(client: client)
                    .frame(minHeight: 150, idealHeight: 280, maxHeight: .infinity)
                ClientResponseView(client: client, session: session)
                    .frame(minHeight: 160, idealHeight: 320, maxHeight: .infinity)
            }
        }
        .task { await client.library.loadIfNeeded() }
    }
}

// MARK: - Title bar

/// The library, the request's name, Save and the request menu.
private struct ClientTitleBar: View {
    @Bindable var client: ClientModel
    let session: AdSession
    @State private var showsLibrary = false

    var body: some View {
        HStack(spacing: 8) {
            Button {
                showsLibrary.toggle()
            } label: {
                Label("Saved", systemImage: "tray.full")
            }
            .help("Saved requests and their responses")
            .popover(isPresented: $showsLibrary, arrowEdge: .bottom) {
                SavedRequestsPopover(client: client, isPresented: $showsLibrary)
            }
            TextField("Name", text: $client.name, prompt: Text(SavedRequest.defaultName(for: client.request)))
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Request name")
            if client.hasUnsavedChanges {
                Circle().fill(Color.orange).frame(width: 6, height: 6).help("Not saved")
            }
            Button {
                Task { await client.save() }
            } label: {
                Label("Save", systemImage: "square.and.arrow.down")
            }
            .keyboardShortcut("s", modifiers: .command)
            .help(client.savedID == nil ? "Save the request and its response (⌘S)" : "Save the changes (⌘S)")
            ClientRequestMenu(client: client, session: session)
        }
        .labelStyle(.titleAndIcon)
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

private struct ClientRequestMenu: View {
    let client: ClientModel
    let session: AdSession
    @State private var confirmsNewRequest = false

    var body: some View {
        Menu {
            Button("New Request") {
                if client.hasUnsavedChanges { confirmsNewRequest = true } else { client.newRequest() }
            }
            Button("Save as New Request") { Task { await client.save(asNew: true) } }
            Divider()
            Button("Copy as curl") { copyCurl() }
                .disabled(!client.problems.isEmpty)
            Divider()
            Button("Export All Saved Requests…") { SavedRequestTransfer.exportAll(from: client.library) }
                .disabled(client.library.requests.isEmpty)
            Button("Import Saved Requests…") { SavedRequestTransfer.importArchive(into: client.library) }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More")
        .confirmationDialog("Discard the unsaved changes?", isPresented: $confirmsNewRequest) {
            Button("New Request", role: .destructive) { client.newRequest() }
        } message: {
            Text("The request in the Client tab has changes that are not saved.")
        }
    }

    private func copyCurl() {
        guard let command = try? ClientPresentation.curl(for: client.request, userAgent: session.device.userAgent,
                                                          acceptLanguage: session.monitor.acceptLanguage) else { return }
        Pasteboard.copy(command)
    }
}

// MARK: - URL bar

/// Method, endpoint and Send / Cancel.
private struct ClientURLBar: View {
    @Bindable var client: ClientModel

    var body: some View {
        HStack(spacing: 8) {
            Picker("Method", selection: $client.request.method) {
                ForEach(ClientMethod.allCases) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            TextField("Endpoint", text: $client.request.url, prompt: Text("https://ssp.example/openrtb2/auction"))
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .onSubmit { client.send() }
                .accessibilityLabel("Endpoint URL")
            if client.isSending {
                Button(role: .cancel) {
                    client.cancel()
                } label: {
                    Label("Cancel", systemImage: "xmark")
                }
                .keyboardShortcut(".", modifiers: .command)
                .help("Stop the request (⌘.)")
            } else {
                Button {
                    client.send()
                } label: {
                    Label("Send", systemImage: "paperplane.fill")
                }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
                .disabled(!client.canSend)
                .help("Send the request with the simulated device’s User-Agent (⌘↩)")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

/// Why the request cannot be sent, and non-blocking notes.
private struct ClientNotices: View {
    let client: ClientModel

    var body: some View {
        let blocking = client.problems.filter { $0 != .missingURL }.map(\.message)
        let notes = [client.sendWarning, client.library.lastError].compactMap { $0 }
        let info = client.library.lastNotice
        if !blocking.isEmpty || !notes.isEmpty || info != nil {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(blocking.enumerated()), id: \.offset) { Label($0.element, systemImage: "xmark.octagon.fill").foregroundStyle(.red) }
                ForEach(Array(notes.enumerated()), id: \.offset) { Label($0.element, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
                if let info { Label(info, systemImage: "checkmark.circle").foregroundStyle(.secondary) }
            }
            .font(.caption)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.bottom, 6)
        }
    }
}

// MARK: - Request

private struct ClientRequestEditor: View {
    enum Tab: String, CaseIterable, Identifiable {
        case body = "Body"
        case headers = "Headers"
        var id: String { rawValue }
    }

    @Bindable var client: ClientModel
    @State private var tab: Tab = .body
    @State private var formatError: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Picker("Request", selection: $tab) {
                    Text("Body").tag(Tab.body)
                    Text("Headers (\(client.request.activeHeaders.count))").tag(Tab.headers)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer(minLength: 0)
                ClientRedirectPicker(client: client)
                if tab == .body {
                    if let formatError { Text(formatError).font(.caption).foregroundStyle(.orange).lineLimit(1) }
                    Button("Format", systemImage: "text.alignleft") { format() }
                        .keyboardShortcut("f", modifiers: [.command, .shift])
                        .disabled(SyntaxHighlighter.Language.detect(client.request.body) != .json)
                        .help("Pretty-print the JSON (keeps key order and number spelling) (⇧⌘F)")
                }
            }
            .controlSize(.small)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            Divider()
            switch tab {
            case .body: ClientBodyEditor(client: client)
            case .headers: ClientHeadersEditor(client: client)
            }
        }
    }

    private func format() {
        let text = client.request.body
        Task {
            let formatted = await Task.detached(priority: .userInitiated) { JSONFormatter.prettyPrinted(text) }.value
            guard client.request.body == text else { return }
            if let formatted {
                formatError = nil
                client.request.body = formatted
            } else {
                formatError = "Not well-formed JSON"
            }
        }
    }
}

/// The request's redirect setting: follow all, within the origin, or none.
private struct ClientRedirectPicker: View {
    @Bindable var client: ClientModel

    var body: some View {
        Menu {
            Picker("Redirects", selection: $client.request.redirects) {
                ForEach(RedirectPolicy.allCases) { policy in
                    Text(ClientPresentation.title(for: policy)).tag(policy)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Label(ClientPresentation.shortTitle(for: client.request.redirects), systemImage: "arrow.triangle.turn.up.right.diamond")
        }
        .fixedSize()
        .help(ClientPresentation.help(for: client.request.redirects))
        .accessibilityLabel("Redirects")
    }
}

private struct ClientBodyEditor: View {
    @Bindable var client: ClientModel

    var body: some View {
        if client.request.method.sendsBody {
            CodeEditor(text: $client.request.body, accessibilityLabel: "Request body")
                .overlay(alignment: .topLeading) {
                    if client.request.body.isEmpty {
                        Text("Type or paste the OpenRTB bid request (JSON).")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 8)
                            .allowsHitTesting(false)
                    }
                }
        } else {
            ContentUnavailableView("GET sends no body", systemImage: "arrow.down.doc",
                                   description: Text("Put the request in the URL, or switch to POST to send the body."))
        }
    }
}

private struct ClientHeadersEditor: View {
    @Bindable var client: ClientModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                ForEach($client.request.headers) { $header in
                    ClientHeaderRow(header: $header) {
                        client.request.headers.removeAll { $0.id == header.id }
                    }
                }
                Button("Add Header", systemImage: "plus") {
                    client.request.headers.append(ClientHeader(name: "", value: ""))
                }
                .controlSize(.small)
                Text("The device’s User-Agent, Accept and Accept-Language are added unless set here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct ClientHeaderRow: View {
    @Binding var header: ClientHeader
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Toggle("Send", isOn: $header.isEnabled)
                .toggleStyle(.checkbox)
                .labelsHidden()
                .help(header.isEnabled ? "Sent" : "Not sent")
            TextField("Name", text: $header.name)
                .frame(minWidth: 90, idealWidth: 150, maxWidth: 200)
            TextField("Value", text: $header.value)
            Button(action: remove) {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .help("Remove the header")
        }
        .textFieldStyle(.roundedBorder)
        .font(.system(.callout, design: .monospaced))
        .opacity(header.isEnabled ? 1 : 0.55)
    }
}

// MARK: - Response

private struct ClientResponseView: View {
    let client: ClientModel
    let session: AdSession

    var body: some View {
        VStack(spacing: 0) {
            switch client.phase {
            case .idle where client.exchange == nil:
                ContentUnavailableView("No Response Yet", systemImage: "paperplane",
                                       description: Text("Send the request: the response appears here and on the device."))
            case .sending:
                VStack(spacing: 8) {
                    ProgressView()
                    Text("Waiting for \(URLText.host(client.request.trimmedURL) ?? "the endpoint")…").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case let .failed(message):
                ContentUnavailableView {
                    Label("Not Sent", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message).textSelection(.enabled)
                }
            case .idle, .received:
                if let exchange = client.exchange {
                    ClientExchangeView(client: client, session: session, exchange: exchange)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ClientExchangeView: View {
    enum Tab: String { case body, headers, redirects }

    let client: ClientModel
    let session: AdSession
    let exchange: ClientExchange
    @State private var tab: Tab
    @State private var shownBody = ""

    init(client: ClientModel, session: AdSession, exchange: ClientExchange) {
        self.client = client
        self.session = session
        self.exchange = exchange
        let followed = client.prefersRedirectsTab && (exchange.response.chain.count > 1 || exchange.response.redirectStop != nil)
        _tab = State(initialValue: followed ? .redirects : .body)
    }

    /// A chain worth showing: redirects followed, or one that ended on a redirect.
    private var showsChain: Bool { exchange.response.chain.count > 1 || exchange.response.redirectStop != nil }

    var body: some View {
        VStack(spacing: 0) {
            ClientStatusBar(client: client, session: session, exchange: exchange)
            ClientSimulatorLine(client: client, session: session, exchange: exchange)
            Divider()
            HStack {
                Picker("Response", selection: $tab) {
                    Text("Body").tag(Tab.body)
                    Text("Headers (\(exchange.response.headers.count))").tag(Tab.headers)
                    if showsChain { Text("Redirects (\(exchange.response.redirectCount))").tag(Tab.redirects) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer(minLength: 0)
                Button("Copy Body", systemImage: "doc.on.doc") { Pasteboard.copy(exchange.response.body) }
                    .disabled(exchange.response.body.isEmpty)
            }
            .controlSize(.small)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            Divider()
            switch tab {
            case .body:
                CodeEditor(text: .constant(shownBody), accessibilityLabel: "Response body", isEditable: false)
            case .headers:
                ScrollView {
                    KeyValueGrid(rows: HTTPHeaders.sorted(exchange.response.headers).map { ($0.name, $0.value) })
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            case .redirects:
                ClientRedirectChainView(response: exchange.response)
            }
        }
        .onChange(of: showsChain) { if !showsChain, tab == .redirects { tab = .body } }
        .task(id: exchange.response.body) {
            // Pretty-printed off the main actor; shown as received when it is not JSON.
            let raw = exchange.response.body
            shownBody = await Task.detached(priority: .userInitiated) { JSONFormatter.prettyPrinted(raw) ?? raw }.value
        }
    }
}

/// "● 200 OK · 142 ms · 3.4 KB · Received 14:02:11 · iPhone 18 Pro" and Render.
private struct ClientStatusBar: View {
    let client: ClientModel
    let session: AdSession
    let exchange: ClientExchange

    var body: some View {
        let response = exchange.response
        let tone = ClientPresentation.statusTone(response.status)
        HStack(spacing: 8) {
            Badge(text: ClientPresentation.statusText(response.status), color: tone.color)
            Text(Format.duration(milliseconds: response.durationMilliseconds)).monospacedDigit()
            Text(Format.bytes(response.bodyBytes)).monospacedDigit()
            if let redirects = ClientPresentation.redirectsLine(response) { Text(redirects) }
            Text(ClientPresentation.origin(of: exchange, client.exchangeOrigin)).lineLimit(1).truncationMode(.middle)
            if let device = exchange.deviceID.flatMap(DeviceCatalog.device(id:)) {
                Label(device.name, systemImage: "iphone").lineLimit(1)
            }
            Spacer(minLength: 4)
            Button {
                Task { await client.render() }
            } label: {
                Label("Render", systemImage: "play.rectangle")
            }
            .controlSize(.small)
            .disabled(!client.canRender)
            .help(session.mode == .real ? "Show this response on its device: nothing goes to the endpoint, but in Real mode the bid’s trackers are sent"
                : "Show this response on its device (nothing is sent to the endpoint)")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

/// Every request of the chain, in order: method, URL, status, where it pointed, time, body, what changed on the way, and
/// why the chain ended.
struct ClientRedirectChainView: View {
    let response: ClientResponse

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(response.chain.enumerated()), id: \.offset) { index, hop in
                    ClientRedirectHopRow(index: index, hop: hop, isAnswer: hop.wasSent && index == response.chain.lastIndex(where: \.wasSent),
                                         stop: response.redirectStop)
                }
                if let stop = response.redirectStop {
                    Label(stop, systemImage: "hand.raised").font(.callout).foregroundStyle(.orange).textSelection(.enabled)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct ClientRedirectHopRow: View {
    let index: Int
    let hop: ClientRedirectHop
    let isAnswer: Bool
    /// Shown once, under the chain: left out of the hop's own notes.
    let stop: String?

    private var lines: [String] {
        let notes = (hop.note ?? "").components(separatedBy: " · ").filter { !$0.isEmpty && $0 != stop }
        let failure = hop.failure.flatMap { $0 == stop || stop.map($0.hasPrefix) == true ? nil : $0 }
        return notes + [failure].compactMap { $0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text("\(index + 1)").monospacedDigit().foregroundStyle(.secondary).frame(width: 18, alignment: .trailing)
                Badge(text: hop.method)
                if let status = hop.status {
                    Badge(text: ClientPresentation.statusText(status), color: ClientPresentation.statusTone(status).color)
                } else {
                    Badge(text: "not sent", color: .orange)
                }
                if let milliseconds = hop.durationMilliseconds, hop.wasSent {
                    Text(Format.duration(milliseconds: milliseconds)).monospacedDigit().foregroundStyle(.secondary)
                }
                if hop.wasSent, let bytes = hop.bodyBytes { Text("body \(Format.bytes(bytes))").foregroundStyle(.secondary) }
                if isAnswer { Badge(text: "answer", color: .green) }
            }
            Text(hop.url).font(Theme.monospacedSmall).textSelection(.enabled).lineLimit(3).padding(.leading, 24)
            if let location = hop.location {
                Label(location, systemImage: "arrow.turn.down.right").font(Theme.monospacedSmall).foregroundStyle(.secondary)
                    .textSelection(.enabled).lineLimit(3).padding(.leading, 24)
            }
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(line).font(.caption).foregroundStyle(line.contains("unencrypted") || line == hop.failure ? .orange : .secondary)
                    .padding(.leading, 24)
            }
        }
        .font(.caption)
    }
}

/// What the simulator made of it (format and placement from the request and response), or why it was left alone.
private struct ClientSimulatorLine: View {
    let client: ClientModel
    let session: AdSession
    let exchange: ClientExchange

    var body: some View {
        HStack(spacing: 6) {
            if let note = client.simulatorNote {
                Image(systemName: "info.circle")
                Text(note)
                if client.canFollowAllRedirects {
                    Button(client.followTarget.map { "Follow to \($0) and Send" } ?? "Follow All Redirects and Send") { client.followAllRedirectsAndSend() }
                        .controlSize(.small)
                        .help("Send this request again, following every redirect for this send only: its body and headers (but Authorization, "
                            + "Proxy-Authorization and Cookie) go to \(client.followTarget ?? "the other origin") too. The request’s Redirects setting stays as it is.")
                }
            } else if session.responseText == exchange.response.body {
                Image(systemName: "iphone.gen3")
                Text(ClientPresentation.simulatorSummary(session))
            } else if exchange.response.carriesAResponseToRender {
                Image(systemName: "play.rectangle")
                Text("Not on the device: press Render to show this response.")
            }
            Spacer(minLength: 0)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(2)
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
    }
}
