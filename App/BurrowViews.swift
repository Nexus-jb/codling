// SPDX-License-Identifier: Apache-2.0

import SwiftUI

/// Burrow's settings: which loader loads the tweaks, what Safe Mode turned
/// off, and each tweak, which can be turned off in one app or everywhere.
/// Everything goes through Burrow's burrowctl, run as root by the helper.
@MainActor
final class BurrowModel: ObservableObject {
    enum Phase: Equatable {
        case loading
        case notInstalled
        case failed(String)
        case ready(BurrowState)
    }

    /// What a change did, shown as an alert by the screen that asked for it.
    struct Outcome: Identifiable {
        let id = UUID()
        let origin: String
        let title: String
        let message: String
        /// Whether restarting SpringBoard brings the change into it.
        let offersRespring: Bool
    }

    @Published private(set) var phase: Phase = .loading
    @Published private(set) var working: String?
    @Published var outcome: Outcome?
    @Published private(set) var apps: [InstalledApp] = []

    private let environment: RuntimeEnvironment

    init(environment: RuntimeEnvironment) {
        self.environment = environment
    }

    var state: BurrowState? {
        if case .ready(let state) = phase {
            return state
        }
        return nil
    }

    private var isInstalled: Bool {
        guard let root = environment.jailbreakRoot else {
            return false
        }
        return FileManager.default.isExecutableFile(atPath: root + "/usr/bin/burrowctl")
    }

    func load() async {
        guard isInstalled else {
            phase = .notInstalled
            return
        }
        if state == nil {
            phase = .loading
        }
        let result = await Task.detached(priority: .userInitiated) { RootHelper.burrowState() }.value
        switch result {
        case .failure(let failure):
            phase = .failed(failure.message)
        case .success(let command) where command.status != 0:
            phase = .failed(command.output.hasPrefix("usage:")
                ? "This version of Burrow cannot report its settings. Update Burrow to see and change them here."
                : command.output.trimmingCharacters(in: .whitespacesAndNewlines))
        case .success(let command):
            if let state = try? BurrowState.decode(Data(command.output.utf8)) {
                phase = .ready(state)
            } else {
                phase = .failed("Burrow's report could not be read.")
            }
        }
        if apps.isEmpty {
            apps = await Task.detached(priority: .utility) { InstalledApps.load() }.value
        }
    }

    /// The name people know a process by: the app's name, or SpringBoard.
    func name(of process: String) -> String {
        if process == "com.apple.springboard" || process == "SpringBoard" {
            return "SpringBoard"
        }
        return apps.first { $0.id == process }?.name ?? process
    }

    private func isSpringBoard(_ process: String) -> Bool {
        name(of: process) == "SpringBoard"
    }

    /// Turns a tweak on or off in one process, or everywhere with process
    /// "*". Tweak "*" is every tweak.
    func setTweak(_ tweak: String, on: Bool, in process: String, origin: String) async {
        guard working == nil else {
            return
        }
        let named = state?.tweaks.first(where: { $0.name == tweak })?.displayName ?? tweak
        let what = tweak == BurrowState.everyTweak ? "Every tweak" : named
        working = on ? "Turning \(what) on" : "Turning \(what) off"
        let result = await Task.detached(priority: .userInitiated) {
            RootHelper.burrowTweak(on: on, tweak: tweak, process: process)
        }.value
        working = nil
        switch result {
        case .failure(let failure):
            outcome = Outcome(origin: origin, title: "Nothing Changed", message: failure.message, offersRespring: false)
        case .success(let command) where command.status != 0:
            outcome = Outcome(origin: origin, title: "Nothing Changed",
                              message: command.output.trimmingCharacters(in: .whitespacesAndNewlines),
                              offersRespring: false)
        case .success:
            let everywhere = process == BurrowState.everyTweak
            let place = everywhere ? "everywhere" : "in \(name(of: process))"
            let when: String
            if everywhere {
                when = "Apps that are open keep their tweaks until they start again. Restart SpringBoard to bring the change into SpringBoard."
            } else if isSpringBoard(process) {
                when = "Restart SpringBoard to bring the change into it."
            } else {
                when = "It takes effect the next time \(name(of: process)) starts. If it is open now, close it in the app switcher and open it again."
            }
            outcome = Outcome(origin: origin, title: "\(what) Is \(on ? "Back On" : "Off") \(place.capitalizedFirst)",
                              message: when,
                              offersRespring: everywhere || isSpringBoard(process))
        }
        await load()
    }

