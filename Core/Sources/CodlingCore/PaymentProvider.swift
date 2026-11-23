// SPDX-License-Identifier: Apache-2.0

import Foundation

/// The payment provider API that sources use for accounts and paid
/// packages, as Sileo documents it (developer.getsileo.app/payment-providers):
/// a source names its provider in a `payment_endpoint` file, and the
/// provider answers JSON at fixed paths under that address.
public enum PaymentProvider {
    /// The provider's address from a source's `payment_endpoint` file: one
    /// HTTPS address, which the paths below are added to. Nil for anything
    /// else, since providers must use HTTPS.
    public static func endpoint(fromFile text: String) -> URL? {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        guard !line.isEmpty, var components = URLComponents(string: line),
              components.scheme?.lowercased() == "https", let host = components.host, !host.isEmpty,
              components.query == nil, components.fragment == nil else {
            return nil
        }
        if !components.path.hasSuffix("/") {
            components.path += "/"
        }
        return components.url
    }

    /// Where to read a source's `payment_endpoint` file from: over HTTPS
    /// only, so that no one on the network can name another provider for
    /// the source. A source served over HTTP is asked at the same address
    /// over HTTPS.
    public static func endpointFileURLs(_ urls: [URL]) -> [URL] {
        var secure: [URL] = []
        for url in urls {
            guard var components = URLComponents(url: url, resolvingAgainstBaseURL: true),
                  let scheme = components.scheme?.lowercased(), scheme == "https" || scheme == "http",
                  components.host?.isEmpty == false else { continue }
            if scheme == "http" {
                components.scheme = "https"
                if components.port == 80 {
                    components.port = nil
                }
            }
            if let upgraded = components.url, !secure.contains(upgraded) {
                secure.append(upgraded)
            }
        }
        return secure
    }

    /// Whether a request to a provider may follow a redirect: only to
    /// HTTPS, since the requests carry the user's token.
    public static func allowsRedirect(to url: URL?) -> Bool {
        url?.scheme?.lowercased() == "https" && url?.host?.isEmpty == false
    }

    /// How to ask for a package's price.
    public struct PriceRequest: Equatable {
        public var url: URL
        /// GET or POST.
        public var method: String
        /// The JSON fields of a POST; nil for a GET.
        public var body: [String: String]?
    }

    /// Signed out, a GET that says nothing about the device, as Zebra asks,
    /// so that a provider the user never signed in to does not learn the
    /// UDID. Signed in, a POST with the token and the device, which the
    /// provider needs to say whether the user bought the package.
    public static func priceRequest(_ endpoint: URL, package: String, token: String?, udid: String,
                                    device: String) -> PriceRequest {
        let address = Self.url(endpoint, packagePath(package, "info"))
        guard let token, !token.isEmpty else {
            return PriceRequest(url: address, method: "GET", body: nil)
        }
        return PriceRequest(url: address, method: "POST", body: ["token": token, "udid": udid, "device": device])
    }

    /// Signed out, for a provider that does not answer that GET (Havoc
    /// answers 404 there): a POST, as Sileo asks, with the device model
    /// only. The UDID still goes only to a provider the user signed in to.
    public static func signedOutPriceRetry(_ endpoint: URL, package: String, device: String) -> PriceRequest {
        PriceRequest(url: url(endpoint, packagePath(package, "info")), method: "POST", body: ["device": device])
    }

    /// The address of a path under the provider, such as "info" or
    /// "package/com.example.tweak/info". The package identifier is escaped.
    public static func url(_ endpoint: URL, _ path: String) -> URL {
        URL(string: path, relativeTo: endpoint)?.absoluteURL ?? endpoint.appendingPathComponent(path)
    }

    public static func packagePath(_ package: String, _ action: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~+"))
        let escaped = package.addingPercentEncoding(withAllowedCharacters: allowed) ?? package
        return "package/\(escaped)/\(action)"
    }

    /// The sign-in page, with the device's UDID and model.
    public static func authenticationURL(_ endpoint: URL, udid: String, model: String) -> URL? {
        var components = URLComponents(url: url(endpoint, "authenticate"), resolvingAgainstBaseURL: true)
        components?.queryItems = [URLQueryItem(name: "udid", value: udid), URLQueryItem(name: "model", value: model)]
        return components?.url
    }

    /// The scheme the sign-in and payment pages return to.
    public static let callbackScheme = "sileo"

    /// The token and payment secret from the address a sign-in page
    /// returns to: sileo://authentication_success?token=…&payment_secret=….
    public static func credentials(fromCallback url: URL) -> Credentials? {
        guard url.scheme?.lowercased() == callbackScheme, url.host == "authentication_success",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let token = items.first(where: { $0.name == "token" })?.value, !token.isEmpty else {
            return nil
        }
        let secret = items.first(where: { $0.name == "payment_secret" })?.value
        return Credentials(token: token, paymentSecret: secret?.isEmpty == false ? secret : nil)
    }

    /// Whether an address is where a payment page returns when it is done.
    public static func isPaymentCompleted(_ url: URL) -> Bool {
        url.scheme?.lowercased() == callbackScheme && url.host == "payment_completed"
    }

    public struct Credentials: Equatable {
        public var token: String
        public var paymentSecret: String?

        public init(token: String, paymentSecret: String?) {
            self.token = token
            self.paymentSecret = paymentSecret
        }
    }

    /// What a provider says about itself, from GET info.
    public struct Info: Equatable {
        public var name: String
        public var icon: URL?
        public var description: String?
        /// The sign-in prompt the provider asks to show, if any.
        public var bannerMessage: String?
        public var bannerButton: String?

