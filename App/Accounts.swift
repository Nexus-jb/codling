// SPDX-License-Identifier: Apache-2.0

import AuthenticationServices
import LocalAuthentication
import Security
import SwiftUI

/// The sign-ins kept in the Keychain, one per payment provider: the token
/// that says who the user is, and the payment secret, which only comes out
/// after Face ID, Touch ID or the passcode, so that no tweak can buy on the
/// user's behalf.
enum PaymentKeychain {
    private static let service = "com.nexusjb.codling.payment"

    enum Failure: Error {
        case status(OSStatus)

        var message: String {
            switch self {
            case .status(let status):
                let text = SecCopyErrorMessageString(status, nil) as String? ?? "error \(status)"
                return "The Keychain did not keep the sign-in: \(text)."
            }
        }
    }

    static func saveToken(_ token: String, for endpoint: URL) throws {
        try save(Data(token.utf8), account: "token " + endpoint.absoluteString, protected: false)
    }

    static func token(for endpoint: URL) -> String? {
        read(account: "token " + endpoint.absoluteString, context: nil).map { String(decoding: $0, as: UTF8.self) }
    }

    /// Keeps the payment secret behind the device's owner check. Fails on a
    /// device without a passcode, where it could not be protected.
    static func saveSecret(_ secret: String, for endpoint: URL) throws {
        try save(Data(secret.utf8), account: "secret " + endpoint.absoluteString, protected: true)
    }

    /// The payment secret, after the system asks for Face ID, Touch ID or
    /// the passcode with the reason given. Blocks while it asks, so it runs
    /// away from the main thread.
    static func secret(for endpoint: URL, reason: String) -> String? {
        let context = LAContext()
        context.localizedReason = reason
        return read(account: "secret " + endpoint.absoluteString, context: context)
            .map { String(decoding: $0, as: UTF8.self) }
    }

    static func hasSecret(for endpoint: URL) -> Bool {
        let context = LAContext()
        context.interactionNotAllowed = true
        var query = baseQuery(account: "secret " + endpoint.absoluteString)
        query[kSecUseAuthenticationContext as String] = context
        query[kSecReturnAttributes as String] = true
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        // An item that needs the owner check answers "interaction not
        // allowed" without asking, which still says it is there.
        return status == errSecSuccess || status == errSecInteractionNotAllowed
    }

    static func delete(for endpoint: URL) {
        for account in ["token ", "secret "] {
            SecItemDelete(baseQuery(account: account + endpoint.absoluteString) as CFDictionary)
        }
    }

    private static func baseQuery(account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    private static func save(_ data: Data, account: String, protected: Bool) throws {
        SecItemDelete(baseQuery(account: account) as CFDictionary)
        var item = baseQuery(account: account)
        item[kSecValueData as String] = data
        if protected {
            var error: Unmanaged<CFError>?
            guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly,
                                                               .userPresence, &error) else {
                throw Failure.status(errSecParam)
            }
            item[kSecAttrAccessControl as String] = access
        } else {
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        }
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw Failure.status(status) }
    }

    private static func read(account: String, context: LAContext?) -> Data? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        if let context {
            query[kSecUseAuthenticationContext as String] = context
        }
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }
}

/// Requests to a payment provider, with the device's UDID and model as the
/// API asks for them.
struct PaymentClient {
    let udid: String
    let model: String
    let version: String
    /// The device's package architecture, such as iphoneos-arm64: what a
    /// download asks for when the package's own is not known.
    let architecture: String

    private var session: URLSession { .shared }

    func endpoint(of source: Source) async -> URL? {
        for url in source.repositoryFileURLs("payment_endpoint") {
            var request = URLRequest(url: url, timeoutInterval: 15)
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            guard let (data, response) = try? await session.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200, data.count < 4096,
                  let text = String(data: data, encoding: .utf8),
                  let endpoint = PaymentProvider.endpoint(fromFile: text) else { continue }
            return endpoint
        }
        return nil
    }

    func info(_ endpoint: URL) async throws -> PaymentProvider.Info {
        let url = PaymentProvider.url(endpoint, "info")
        return try PaymentProvider.info(try await get(url), base: endpoint)
    }

    func user(_ endpoint: URL, token: String) async throws -> PaymentProvider.User {
        try PaymentProvider.user(try await post(PaymentProvider.url(endpoint, "user_info"),
                                                ["token": token, "udid": udid, "device": model]))
    }