    /// Makes Burrow's or ElleKit's loader load the tweaks into new processes.
    func useLoader(burrow: Bool, origin: String) async {
        guard working == nil else {
            return
        }
        working = burrow ? "Switching to Burrow's loader" : "Switching to ElleKit's loader"
        let result = await Task.detached(priority: .userInitiated) { RootHelper.burrowLoader(burrow: burrow) }.value
        working = nil
        switch result {
        case .failure(let failure):
            outcome = Outcome(origin: origin, title: "The Loader Did Not Change", message: failure.message, offersRespring: false)
        case .success(let command) where command.status != 0:
            outcome = Outcome(origin: origin, title: "The Loader Did Not Change",
                              message: command.output.trimmingCharacters(in: .whitespacesAndNewlines),
                              offersRespring: false)
        case .success:
            outcome = Outcome(
                origin: origin,
                title: burrow ? "Burrow's Loader Is in Use" : "ElleKit's Loader Is in Use",
                message: burrow
                    ? "New processes get their tweaks from Burrow's loader, with Safe Mode. For the next 15 minutes Burrow watches SpringBoard closely and goes back to ElleKit's loader by itself if SpringBoard crashes twice. Restart SpringBoard to load it with Burrow's loader."
                    : "New processes get their tweaks from ElleKit's loader. Burrow's per-app settings and Safe Mode wait until Burrow's loader is back. Restart SpringBoard to load it with ElleKit's loader.",
                offersRespring: true)
        }
        await load()
    }

    func respring() async {
        working = "Restarting SpringBoard"
        _ = await Task.detached(priority: .userInitiated) { RootHelper.respring() }.value
        working = nil
    }
}

private extension String {
    var capitalizedFirst: String {
        prefix(1).uppercased() + dropFirst()
    }
}

/// The Burrow screen in the System tab.
struct BurrowView: View {
    @ObservedObject var model: BurrowModel

    var body: some View {
        List {
            switch model.phase {
            case .loading:
                HStack {
                    ProgressView()
                    Text("Asking Burrow")
                        .padding(.leading, 6)
                }
            case .notInstalled:
                Section {
                    Text("Burrow is not installed.")
                } footer: {
                    Text("Burrow loads tweaks into apps, with Safe Mode, which turns off a tweak that crashes an app in that app only. Once Burrow is installed, its settings appear here.")
                }
            case .failed(let message):
                Section {
                    Text(message)
                        .textSelection(.enabled)
                    Button("Try Again") {
                        Task { await model.load() }
                    }
                } header: {
                    Text("Burrow did not answer")
                }
            case .ready(let state):
                BurrowStateSections(model: model, state: state)
            }
        }
        .navigationTitle("Burrow")
        .refreshable { await model.load() }
        .task { await model.load() }
        .burrowOutcomeAlert(model: model, origin: BurrowStateSections.origin)
        .overlay(alignment: .bottom) { BurrowWorkingBanner(text: model.working) }
    }
}

private struct BurrowStateSections: View {
    static let origin = "burrow"
    @ObservedObject var model: BurrowModel
    let state: BurrowState
    @State private var confirmingLoader = false

