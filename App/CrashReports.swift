// SPDX-License-Identifier: Apache-2.0

import CryptoKit
import SwiftUI

/// Sends crash reports from Burrow's crash log, and install results, to the
/// repositories that offer the package, when they serve a
/// `reports_endpoint` file (docs/reports.md). A crash report leaves the
/// device only after the user has seen it and tapped Send, or, for a
/// repository they chose to always send to, when Codling next reads the
/// crash log. Install results go only while the user has Share Install
/// Results on.
@MainActor
final class ReportsModel: ObservableObject {
    /// A repository that receives a report.
    struct Recipient: Identifiable, Equatable {
        let sourceID: String
        let title: String
        let endpoint: URL
        var id: String { sourceID }
    }

    /// Who receives each crash's report, by crash id; a crash whose
    /// package no repository takes reports for has none.
    @Published private(set) var recipients: [String: [Recipient]] = [:]
    @Published private(set) var sent: Set<String>
    /// The repositories, by address, that the user chose to always send
    /// crash reports to.
    @Published private(set) var alwaysSend: Set<String>

    /// Whether install results go to the repositories, which the user turns
    /// on in System. Off until they do.
    @Published var shareInstallResults: Bool {
        didSet { UserDefaults.standard.set(shareInstallResults, forKey: Self.shareKey) }
    }

    weak var sources: SourcesModel?
    /// For the tweak loader in use, when Burrow has been read.
    weak var burrow: BurrowModel?
    private let environment: RuntimeEnvironment
    /// Each repository's reports address, or nil for none, once read.
    private var endpoints: [String: URL?] = [:]

    private static let sentKey = "SentCrashReports"
    private static let alwaysKey = "AlwaysSendCrashReports"
    private static let shareKey = "ShareInstallResults"

    init(environment: RuntimeEnvironment) {
        self.environment = environment
        let defaults = UserDefaults.standard
        sent = Set(defaults.stringArray(forKey: Self.sentKey) ?? [])
        alwaysSend = Set(defaults.stringArray(forKey: Self.alwaysKey) ?? [])
        shareInstallResults = defaults.bool(forKey: Self.shareKey)
    }

    /// Finds who receives each crash's report: the repositories in the
    /// index that offer that version of the package and serve a reports
    /// address.
    func prepare(_ crashes: [BurrowState.Crash]) async {
        var found: [String: [Recipient]] = [:]
        for crash in crashes {
            guard let identifier = crash.package?.package, let version = crash.package?.version else { continue }
            let list = await recipients(package: identifier, version: version).map(\.recipient)
            if !list.isEmpty {
                found[crash.id] = list
            }
        }
        recipients = found
    }

    /// The repositories in the index that offer this version of a package
    /// and serve a reports address, with the architecture each lists it
    /// for.
    private func recipients(package identifier: String, version: String) async -> [(recipient: Recipient, architecture: String)] {
        guard let sources, let store = sources.store else { return [] }
        let offers = (try? await store.offers(of: identifier)) ?? []
        var list: [(recipient: Recipient, architecture: String)] = []
        for offer in offers {
            guard let info = sources.info(for: offer.source),
                  let versions = try? await store.versions(of: identifier, source: offer.source),
                  let record = versions.first(where: { $0.version == version }),
                  let endpoint = await endpoint(of: info.source) else { continue }
            list.append((Recipient(sourceID: info.id, title: info.title, endpoint: endpoint),
                         record.architecture.isEmpty ? environment.architecture : record.architecture))
        }
        return list.sorted { $0.recipient.title.localizedCaseInsensitiveCompare($1.recipient.title) == .orderedAscending }
    }

    /// After a change, while Share Install Results is on: whether each
    /// package it installed or upgraded went in, to the repositories that
    /// offer it and take reports. apt's output is never sent, only the
    /// names of the problems Codling found in it.
    func sendInstallResults(plan: AptPlan, succeeded: Bool, diagnoses: [AptDiagnosis]) {
        guard shareInstallResults else { return }
        let changes = plan.changes.filter { $0.kind == .install || $0.kind == .upgrade }
        guard !changes.isEmpty else { return }
        let device = device(loader: burrow?.state?.loader)
        let problems = diagnoses.map(\.id)
        let version = environment.version
        Task {
            for change in changes {
                for (recipient, architecture) in await recipients(package: change.package, version: change.version) {
                    let result = Reports.InstallResult(package: change.package, version: change.version,
                                                       architecture: architecture, upgrade: change.kind == .upgrade,
                                                       installed: succeeded, problems: problems, device: device)
                    if let body = try? Reports.body(result) {
                        _ = await Self.post(body, to: Reports.url(recipient.endpoint, .install), version: version)
                    }
                }
            }
        }
    }