    func signOut(_ endpoint: URL, token: String) async {
        _ = try? await post(PaymentProvider.url(endpoint, "sign_out"), ["token": token])
    }

    /// A paid package's price, and with a token whether the user bought it.
    func price(_ endpoint: URL, package: String, token: String?) async throws -> PaymentProvider.Price {
        var body = ["udid": udid, "device": model]
        body["token"] = token
        let url = PaymentProvider.url(endpoint, PaymentProvider.packagePath(package, "info"))
        return try PaymentProvider.price(try await post(url, body))
    }

    func purchase(_ endpoint: URL, package: String, token: String, secret: String?) async throws -> PaymentProvider.Purchase {
        var body = ["token": token, "udid": udid, "device": model]
        body["payment_secret"] = secret
        let url = PaymentProvider.url(endpoint, PaymentProvider.packagePath(package, "purchase"))
        return try PaymentProvider.purchase(try await post(url, body, timeout: 60))
    }

    /// The single-use address of a bought package's file. architecture is
    /// the Architecture field of the record apt lists, as Zebra sends it, so
    /// that a provider with builds for several jailbreaks (rootless,
    /// roothide, rootful) sends the one this device uses, and finds a build
    /// for "all" too.
    func authorizeDownload(_ endpoint: URL, package: String, token: String, version: String, repo: String,
                           architecture packageArchitecture: String?) async throws -> URL {
        let url = PaymentProvider.url(endpoint, PaymentProvider.packagePath(package, "authorize_download"))
        let asked = packageArchitecture.flatMap { $0.isEmpty ? nil : $0 } ?? architecture
        return try PaymentProvider.downloadURL(try await post(url, ["token": token, "udid": udid, "device": model,
                                                                    "version": version, "repo": repo,
                                                                    "architecture": asked]))
    }

    func download(_ url: URL, to destination: URL) async throws {
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let file: URL
        let response: URLResponse
        do {
            (file, response) = try await session.download(for: request)
        } catch {
            throw PaymentProvider.Failure(message: RefreshError.describe(error))
        }
        defer { try? FileManager.default.removeItem(at: file) }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw PaymentProvider.Failure(message: "\(url.host ?? "The provider") answered \(http.statusCode) "
                                          + "(\(HTTPURLResponse.localizedString(forStatusCode: http.statusCode))) to the download.")
        }
        do {
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: file, to: destination)
        } catch {
            throw PaymentProvider.Failure(message: "Codling could not keep the download: \(error.localizedDescription)")
        }
    }

    private var userAgent: String { "Codling/\(version) (\(model); iOS)" }

    private func get(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("en", forHTTPHeaderField: "Accept-Language")
        return try await send(request)
    }

    private func post(_ url: URL, _ body: [String: String], timeout: TimeInterval = 20) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("en", forHTTPHeaderField: "Accept-Language")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await send(request)
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw PaymentProvider.Failure(message: RefreshError.describe(error))
        }
        // Providers answer errors as JSON with an error message, often with
        // a 4xx status; that message is the one to show.
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode),
           (try? JSONValue.decode(data)).flatMap(PaymentProvider.failure(in:)) == nil {
            throw PaymentProvider.Failure(message: "\(request.url?.host ?? "The provider") answered \(http.statusCode) "
                                          + "(\(HTTPURLResponse.localizedString(forStatusCode: http.statusCode))).")
        }
        return data
    }
}

/// Opens a provider's sign-in page in the system's sign-in sheet, which
/// returns to Codling at the provider's callback address.
final class WebSignIn: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?
    /// The window the sheet shows over, found when the sign-in starts.
    private var anchor = ASPresentationAnchor()

    /// The address the page returned to; nil when the user closed it.
    @MainActor
    func start(_ url: URL) async throws -> URL? {
        if let window = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap(\.windows)
            .first(where: \.isKeyWindow) {
            anchor = window
        }
        return try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: PaymentProvider.callbackScheme) { callback, error in
                if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
                    continuation.resume(returning: nil)
                } else if let error {
                    continuation.resume(throwing: PaymentProvider.Failure(message: "The sign-in page could not open: \(error.localizedDescription)"))
                } else {
                    continuation.resume(returning: callback)
                }
            }
            session.presentationContextProvider = self
            self.session = session
            if !session.start() {
                continuation.resume(throwing: PaymentProvider.Failure(message: "The sign-in page could not open."))
            }
        }
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        anchor
    }
}

