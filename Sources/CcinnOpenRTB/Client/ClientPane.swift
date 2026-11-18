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

    var body: some View {
        Menu {
            Button("New Request") { client.newRequest() }
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
                ForEach(blocking, id: \.self) { Label($0, systemImage: "xmark.octagon.fill").foregroundStyle(.red) }
                ForEach(notes, id: \.self) { Label($0, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
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
    enum Tab: String { case body, headers }

    let client: ClientModel
    let session: AdSession
    let exchange: ClientExchange
    @State private var tab: Tab = .body
    @State private var shownBody = ""

    var body: some View {
        VStack(spacing: 0) {
            ClientStatusBar(client: client, exchange: exchange)
            ClientSimulatorLine(client: client, session: session, exchange: exchange)
            Divider()
            HStack {
                Picker("Response", selection: $tab) {
                    Text("Body").tag(Tab.body)
                    Text("Headers (\(exchange.response.headers.count))").tag(Tab.headers)
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
            }
        }
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
    let exchange: ClientExchange

    var body: some View {
        let response = exchange.response
        let tone = ClientPresentation.statusTone(response.status)
        HStack(spacing: 8) {
            Badge(text: ClientPresentation.statusText(response.status), color: tone.color)
            Text(Format.duration(milliseconds: response.durationMilliseconds)).monospacedDigit()
            Text(Format.bytes(response.bodyBytes)).monospacedDigit()
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
            .help("Show this response on its device (nothing is sent to the endpoint)")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
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