    /// The report for a crash, exactly as it would be sent.
    func report(for crash: BurrowState.Crash, loader: String?) -> Reports.CrashReport? {
        guard let incident = crash.incident else { return nil }
        let id = SHA256.hash(data: Data(incident.utf8)).map { String(format: "%02x", $0) }.joined()
        return Reports.CrashReport(crash: crash, id: id, architecture: environment.architecture, device: device(loader: loader))
    }

    /// What every report says about this device.
    func device(loader: String?) -> Reports.Device {
        Reports.Device(model: environment.deviceModel, system: environment.systemVersion, build: Self.systemBuild,
                       jailbreak: environment.scheme == .roothide ? "roothide" : "rootless",
                       loader: Reports.loaderName(loader), client: "Codling \(environment.version)")
    }

    func isAlwaysSent(_ recipients: [Recipient]) -> Bool {
        !recipients.isEmpty && recipients.allSatisfy { alwaysSend.contains($0.endpoint.absoluteString) }
    }

    func setAlwaysSend(_ on: Bool, for recipients: [Recipient]) {
        for recipient in recipients {
            if on {
                alwaysSend.insert(recipient.endpoint.absoluteString)
            } else {
                alwaysSend.remove(recipient.endpoint.absoluteString)
            }
        }
        UserDefaults.standard.set(Array(alwaysSend).sorted(), forKey: Self.alwaysKey)
    }

    /// Sends a crash's report to each recipient. Returns why it failed for
    /// any of them, or nil when every one accepted it.
    func send(_ crash: BurrowState.Crash, loader: String?) async -> String? {
        guard let report = report(for: crash, loader: loader), let body = try? Reports.body(report) else {
            return "Codling could not make a report of this crash."
        }
        let targets = recipients[crash.id] ?? []
        guard !targets.isEmpty else {
            return "The tweak's source does not take crash reports."
        }
        var problems: [String] = []
        for recipient in targets {
            if let problem = await Self.post(body, to: Reports.url(recipient.endpoint, .crash), version: environment.version) {
                problems.append("\(recipient.title): \(problem)")
            }
        }
        guard problems.isEmpty else {
            return problems.joined(separator: "\n")
        }
        sent.insert(crash.id)
        UserDefaults.standard.set(Array(sent).sorted(), forKey: Self.sentKey)
        return nil
    }

    /// Sends, without asking, the crashes not sent yet whose recipients the
    /// user chose to always send to. A crash that fails waits for the next
    /// time.
    func sendAutomatically(_ crashes: [BurrowState.Crash], loader: String?) async {
        guard !alwaysSend.isEmpty else { return }
        for crash in crashes where !sent.contains(crash.id) {
            guard let targets = recipients[crash.id], isAlwaysSent(targets) else { continue }
            _ = await send(crash, loader: loader)
        }
    }

    /// Sends an install result, as InstallResults does.
    static func post(_ body: Data, to url: URL, version: String) async -> String? {
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Codling/\(version)", forHTTPHeaderField: "User-Agent")
        do {
            let (_, response) = try await URLSession.shared.data(for: request, delegate: HTTPSOnlyRedirects.shared)
            guard let status = (response as? HTTPURLResponse)?.statusCode else { return "no answer" }
            return (200..<300).contains(status) ? nil : "it answered \(status)"
        } catch {
            return error.localizedDescription
        }
    }

    /// A repository's reports address, read once per launch, over HTTPS
    /// only.
    func endpoint(of source: Source) async -> URL? {
        if let known = endpoints[source.uri] {
            return known
        }
        var found: URL?
        for url in PaymentProvider.endpointFileURLs(source.repositoryFileURLs("reports_endpoint")) {
            var request = URLRequest(url: url, timeoutInterval: 15)
            request.setValue("Codling/\(environment.version)", forHTTPHeaderField: "User-Agent")
            guard let (data, response) = try? await URLSession.shared.data(for: request, delegate: HTTPSOnlyRedirects.shared),
                  (response as? HTTPURLResponse)?.statusCode == 200, data.count < 4096,
                  let text = String(data: data, encoding: .utf8),
                  let endpoint = Reports.endpoint(fromFile: text) else { continue }
            found = endpoint
            break
        }
        endpoints[source.uri] = found
        return found
    }