/// The payment providers of the user's sources, and who is signed in to
/// each.
@MainActor
final class PaymentAccounts: ObservableObject {
    struct Provider: Identifiable, Equatable {
        let endpoint: URL
        /// The sources that name this provider.
        var sources: [SourceInfo]
        var info: PaymentProvider.Info?
        var state: State

        var id: String { endpoint.absoluteString }
        var name: String { info?.name ?? sources.first?.title ?? endpoint.host ?? "Provider" }
    }

    enum State: Equatable {
        case signedOut
        case working
        case signedIn(PaymentProvider.User)
        case failed(String)
    }

    @Published private(set) var providers: [Provider] = []
    @Published private(set) var discovering = false
    @Published private(set) var discovered = false
    /// Changes whenever a provider or a sign-in does, so that pages showing
    /// prices read them again.
    @Published private(set) var revision = 0

    private let environment: RuntimeEnvironment
    private let webSignIn = WebSignIn()
    /// The source addresses the providers were found for.
    private var discoveredFor: [String] = []
    /// The latest search for providers, which later callers wait for.
    private var discovery: (addresses: [String], task: Task<Void, Never>)?

    init(environment: RuntimeEnvironment) {
        self.environment = environment
    }

    private lazy var udid: String? = DeviceDetails.uniqueDeviceID()

    private var client: PaymentClient? {
        udid.map { PaymentClient(udid: $0, model: environment.deviceModel, version: environment.version,
                                 architecture: environment.architecture) }
    }

    /// The first signed-in user, for the account circle.
    var signedInUser: PaymentProvider.User? {
        for provider in providers {
            if case .signedIn(let user) = provider.state { return user }
        }
        return nil
    }

    /// Finds which sources have a payment provider, reads each provider's
    /// details, and checks the sign-ins Codling keeps. Waits for a search
    /// already under way for the same sources.
    func discover(sources: SourcesModel, force: Bool = false) async {
        let infos = sources.rows.compactMap { sources.info(for: $0.id) }
        let addresses = infos.map(\.source.uri).sorted()
        if let discovery, discovery.addresses == addresses {
            await discovery.task.value
            if !force { return }
        }
        guard force || addresses != discoveredFor else { return }
        let task = Task { await self.find(infos: infos, addresses: addresses) }
        discovery = (addresses, task)
        await task.value
    }

    private func find(infos: [SourceInfo], addresses: [String]) async {
        discovering = true
        defer {
            discovering = false
            discovered = true
            revision += 1
        }
        guard let client else {
            providers = []
            discoveredFor = addresses
            return
        }

        let found = await withTaskGroup(of: (SourceInfo, URL?).self) { group in
            for info in infos {
                group.addTask { (info, await client.endpoint(of: info.source)) }
            }
            var pairs: [(SourceInfo, URL)] = []
            for await (info, endpoint) in group {
                if let endpoint { pairs.append((info, endpoint)) }
            }
            return pairs
        }
        var byEndpoint: [String: Provider] = [:]
        for (info, endpoint) in found {
            byEndpoint[endpoint.absoluteString, default: Provider(endpoint: endpoint, sources: [], info: nil, state: .signedOut)]
                .sources.append(info)
        }
        var list = Array(byEndpoint.values)
        for index in list.indices {
            list[index].sources.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
            list[index].info = try? await client.info(list[index].endpoint)
            list[index].state = await state(of: list[index].endpoint, client: client)
        }
        // By name, so that no provider comes first for any other reason.
        providers = list.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        discoveredFor = addresses
    }

    private func state(of endpoint: URL, client: PaymentClient) async -> State {
        guard let token = PaymentKeychain.token(for: endpoint) else { return .signedOut }
        do {
            return .signedIn(try await client.user(endpoint, token: token))
        } catch let failure as PaymentProvider.Failure {
            if failure.invalidate {
                PaymentKeychain.delete(for: endpoint)
                return .signedOut
            }
            return .failed(failure.message)
        } catch {
            return .failed("\(error)")
        }
    }