    var body: some View {
        Section {
            row("Tweak loader", state.loader)
            row("Safe Mode", state.safeModeSince.map { "On since \(Self.format($0))" } ?? "Off")
            if let until = state.trialUntil {
                Text("Burrow watches SpringBoard closely until \(Self.format(until)), and goes back to ElleKit's loader by itself if SpringBoard crashes twice.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
            if let back = state.wentBack {
                Text("Burrow went back to ElleKit's loader\(back.date.map { " on \(Self.format($0))" } ?? ""): \(back.reason)")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
            if state.loader == "Burrow" || state.loader == "ElleKit" {
                Button(state.usesBurrowLoader ? "Go Back to ElleKit's Loader" : "Use Burrow's Loader") {
                    confirmingLoader = true
                }
                .disabled(model.working != nil)
                .confirmationDialog(state.usesBurrowLoader ? "Go back to ElleKit's loader?" : "Use Burrow's loader?",
                                    isPresented: $confirmingLoader, titleVisibility: .visible) {
                    Button(state.usesBurrowLoader ? "Use ElleKit's Loader" : "Use Burrow's Loader") {
                        Task { await model.useLoader(burrow: !state.usesBurrowLoader, origin: Self.origin) }
                    }
                } message: {
                    Text(state.usesBurrowLoader
                         ? "Tweaks keep loading, but without Burrow's per-app settings and Safe Mode."
                         : "Burrow's loader loads the same tweaks, adds Safe Mode and per-app settings, and goes back to ElleKit's loader by itself if it crashes.")
                }
            }
        } header: {
            Text("Loader")
        } footer: {
            if !state.usesBurrowLoader {
                Text("Burrow's settings below take effect once Burrow's loader loads the tweaks.")
            }
        }

        if state.settings == "invalid" {
            Section {
                Label("Burrow's loader settings are damaged, so the loader loads no tweaks until they are fixed. Codling leaves them alone.",
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
            }
        } else if state.format != BurrowState.knownFormat {
            Section {
                Text("This Burrow reports its settings in a newer form. Update Codling to change them here.")
            }
        }

        let events = state.safeModeEvents.filter(state.isStillOff)
        if !events.isEmpty {
            Section {
                ForEach(Array(events.prefix(10).enumerated()), id: \.offset) { _, event in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(eventTitle(event))
                        Text(event.text)
                            .font(.footnote)
                            .foregroundColor(.secondary)
                            .textSelection(.enabled)
                        Button(event.tweak == BurrowState.everyTweak ? "Turn Every Tweak Back On" : "Turn Back On") {
                            Task { await model.setTweak(event.tweak, on: true, in: event.process, origin: Self.origin) }
                        }
                        .buttonStyle(.borderless)
                        .disabled(!state.canChangeSettings || model.working != nil)
                    }
                    .padding(.vertical, 2)
                }
            } header: {
                Text("Turned Off by Safe Mode")
            } footer: {
                Text("Safe Mode turns a tweak off in the app it crashed, and nowhere else.")
            }
        }

        Section {
            if state.tweaks.isEmpty {
                Text("No tweaks are installed.")
                    .foregroundColor(.secondary)
            }
            ForEach(state.tweaks) { tweak in
                NavigationLink {
                    TweakSettingsView(model: model, tweakName: tweak.name)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(tweak.displayName)
                        Text(summary(of: tweak))
                            .font(.footnote)
                            .foregroundColor(state.isOffEverywhere(tweak.name) || !state.placesOff(tweak.name).isEmpty
                                             ? .orange : .secondary)
                    }
                }
            }
        } header: {
            Text("Tweaks")
        }
    }

    private func summary(of tweak: BurrowState.Tweak) -> String {
        if state.isOffEverywhere(tweak.name) {
            return "Off everywhere"
        }
        let places = state.placesOff(tweak.name)
        switch places.count {
        case 0: return "On"
        case 1: return "Off in \(model.name(of: places[0].process))"
        default: return "Off in \(places.count) places"
        }
    }

    private func eventTitle(_ event: BurrowState.Event) -> String {
        let named = state.tweaks.first(where: { $0.name == event.tweak })?.displayName ?? event.tweak
        let what = event.tweak == BurrowState.everyTweak ? "Every tweak" : named
        let when = event.date.map { ", \(Self.format($0))" } ?? ""
        return "\(what) in \(model.name(of: event.process))\(when)"
    }

    static func format(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
    }
}

/// One tweak: where it loads, where it is off, and the switches.
struct TweakSettingsView: View {
    @ObservedObject var model: BurrowModel
    let tweakName: String
    @State private var choosingApp = false

    private var origin: String { "tweak:" + tweakName }

    var body: some View {
        List {
            if let state = model.state, let tweak = state.tweaks.first(where: { $0.name == tweakName }) {
                content(state: state, tweak: tweak)
            } else {
                Text("This tweak is no longer installed.")
                    .foregroundColor(.secondary)
            }
        }
        .navigationTitle(model.state?.tweaks.first(where: { $0.name == tweakName })?.displayName ?? tweakName)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await model.load() }
        .sheet(isPresented: $choosingApp) {
            if let state = model.state, let tweak = state.tweaks.first(where: { $0.name == tweakName }) {
                AppChooserView(model: model, state: state, tweak: tweak) { process in
                    choosingApp = false
                    Task { await model.setTweak(tweak.name, on: false, in: process, origin: origin) }
                }
            }
        }
        .burrowOutcomeAlert(model: model, origin: origin)
        .overlay(alignment: .bottom) { BurrowWorkingBanner(text: model.working) }
    }

    @ViewBuilder
    private func content(state: BurrowState, tweak: BurrowState.Tweak) -> some View {
        let offEverywhere = state.isOffEverywhere(tweak.name)
        let places = state.placesOff(tweak.name)
        let canChange = state.canChangeSettings && model.working == nil

        Section {
            if tweak.displayName != tweak.name {
                detail("File", tweak.name + ".dylib")
            }
            if let package = tweak.package {
                detail("Package", [package, tweak.packageVersion].compactMap { $0 }.joined(separator: " "))
            }
            detail("Loads into", reach(of: tweak))
            if tweak.manager {
                Text("This is a tweak manager: it decides about other tweaks, and loads before them.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
        }

        Section {
            Toggle("On Everywhere", isOn: Binding(
                get: { !offEverywhere },
                set: { on in
                    Task { await model.setTweak(tweak.name, on: on, in: BurrowState.everyTweak, origin: origin) }
                }))
                .disabled(!canChange || state.disabledEverywhere.contains(BurrowState.everyTweak))
        } footer: {
            if offEverywhere {
                Text("Off in every process. Turn it on everywhere before turning it on in one app.")
            } else {
                Text("Turning it off everywhere keeps the apps below as they are.")
            }
        }

        Section {
            if places.isEmpty {
                Text("Not turned off in any app.")
                    .foregroundColor(.secondary)
            }
            ForEach(places) { place in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.name(of: place.process))
                        if place.everyTweak {
                            Text("Every tweak is off here")
                                .font(.footnote)
                                .foregroundColor(.secondary)
                        } else if model.name(of: place.process) != place.process {
                            Text(place.process)
                                .font(.footnote)
                                .foregroundColor(.secondary)
                        }
                    }
                    Spacer()
                    Button(place.everyTweak ? "Turn All On" : "Turn On") {
                        Task {
                            await model.setTweak(place.everyTweak ? BurrowState.everyTweak : tweak.name, on: true,
                                                 in: place.process, origin: origin)
                        }
                    }
                    .buttonStyle(.borderless)
                    .disabled(!canChange || offEverywhere)
                }
                .accessibilityElement(children: .combine)
            }
            Button {
                choosingApp = true
            } label: {
                Label("Turn Off in an App", systemImage: "minus.circle")
            }
            .disabled(!canChange || offEverywhere)
        } header: {
            Text("Turned Off In")
        } footer: {
            if !state.usesBurrowLoader {
                Text("These settings take effect once Burrow's loader loads the tweaks.")
            }
        }
    }