    /// The iOS build, such as 20D67.
    static let systemBuild: String? = {
        var size = 0
        guard sysctlbyname("kern.osversion", nil, &size, nil, 0) == 0, size > 1 else { return nil }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.osversion", &bytes, &size, nil, 0) == 0 else { return nil }
        let build = String(cString: bytes)
        return build.isEmpty ? nil : build
    }()
}

/// The switch for install results, in System.
struct InstallResultsCard: View {
    @EnvironmentObject private var reports: ReportsModel

    var body: some View {
        Card(padding: 14) {
            Toggle(isOn: $reports.shareInstallResults) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Share Install Results")
                        .font(.subheadline.weight(.semibold))
                    Text("After each change, tell the sources of the packages it installed or upgraded whether they went in, with this device's model, iOS version and jailbreak, so that their developers know where their packages work. Only sources that take reports receive them, and nothing that identifies you or this device is sent.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// Burrow's crash log on the Burrow screen: each crash with a tweak to
/// blame, and Send to Developer where the tweak's source takes reports.
struct CrashLogCard: View {
    /// The Burrow screen's, which shows the alert when clearing fails.
    static let origin = "burrow"
    @ObservedObject var model: BurrowModel
    let state: BurrowState
    @EnvironmentObject private var reports: ReportsModel
    @State private var expanded = false
    @State private var reviewing: BurrowState.Crash?
    @State private var confirmingClear = false

    var body: some View {
        let crashes = state.crashLog
        if !crashes.isEmpty {
            CollapsibleCard(title: "Crash Log", symbol: "exclamationmark.triangle", color: .orange,
                            count: crashes.count, expanded: $expanded) {
                DividedRows(items: crashes, dividerInset: 16) { crash in
                    row(crash)
                }
                Divider()
                    .padding(.leading, 16)
                Button(role: .destructive) {
                    confirmingClear = true
                } label: {
                    Label("Clear Crash Log", systemImage: "trash")
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(model.working == nil ? .red : .secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.borderless)
                .disabled(model.working != nil)
            }
            .confirmationDialog("Clear the crash log?", isPresented: $confirmingClear, titleVisibility: .visible) {
                Button("Clear Crash Log", role: .destructive) {
                    Task { await model.clearCrashLog(origin: Self.origin) }
                }
            } message: {
                Text("Burrow forgets these crashes and deletes its copies of their reports. Tweaks Safe Mode turned off stay off, and reports not sent yet cannot be sent.")
            }
            .padding(.top, 8)
            .task(id: crashes.map(\.id)) {
                await reports.prepare(crashes)
                await reports.sendAutomatically(crashes, loader: state.loader)
            }
            .sheet(item: $reviewing) { crash in
                CrashReportSheet(crash: crash, loader: state.loader) { reviewing = nil }
                    .environmentObject(reports)
                    .tint(Palette.text)
                    .accentColor(Palette.text)
            }
            if expanded {
                CardFooter(text: "Crashes Burrow blames on a tweak. A report goes to the tweak's developer only when you send it, and only through a source that takes crash reports.")
            }
        }
    }

    private func row(_ crash: BurrowState.Crash) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title(crash))
                .font(.subheadline.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            if let date = crash.date {
                Text(date, style: .relative)
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    + Text(" ago")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
            if let reason = crash.reason {
                Text(reason)
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(growing: 3)
            }
            HStack(spacing: 20) {
                if reports.sent.contains(crash.id) {
                    Label("Sent to the developer", systemImage: "checkmark.circle.fill")
                        .foregroundColor(.green)
                } else if let recipients = reports.recipients[crash.id], !recipients.isEmpty {
                    Button("Send to Developer") { reviewing = crash }
                }
                if let report = reports.report(for: crash, loader: state.loader) {
                    Button {
                        share(report)
                    } label: {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                    .accessibilityLabel("Share the report of this crash")
                }
            }
            .font(.subheadline.weight(.semibold))
            .buttonStyle(.borderless)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    /// Opens the share sheet with the report as a text file, for the user
    /// to send wherever they choose. It holds the same as Send would send.
    private func share(_ report: Reports.CrashReport) {
        guard let text = try? Reports.shareText(report) else { return }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("crash-reports", isDirectory: true)
        let file = directory.appendingPathComponent(Reports.shareFileName(report))
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(text.utf8).write(to: file, options: .atomic)
            Presenter.share([file])
        } catch {
            Presenter.share([text])
        }
    }

    private func title(_ crash: BurrowState.Crash) -> String {
        let tweak = crash.package?.name ?? crash.tweak ?? "A tweak"
        return "\(tweak) crashed \(crash.process ?? crash.bundleIdentifier ?? "a process")"
    }
}

/// What a crash report holds, before the user sends it.
struct CrashReportSheet: View {
    let crash: BurrowState.Crash
    let loader: String?
    let onClose: () -> Void
    @EnvironmentObject private var reports: ReportsModel
    @State private var sending = false
    @State private var problem: String?
    @State private var showsEverything = false

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 12) {
                    if let report = reports.report(for: crash, loader: loader) {
                        content(report)
                    } else {
                        Card(padding: 14) {
                            ToolHeader(symbol: "xmark.octagon", color: .red, title: "No report to send") {
                                ToolNote(text: "Burrow's crash log does not say which package and version this tweak came from, so the developer could not use a report.")
                            }
                        }
                    }
                }
                .toolColumn()
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            .background(WallBackground())
            .navigationTitle("Crash Report")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", action: onClose)
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    @ViewBuilder
    private func content(_ report: Reports.CrashReport) -> some View {
        let recipients = reports.recipients[crash.id] ?? []
        Card(padding: 14) {
            ToolHeader(symbol: "paperplane", color: .blue, title: "Send to the developer?") {
                ToolNote(text: "This report helps the developer of \(report.package) find and fix the crash. It is sent only to the source below, and only when you tap Send. It holds nothing that identifies you or this device.")
            }
        }
        VStack(spacing: 0) {
            ForEach(Array(recipients.enumerated()), id: \.element.id) { index, recipient in
                InfoRow(name: index == 0 ? "Goes to" : "And to", value: "\(recipient.title) (\(recipient.endpoint.host ?? ""))",
                        first: index == 0)
            }
            InfoRow(name: "Package", value: "\(report.package) \(report.version)", monospaced: true)
            InfoRow(name: "Tweak", value: report.tweak)
            InfoRow(name: "Crashed", value: report.process)
            if let reason = report.reason {
                InfoRow(name: "Reason", value: reason)
            }
            InfoRow(name: "Frames", value: report.frames.isEmpty ? "None" : "\(report.frames.count), from the crashed thread")
            if !report.otherTweaks.isEmpty {
                InfoRow(name: "Other tweaks", value: report.otherTweaks.map(\.tweak).joined(separator: ", "))
            }
            InfoRow(name: "Device", value: ([report.device.model, "iOS \(report.device.system)", report.device.build]
                                             .compactMap { $0 } + [report.device.jailbreak, report.device.loader].compactMap { $0 })
                                            .joined(separator: " · "))
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassSurface(cornerRadius: 22)

        Card(padding: 14) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { showsEverything.toggle() }
            } label: {
                HStack {
                    Text("Everything That Is Sent")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Image(systemName: showsEverything ? "chevron.up" : "chevron.down")
                        .font(.footnote.weight(.semibold))
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if showsEverything, let data = try? Reports.body(report, pretty: true) {
                Text(String(decoding: data, as: UTF8.self))
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 10)
            }
        }

        Card(padding: 14) {
            Toggle(isOn: Binding(get: { reports.isAlwaysSent(recipients) },
                                 set: { reports.setAlwaysSend($0, for: recipients) })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Always Send")
                        .font(.subheadline.weight(.semibold))
                    Text("Send the reports of later crashes to \(recipients.map(\.title).joined(separator: " and ")) without asking.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }

        if let problem {
            Card(padding: 14) {
                ToolHeader(symbol: "xmark.octagon", color: .red, title: "Not sent") {
                    ToolNote(text: problem)
                }
            }
        }

        Button(sending ? "Sending…" : (problem == nil ? "Send" : "Try Again")) {
            Task {
                sending = true
                problem = await reports.send(crash, loader: loader)
                sending = false
                if problem == nil {
                    onClose()
                }
            }
        }
        .buttonStyle(CapsuleButtonStyle())
        .disabled(sending || recipients.isEmpty)
    }
}