    /// Signs in on the provider's page. Returns why it did not, if it did not.
    func signIn(_ provider: Provider) async -> String? {
        guard let client, let udid else {
            return "Codling could not read this device's UDID, which the provider needs to sign you in."
        }
        guard let url = PaymentProvider.authenticationURL(provider.endpoint, udid: udid, model: environment.deviceModel) else {
            return "The provider's sign-in address is not valid."
        }
        set(.working, for: provider.endpoint)
        do {
            guard let callback = try await webSignIn.start(url) else {
                // Closed without signing in: as it was before.
                set(await state(of: provider.endpoint, client: client), for: provider.endpoint)
                return nil
            }
            guard let credentials = PaymentProvider.credentials(fromCallback: callback) else {
                set(.signedOut, for: provider.endpoint)
                return "The provider's page did not return a sign-in."
            }
            try PaymentKeychain.saveToken(credentials.token, for: provider.endpoint)
            var note: String?
            if let secret = credentials.paymentSecret {
                do {
                    try PaymentKeychain.saveSecret(secret, for: provider.endpoint)
                } catch {
                    note = "You are signed in, but buying needs a passcode on this device, so that Codling can protect your payment secret."
                }
            }
            set(await state(of: provider.endpoint, client: client), for: provider.endpoint)
            return note
        } catch let failure as PaymentKeychain.Failure {
            set(.signedOut, for: provider.endpoint)
            return failure.message
        } catch let failure as PaymentProvider.Failure {
            set(.signedOut, for: provider.endpoint)
            return failure.message
        } catch {
            set(.signedOut, for: provider.endpoint)
            return "\(error)"
        }
    }

    func signOut(_ provider: Provider) async {
        if let token = PaymentKeychain.token(for: provider.endpoint), let client {
            set(.working, for: provider.endpoint)
            await client.signOut(provider.endpoint, token: token)
        }
        PaymentKeychain.delete(for: provider.endpoint)
        set(.signedOut, for: provider.endpoint)
    }

    func retry(_ provider: Provider) async {
        guard let client else { return }
        set(.working, for: provider.endpoint)
        set(await state(of: provider.endpoint, client: client), for: provider.endpoint)
    }

    private func set(_ state: State, for endpoint: URL) {
        guard let index = providers.firstIndex(where: { $0.endpoint == endpoint }) else { return }
        providers[index].state = state
        revision += 1
    }

    // MARK: Paid packages

    /// The provider of the source with this identifier, if it has one.
    func provider(forSource id: String) -> Provider? {
        providers.first { $0.sources.contains { $0.id == id } }
    }

    func provider(at endpoint: URL) -> Provider? {
        providers.first { $0.endpoint == endpoint }
    }

    func isSignedIn(_ provider: Provider) -> Bool {
        PaymentKeychain.token(for: provider.endpoint) != nil
    }

    private static let noDeviceID = "Codling could not read this device's UDID, which payment providers need."

    /// A paid package's price, and whether the signed-in user bought it.
    func price(of package: String, at provider: Provider) async throws -> PaymentProvider.Price {
        guard let client else { throw PaymentProvider.Failure(message: Self.noDeviceID) }
        do {
            return try await client.price(provider.endpoint, package: package,
                                          token: PaymentKeychain.token(for: provider.endpoint))
        } catch let failure as PaymentProvider.Failure where failure.invalidate {
            // The provider no longer knows the sign-in: forget it, and ask
            // as a guest.
            PaymentKeychain.delete(for: provider.endpoint)
            set(.signedOut, for: provider.endpoint)
            return try await client.price(provider.endpoint, package: package, token: nil)
        }
    }

    enum BuyOutcome: Equatable {
        /// The provider took the purchase, or the user left its payment
        /// page; the price says whether the package is bought now.
        case done
        case cancelled
        case failed(String)
    }