        public init(name: String, icon: URL?, description: String?, bannerMessage: String?, bannerButton: String?) {
            self.name = name
            self.icon = icon
            self.description = description
            self.bannerMessage = bannerMessage
            self.bannerButton = bannerButton
        }
    }

    /// The signed-in user, from POST user_info.
    public struct User: Equatable {
        public var name: String?
        public var email: String?
        /// The identifiers of the packages the user bought.
        public var purchases: [String]

        public init(name: String?, email: String?, purchases: [String]) {
            self.name = name
            self.email = email
            self.purchases = purchases
        }
    }

    /// A paid package's price and whether the user has it, from POST
    /// package/…/info.
    public struct Price: Equatable {
        public var price: String?
        public var purchased: Bool
        public var available: Bool

        public init(price: String?, purchased: Bool, available: Bool) {
            self.price = price
            self.purchased = purchased
            self.available = available
        }
    }

    /// What a purchase came to, from POST package/…/purchase.
    public enum Purchase: Equatable {
        case completed
        /// The provider needs the user on a page, such as a checkout.
        case actionRequired(URL)
        case failed
    }

    /// An answer that says something went wrong.
    public struct Failure: Error, Equatable {
        public var message: String
        public var recoveryURL: URL?
        /// The provider asks Codling to forget the user's credentials.
        public var invalidate: Bool
        /// The provider itself answered with this, such as "not available
        /// for purchase", so asking again gives the same answer; false when
        /// the request did not get through or the answer could not be read.
        public var fromProvider: Bool

        public init(message: String, recoveryURL: URL? = nil, invalidate: Bool = false, fromProvider: Bool = false) {
            self.message = message
            self.recoveryURL = recoveryURL
            self.invalidate = invalidate
            self.fromProvider = fromProvider
        }
    }

    // MARK: Reading answers

    /// The failure an answer reports: an `error` message, or `success`
    /// false. Nil when the answer does not report one.
    public static func failure(in root: JSONValue) -> Failure? {
        let message = root["error"]?.string.flatMap { $0.isEmpty ? nil : $0 }
        let unsuccessful = root["success"]?.bool == false
        guard message != nil || unsuccessful else { return nil }
        return Failure(message: message ?? "The provider did not complete the request.",
                       recoveryURL: root["recovery_url"]?.string.flatMap(httpsURL),
                       invalidate: root["invalidate"]?.bool == true, fromProvider: true)
    }

    public static func info(_ data: Data, base: URL) throws -> Info {
        let root = try object(data)
        if let failure = failure(in: root) { throw failure }
        guard let name = root["name"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
            throw Failure(message: "The provider did not give its name.")
        }
        let banner = root["authentication_banner"]
        return Info(name: name,
                    icon: root["icon"]?.string.flatMap { URL(string: $0, relativeTo: base)?.absoluteURL }
                        .flatMap { ["http", "https"].contains($0.scheme?.lowercased() ?? "") ? $0 : nil },
                    description: nonEmpty(root["description"]?.string),
                    bannerMessage: nonEmpty(banner?["message"]?.string),
                    bannerButton: nonEmpty(banner?["button"]?.string))
    }

    public static func user(_ data: Data) throws -> User {
        let root = try object(data)
        if let failure = failure(in: root) { throw failure }
        let user = root["user"]
        return User(name: nonEmpty(user?["name"]?.string), email: nonEmpty(user?["email"]?.string),
                    purchases: (root["items"]?.array ?? []).compactMap { nonEmpty($0.string) })
    }

    public static func price(_ data: Data) throws -> Price {
        let root = try object(data)
        if let failure = failure(in: root) { throw failure }
        return Price(price: nonEmpty(root["price"]?.string), purchased: root["purchased"]?.bool ?? false,
                     available: root["available"]?.bool ?? true)
    }

    public static func purchase(_ data: Data) throws -> Purchase {
        let root = try object(data)
        if let failure = failure(in: root) { throw failure }
        switch root["status"]?.number {
        case 0?:
            return .completed
        case 1?:
            guard let url = root["url"]?.string.flatMap(httpsURL) else {
                throw Failure(message: "The provider asked for a step on its page but gave no HTTPS address for it.")
            }
            return .actionRequired(url)
        default:
            return .failed
        }
    }

    /// The single-use download address from POST package/…/authorize_download.
    public static func downloadURL(_ data: Data) throws -> URL {
        let root = try object(data)
        if let failure = failure(in: root) { throw failure }
        guard let url = root["url"]?.string.flatMap(httpsURL) else {
            throw Failure(message: "The provider gave no HTTPS address to download the package from.")
        }
        return url
    }

    private static func object(_ data: Data) throws -> JSONValue {
        guard let root = try? JSONValue.decode(data), root.isObject else {
            throw Failure(message: "The provider's answer is not the JSON Codling expects.")
        }
        return root
    }

    private static func httpsURL(_ text: String) -> URL? {
        guard let url = URL(string: text), url.scheme?.lowercased() == "https", url.host != nil else { return nil }
        return url
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }

    /// One or two letters for a person's circle: the first letters of the
    /// first two words of the name, or of the email address.
    public static func initials(name: String?, email: String?) -> String? {
        let words = (name ?? "").split(whereSeparator: { $0.isWhitespace || $0 == "." || $0 == "_" })
        let letters = words.prefix(2).compactMap { $0.first.map { String($0).uppercased() } }.joined()
        if !letters.isEmpty {
            return letters
        }
        return email?.first.map { String($0).uppercased() }
    }
}