    private func reach(of tweak: BurrowState.Tweak) -> String {
        switch tweak.reach {
        case .everyProcess:
            return "Every process, apps and system services alike"
        case .everyApp:
            return "Every app"
        case .nothing:
            return "Nothing: its filter names no process"
        case .named:
            var names = tweak.namedTargets.map { model.name(of: $0) }
            if !tweak.classes.isEmpty {
                names.append("processes with the classes " + tweak.classes.joined(separator: ", "))
            }
            return names.joined(separator: ", ")
        }
    }

    private func detail(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.footnote)
                .foregroundColor(.secondary)
            Text(value)
                .textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Picks the app, or the process the tweak's filter names, to turn the tweak
/// off in.
private struct AppChooserView: View {
    @ObservedObject var model: BurrowModel
    let state: BurrowState
    let tweak: BurrowState.Tweak
    let choose: (String) -> Void
    @State private var query = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            List {
                let off = Set(state.placesOff(tweak.name).map(\.process))
                let named = tweak.namedTargets.filter { !off.contains($0) && matches($0) }
                if !named.isEmpty {
                    Section {
                        ForEach(named, id: \.self) { process in
                            choice(process)
                        }
                    } header: {
                        Text("Named by the tweak")
                    }
                }
                if tweak.mayLoadIntoAnyApp(installedApps: Set(model.apps.map(\.id))) {
                    let namedSet = Set(named)
                    let apps = model.apps.filter { !off.contains($0.id) && !namedSet.contains($0.id) && matches($0.id) }
                    Section {
                        if model.apps.isEmpty {
                            Text("Codling could not list the apps on this device.")
                                .foregroundColor(.secondary)
                        }
                        ForEach(apps) { app in
                            choice(app.id)
                        }
                    } header: {
                        Text("Apps")
                    }
                }
            }
            .searchable(text: $query)
            .navigationTitle("Turn Off In")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func matches(_ process: String) -> Bool {
        let text = query.trimmingCharacters(in: .whitespaces)
        return text.isEmpty || model.name(of: process).localizedCaseInsensitiveContains(text)
            || process.localizedCaseInsensitiveContains(text)
    }

    private func choice(_ process: String) -> some View {
        Button {
            choose(process)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.name(of: process))
                    .foregroundColor(.primary)
                if model.name(of: process) != process {
                    Text(process)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            }
        }
    }
}

/// A small banner while a change runs.
private struct BurrowWorkingBanner: View {
    let text: String?

    var body: some View {
        if let text {
            HStack(spacing: 8) {
                ProgressView()
                Text(text)
                    .font(.footnote)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: Capsule())
            .padding(.bottom, 12)
            .accessibilityElement(children: .combine)
        }
    }
}

private extension View {
    func burrowOutcomeAlert(model: BurrowModel, origin: String) -> some View {
        alert(item: Binding(get: { model.outcome?.origin == origin ? model.outcome : nil },
                            set: { model.outcome = $0 })) { outcome in
            if outcome.offersRespring {
                return Alert(title: Text(outcome.title), message: Text(outcome.message),
                             primaryButton: .default(Text("Restart SpringBoard")) {
                                 Task { await model.respring() }
                             },
                             secondaryButton: .cancel(Text("Later")))
            }
            return Alert(title: Text(outcome.title), message: Text(outcome.message), dismissButton: .default(Text("OK")))
        }
    }
}