    /// Buys a package: Face ID, Touch ID or the passcode releases the payment
    /// secret, and the provider may ask the user to finish on its own page.
    func buy(_ package: String, name: String, at provider: Provider) async -> BuyOutcome {
        guard let client else { return .failed(Self.noDeviceID) }
        guard let token = PaymentKeychain.token(for: provider.endpoint) else {
            return .failed("Sign in to \(provider.name) to buy \(name).")
        }
        var secret: String?
        if PaymentKeychain.hasSecret(for: provider.endpoint) {
            let endpoint = provider.endpoint
            let reason = "Buy \(name) from \(provider.name)"
            secret = await Task.detached(priority: .userInitiated) {
                PaymentKeychain.secret(for: endpoint, reason: reason)
            }.value
            guard secret != nil else { return .cancelled }
        }
        do {
            switch try await client.purchase(provider.endpoint, package: package, token: token, secret: secret) {
            case .completed:
                break
            case .actionRequired(let url):
                _ = try await webSignIn.start(url)
            case .failed:
                return .failed("\(provider.name) did not complete the purchase. Check your account on \(provider.name)'s website.")
            }
            await refreshUser(provider)
            return .done
        } catch let failure as PaymentProvider.Failure {
            if failure.invalidate {
                PaymentKeychain.delete(for: provider.endpoint)
                set(.signedOut, for: provider.endpoint)
            }
            return .failed(failure.message)
        } catch {
            return .failed("\(error)")
        }
    }

    /// Reads the user's details again, as after a purchase, without
    /// showing the provider as busy.
    func refreshUser(_ provider: Provider) async {
        guard let client else { return }
        set(await state(of: provider.endpoint, client: client), for: provider.endpoint)
    }

    /// Downloads a bought package from the single-use address its provider
    /// gives, and has the helper check it against the hash apt lists and
    /// keep it where only root can write.
    func fetch(package: String, name: String, request: PurchaseRequest) async throws {
        guard let client else { throw PaymentProvider.Failure(message: Self.noDeviceID) }
        guard let token = PaymentKeychain.token(for: request.endpoint) else {
            throw PaymentProvider.Failure(message: "Sign in to \(request.providerName) to download \(name).")
        }
        let url = try await client.authorizeDownload(request.endpoint, package: package, token: token,
                                                     version: request.version, repo: request.repo,
                                                     architecture: request.architecture)
        try await client.download(url, to: PurchaseInbox.file(package: package, version: request.version))
        let version = request.version
        let taken = await Task.detached(priority: .userInitiated) {
            RootHelper.takePurchase(package, version: version)
        }.value
        if case .failure(let failure) = taken {
            throw PaymentProvider.Failure(message: failure.message)
        }
    }
}

/// Where Codling downloads a bought package for the helper to take. It must
/// match purchase_inbox in Helper/codling-helper.c, which builds the same
/// name itself.
enum PurchaseInbox {
    static let directory = URL(fileURLWithPath: "/var/mobile/Library/Caches/com.nexusjb.codling/purchases",
                               isDirectory: true)

    static func file(package: String, version: String) -> URL {
        directory.appendingPathComponent("\(package)_\(version.replacingOccurrences(of: ":", with: "%3a")).deb")
    }
}

/// What the queue needs to download a bought package: its provider, the
/// source it comes from, and the version.
struct PurchaseRequest: Equatable {
    let endpoint: URL
    let providerName: String
    /// The source's address, which the provider is told.
    let repo: String
    let version: String
    /// The record's Architecture field: this device's (iphoneos-arm64 when
    /// rootless, iphoneos-arm64e with RootHide) or "all", as Codling's index
    /// keeps only those.
    let architecture: String?
}

// MARK: Screens

/// A person's circle: their initials on glass, or a person when no one is
/// signed in.
struct AccountCircle: View {
    let user: PaymentProvider.User?
    var size: CGFloat = 46

    var body: some View {
        ZStack {
            if let initials = user.flatMap({ PaymentProvider.initials(name: $0.name, email: $0.email) }) {
                Text(initials)
                    .font(.system(size: size * 0.38, weight: .bold, design: .rounded)) // fixed: initials sized to the circle
                    .foregroundColor(Palette.text)
            } else {
                Image(systemName: "person.fill")
                    .font(.system(size: size * 0.42, weight: .semibold)) // fixed: a symbol sized to the circle
                    .foregroundColor(Palette.text)
            }
        }
        .frame(width: size, height: size)
        .glassSurface(cornerRadius: size / 2, inset: true)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(user.map { "Account, signed in as \($0.name ?? $0.email ?? "you")" } ?? "Accounts, not signed in")
    }
}

