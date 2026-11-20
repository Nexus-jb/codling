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
            switch BurrowState.decode(output: command.output) {
            case .success(let state):
                phase = .ready(state)
            case .failure(let error):
                phase = .failed("Burrow's report could not be read. \(error.detail)")
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
        ScrollView {
            VStack(spacing: 12) {
                switch model.phase {
                case .loading:
                    Card(padding: 14) {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("Asking Burrow")
                                .foregroundColor(.secondary)
                        }
                    }
                case .notInstalled:
                    Card(padding: 14) {
                        ToolHeader(symbol: "puzzlepiece.extension", color: .gray, title: "Burrow is not installed") {
                            ToolNote(text: "Burrow loads tweaks into apps, with Safe Mode, which turns off a tweak that crashes an app in that app only. Once Burrow is installed, its settings appear here.")
                        }
                    }
                case .failed(let message):
                    Card(padding: 14) {
                        ToolHeader(symbol: "xmark.octagon", color: .red, title: "Burrow did not answer") {
                            Text(message)
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Button("Try Again") {
                            Task { await model.load() }
                        }
                        .buttonStyle(TintedButtonStyle())
                        .padding(.top, 12)
                    }
                case .ready(let state):
                    BurrowStateSections(model: model, state: state)
                }
            }
            .toolColumn()
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
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
    @State private var showsSafeMode = false
    @State private var showsTweaks = false

    var body: some View {
        loaderCard

        if state.settings == "invalid" {
            Card(padding: 14) {
                ToolHeader(symbol: "exclamationmark.triangle", color: .orange, title: "Damaged settings") {
                    ToolNote(text: "Burrow's loader settings are damaged, so the loader loads no tweaks until they are fixed. Codling leaves them alone.")
                }
            }
        } else if state.format != BurrowState.knownFormat {
            Card(padding: 14) {
                ToolHeader(symbol: "arrow.down.circle", color: .orange, title: "A newer Burrow") {
                    ToolNote(text: "This Burrow reports its settings in a newer form. Update Codling to change them here.")
                }
            }
        }

        let events = state.safeModeEvents.filter(state.isStillOff)
        if !events.isEmpty {
            CollapsibleCardHeading(title: "Turned Off by Safe Mode", symbol: "shield.lefthalf.filled",
                                   count: events.count, expanded: $showsSafeMode)
                .padding(.top, 8)
            if showsSafeMode {
                ForEach(Array(events.prefix(10).enumerated()), id: \.offset) { _, event in
                    Card(padding: 14) {
                        ToolHeader(symbol: "exclamationmark.shield", color: .orange, title: eventTitle(event)) {
                            Text(event.text)
                                .font(.footnote)
                                .foregroundColor(.secondary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Button(event.tweak == BurrowState.everyTweak ? "Turn Every Tweak Back On" : "Turn Back On") {
                            Task { await model.setTweak(event.tweak, on: true, in: event.process, origin: Self.origin) }
                        }
                        .buttonStyle(TintedButtonStyle())
                        .disabled(!state.canChangeSettings || model.working != nil)
                        .padding(.top, 12)
                    }
                }
                CardFooter(text: events.count > 10
                           ? "The latest 10 are shown. Safe Mode turns a tweak off in the app it crashed, and nowhere else."
                           : "Safe Mode turns a tweak off in the app it crashed, and nowhere else.")
            }
        }

        if state.tweaks.isEmpty {
            CardHeading(title: "Tweaks", symbol: "puzzlepiece.extension")
                .padding(.top, 8)
            Card(padding: 14) {
                Text("No tweaks are installed.")
                    .foregroundColor(.secondary)
            }
        } else {
            CollapsibleCardHeading(title: "Tweaks", symbol: "puzzlepiece.extension",
                                   count: state.tweakGroups.count, expanded: $showsTweaks)
                .padding(.top, 8)
            if showsTweaks {
                // A package's tweaks, such as one for SpringBoard and one for
                // an app, are one row.
                CardRows(items: state.tweakGroups, dividerInset: 66) { group in
                    NavigationLink {
                        PackageTweaksView(model: model, groupID: group.id)
                    } label: {
                        HStack(spacing: 12) {
                            IconTile(symbol: "puzzlepiece.extension.fill",
                                     color: group.tweaks.contains(where: isOffSomewhere) ? .orange : .blue, size: 38)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(group.title)
                                    .font(.body.weight(.semibold))
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                                // One line for each of the package's tweaks.
                                ForEach(group.tweaks) { tweak in
                                    Text(line(for: tweak, alone: group.tweaks.count == 1))
                                        .font(.footnote)
                                        .foregroundColor(isOffSomewhere(tweak) ? .orange : .secondary)
                                }
                            }
                            Spacer(minLength: 6)
                            Chevron()
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                    }
                    .buttonStyle(CardRowButtonStyle())
                }
            }
        }
    }

    private var loaderCard: some View {
        Card(padding: 14) {
            ToolHeader(symbol: "bolt.horizontal.circle", color: .blue, title: "Loader") {
                VStack(spacing: 6) {
                    row("Tweak loader", state.loader)
                    row("Safe Mode", state.safeModeSince.map { "On since \(Self.format($0))" } ?? "Off")
                }
                if let until = state.trialUntil {
                    ToolNote(text: "Burrow watches SpringBoard closely until \(Self.format(until)), and goes back to ElleKit's loader by itself if SpringBoard crashes twice.")
                        .padding(.top, 2)
                }
                if let back = state.wentBack {
                    ToolNote(text: "Burrow went back to ElleKit's loader\(back.date.map { " on \(Self.format($0))" } ?? ""): \(back.reason)")
                        .padding(.top, 2)
                }
                if !state.usesBurrowLoader {
                    ToolNote(text: "Burrow's settings below take effect once Burrow's loader loads the tweaks.")
                        .padding(.top, 2)
                }
            }
            if state.loader == "Burrow" || state.loader == "ElleKit" {
                Button(state.usesBurrowLoader ? "Go Back to ElleKit's Loader" : "Use Burrow's Loader") {
                    confirmingLoader = true
                }
                .buttonStyle(TintedButtonStyle())
                .disabled(model.working != nil)
                .padding(.top, 12)
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
        }
    }

    private func isOffSomewhere(_ tweak: BurrowState.Tweak) -> Bool {
        state.isOffEverywhere(tweak.name) || !state.placesOff(tweak.name).isEmpty
    }

    /// "PowerSelectorApp · On"; just "On" for a package's only tweak named
    /// as the package is.
    private func line(for tweak: BurrowState.Tweak, alone: Bool) -> String {
        alone && tweak.displayName == tweak.name ? summary(of: tweak) : "\(tweak.name) · \(summary(of: tweak))"
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
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .foregroundColor(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .multilineTextAlignment(.trailing)
        }
        .font(.subheadline)
        .accessibilityElement(children: .combine)
    }
}

/// One package's tweaks: for each, where it loads, where it is off, and
/// the switches.
struct PackageTweaksView: View {
    @ObservedObject var model: BurrowModel
    let groupID: String
    @State private var choosingFor: BurrowState.Tweak?

    private var origin: String { "package:" + groupID }

    private var group: BurrowState.TweakGroup? {
        model.state?.tweakGroups.first { $0.id == groupID }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                if let state = model.state, let group {
                    content(state: state, group: group)
                } else {
                    Card(padding: 14) {
                        Text("This tweak is no longer installed.")
                            .foregroundColor(.secondary)
                    }
                }
            }
            .toolColumn()
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .navigationTitle(group?.title ?? "Tweak")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await model.load() }
        .sheet(item: $choosingFor) { tweak in
            if let state = model.state {
                AppChooserView(model: model, state: state, tweak: tweak) { process in
                    choosingFor = nil
                    Task { await model.setTweak(tweak.name, on: false, in: process, origin: origin) }
                }
            }
        }
        .burrowOutcomeAlert(model: model, origin: origin)
        .overlay(alignment: .bottom) { BurrowWorkingBanner(text: model.working) }
    }

    @ViewBuilder
    private func content(state: BurrowState, group: BurrowState.TweakGroup) -> some View {
        Card(padding: 14) {
            ToolHeader(symbol: "puzzlepiece.extension.fill", color: .blue, title: group.title) {
                if let package = group.tweaks.first?.package {
                    Text([package, group.tweaks.first?.packageVersion].compactMap { $0 }.joined(separator: " "))
                        .font(.footnote.monospaced())
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                }
                if group.tweaks.count > 1 {
                    ToolNote(text: "This package installs \(group.tweaks.count) tweaks, each with its own settings below.")
                        .padding(.top, 2)
                }
            }
        }
        ForEach(group.tweaks) { tweak in
            tweakCard(state: state, tweak: tweak, named: group.tweaks.count > 1 || tweak.displayName != tweak.name)
        }
    }

    private func tweakCard(state: BurrowState, tweak: BurrowState.Tweak, named: Bool) -> some View {
        let offEverywhere = state.isOffEverywhere(tweak.name)
        let places = state.placesOff(tweak.name)
        let canChange = state.canChangeSettings && model.working == nil
        return Card(padding: 14) {
            ToolHeader(symbol: "slider.horizontal.3", color: offEverywhere ? .orange : .indigo,
                       title: named ? tweak.name : "Settings") {
                Text("Loads into: \(reach(of: tweak))")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if tweak.manager {
                    ToolNote(text: "This is a tweak manager: it decides about other tweaks, and loads before them.")
                        .padding(.top, 2)
                }
            }

            VStack(spacing: 0) {
                Toggle("On Everywhere", isOn: Binding(
                    get: { !offEverywhere },
                    set: { on in
                        Task { await model.setTweak(tweak.name, on: on, in: BurrowState.everyTweak, origin: origin) }
                    }))
                    .font(.subheadline.weight(.semibold))
                    .disabled(!canChange || state.disabledEverywhere.contains(BurrowState.everyTweak))
                    .padding(.vertical, 8)
                ForEach(places) { place in
                    Divider()
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Off in \(model.name(of: place.process))")
                                .font(.subheadline.weight(.semibold))
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
                        .font(.subheadline.weight(.semibold))
                        .buttonStyle(.borderless)
                        .disabled(!canChange || offEverywhere)
                    }
                    .padding(.vertical, 8)
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(.horizontal, 12)
            .background(Color(.tertiarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .padding(.top, 12)

            Button {
                choosingFor = tweak
            } label: {
                Label("Turn Off in an App", systemImage: "minus.circle")
            }
            .buttonStyle(TintedButtonStyle())
            .disabled(!canChange || offEverywhere)
            .padding(.top, 12)

            if let note = footer(state: state, offEverywhere: offEverywhere, places: places) {
                ToolNote(text: note)
                    .padding(.top, 10)
            }
        }
    }

    private func footer(state: BurrowState, offEverywhere: Bool, places: [BurrowState.OffPlace]) -> String? {
        if offEverywhere {
            return "Off in every process. Turn it on everywhere before turning it on in one app."
        } else if !state.usesBurrowLoader {
            return "These settings take effect once Burrow's loader loads the tweaks."
        } else if !places.isEmpty {
            return "Turning it off everywhere keeps the apps above as they are."
        }
        return nil
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
            ScrollView {
                VStack(spacing: 10) {
                    let off = Set(state.placesOff(tweak.name).map(\.process))
                    let named = tweak.namedTargets.filter { !off.contains($0) && matches($0) }
                    if !named.isEmpty {
                        CardHeading(title: "Named by the tweak", symbol: "scope")
                        CardRows(items: named.map(Choice.init), dividerInset: 62) { choice in
                            row(choice.id, symbol: "gearshape.2.fill", color: .gray)
                        }
                    }
                    if tweak.mayLoadIntoAnyApp(installedApps: Set(model.apps.map(\.id))) {
                        let namedSet = Set(named)
                        let apps = model.apps.filter { !off.contains($0.id) && !namedSet.contains($0.id) && matches($0.id) }
                        CardHeading(title: "Apps", symbol: "square.grid.2x2")
                            .padding(.top, named.isEmpty ? 0 : 8)
                        if model.apps.isEmpty {
                            Card(padding: 14) {
                                Text("Codling could not list the apps on this device.")
                                    .foregroundColor(.secondary)
                            }
                        } else if !apps.isEmpty {
                            CardRows(items: apps.map { Choice(id: $0.id) }, dividerInset: 62) { choice in
                                row(choice.id, symbol: "app.fill", color: .blue)
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
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

    private struct Choice: Identifiable {
        let id: String
    }

    private func row(_ process: String, symbol: String, color: Color) -> some View {
        Button {
            choose(process)
        } label: {
            HStack(spacing: 12) {
                IconTile(symbol: symbol, color: color, size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.name(of: process))
                        .font(.body.weight(.semibold))
                    if model.name(of: process) != process {
                        Text(process)
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
        }
        .buttonStyle(CardRowButtonStyle())
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