/// The accounts of the user's sources: for each source that sells
/// packages, its provider, and signing in or out of it.
struct AccountsView: View {
    @EnvironmentObject private var accounts: PaymentAccounts
    @EnvironmentObject private var sources: SourcesModel
    @State private var note: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                if accounts.providers.isEmpty {
                    Card(padding: 14) {
                        if accounts.discovering || !accounts.discovered {
                            HStack(spacing: 8) {
                                ProgressView()
                                Text("Finding the sources that sell packages")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                            }
                        } else {
                            ToolHeader(symbol: "person.crop.circle", color: .blue, title: "No accounts") {
                                ToolNote(text: "None of your sources sells packages, so there is no account to sign in to.")
                            }
                        }
                    }
                }
                ForEach(accounts.providers) { provider in
                    ProviderCard(provider: provider) { message in
                        note = message
                    }
                }
                if !accounts.providers.isEmpty {
                    CardFooter(text: "You sign in on each provider's own page. Codling keeps the sign-in in this device's Keychain, sends it only to that provider, and asks for Face ID, Touch ID or your passcode before it uses your payment details.")
                }
            }
            .toolColumn()
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .background(WallBackground())
        .navigationTitle("Accounts")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await accounts.discover(sources: sources, force: true) }
        .task { await accounts.discover(sources: sources) }
        .alert("Accounts", isPresented: Binding(get: { note != nil }, set: { if !$0 { note = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(note ?? "")
        }
    }
}

private struct ProviderCard: View {
    let provider: PaymentAccounts.Provider
    let report: (String) -> Void
    @EnvironmentObject private var accounts: PaymentAccounts

    var body: some View {
        Card(padding: 14) {
            HStack(alignment: .top, spacing: 12) {
                RemoteImage(urls: [provider.info?.icon].compactMap { $0 } + (provider.sources.first?.iconURLs ?? []),
                            maxPixels: 150) {
                    IconTile(symbol: "storefront", color: .blue, size: 44)
                }
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(provider.name)
                        .font(.headline)
                    if let names = sourceNames {
                        Text(names)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                    }
                    if let description = provider.info?.description {
                        ToolNote(text: description)
                            .padding(.top, 2)
                    }
                }
                Spacer(minLength: 0)
            }
            status
                .padding(.top, 12)
        }
    }

    /// The sources that use this provider, unless that is only the
    /// provider's own name.
    private var sourceNames: String? {
        let names = provider.sources.map(\.title)
        if names.count == 1, names[0].caseInsensitiveCompare(provider.name) == .orderedSame {
            return nil
        }
        return names.joined(separator: ", ")
    }

    /// The provider's sign-in prompt, unless its description already says
    /// the same.
    private var signInPrompt: String? {
        guard let message = provider.info?.bannerMessage else {
            return provider.info?.description == nil
                ? "Sign in to buy packages from \(provider.name) and to download the ones you bought." : nil
        }
        return message.caseInsensitiveCompare(provider.info?.description ?? "") == .orderedSame ? nil : message
    }

    @ViewBuilder
    private var status: some View {
        switch provider.state {
        case .working:
            HStack(spacing: 8) {
                ProgressView()
                Text("Working")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
        case .signedIn(let user):
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    AccountCircle(user: user, size: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(user.name ?? user.email ?? "Signed in")
                            .font(.subheadline.weight(.semibold))
                        if let email = user.email, user.name != nil {
                            Text(email)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Text(user.purchases.count == 1 ? "1 package bought" : "\(user.purchases.count) packages bought")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundColor(Palette.green)
                        .accessibilityLabel("Signed in")
                }
                Button("Sign Out") {
                    Task { await accounts.signOut(provider) }
                }
                .buttonStyle(TintedButtonStyle(color: .red))
            }
        case .signedOut:
            VStack(alignment: .leading, spacing: 10) {
                if let prompt = signInPrompt {
                    ToolNote(text: prompt)
                }
                Button(provider.info?.bannerButton.map { $0.capitalized } ?? "Sign In") {
                    Task {
                        if let message = await accounts.signIn(provider) {
                            report(message)
                        }
                    }
                }
                .buttonStyle(TintedButtonStyle())
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 10) {
                StatusLine(symbol: "exclamationmark.triangle.fill", text: "The account could not be checked", color: .orange)
                ToolNote(text: message)
                HStack(spacing: 8) {
                    Button("Try Again") {
                        Task { await accounts.retry(provider) }
                    }
                    .buttonStyle(TintedButtonStyle())
                    Button("Sign Out") {
                        Task { await accounts.signOut(provider) }
                    }
                    .buttonStyle(TintedButtonStyle(color: .red))
                }
            }
        }
    }
}
