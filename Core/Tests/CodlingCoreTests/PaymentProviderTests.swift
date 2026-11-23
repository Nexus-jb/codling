// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import CodlingCore

final class PaymentProviderTests: XCTestCase {
    func testEndpointFile() {
        XCTAssertEqual(PaymentProvider.endpoint(fromFile: "https://my.chariz.io/\n")?.absoluteString, "https://my.chariz.io/")
        XCTAssertEqual(PaymentProvider.endpoint(fromFile: "  https://api.nexusjb.com/api/v1/sileo  ")?.absoluteString,
                       "https://api.nexusjb.com/api/v1/sileo/")
        XCTAssertNil(PaymentProvider.endpoint(fromFile: "http://insecure.example/"))
        XCTAssertNil(PaymentProvider.endpoint(fromFile: ""))
        XCTAssertNil(PaymentProvider.endpoint(fromFile: "<html>Not found</html>"))
        XCTAssertNil(PaymentProvider.endpoint(fromFile: "https://example.com/?a=b"))
    }

    func testEndpointFileIsReadOverHTTPS() {
        let urls = [URL(string: "http://repo.example.com/./payment_endpoint")!,
                    URL(string: "https://repo.example.com/./payment_endpoint")!,
                    URL(string: "http://old.example.com:80/payment_endpoint")!,
                    URL(string: "http://odd.example.com:8080/payment_endpoint")!,
                    URL(string: "ftp://repo.example.com/payment_endpoint")!,
                    URL(string: "file:///etc/payment_endpoint")!]
        XCTAssertEqual(PaymentProvider.endpointFileURLs(urls).map(\.absoluteString),
                       ["https://repo.example.com/./payment_endpoint",
                        "https://old.example.com/payment_endpoint",
                        "https://odd.example.com:8080/payment_endpoint"])
        XCTAssertEqual(PaymentProvider.endpointFileURLs([]), [])
    }

    func testRedirectsStayOnHTTPS() {
        XCTAssertTrue(PaymentProvider.allowsRedirect(to: URL(string: "https://api.example.com/v2/info")))
        XCTAssertTrue(PaymentProvider.allowsRedirect(to: URL(string: "https://other.example.com/info")))
        XCTAssertFalse(PaymentProvider.allowsRedirect(to: URL(string: "http://api.example.com/info")))
        XCTAssertFalse(PaymentProvider.allowsRedirect(to: URL(string: "sileo://authentication_success?token=x")))
        XCTAssertFalse(PaymentProvider.allowsRedirect(to: nil))
    }

    func testPriceRequestSendsTheDeviceOnlyWhenSignedIn() {
        let endpoint = URL(string: "https://api.example.com/v1/sileo/")!
        let signedOut = PaymentProvider.priceRequest(endpoint, package: "com.example.tweak", token: nil,
                                                     udid: "00008120-ABC", device: "iPhone15,3")
        XCTAssertEqual(signedOut.method, "GET")
        XCTAssertNil(signedOut.body)
        XCTAssertEqual(signedOut.url.absoluteString, "https://api.example.com/v1/sileo/package/com.example.tweak/info")
        XCTAssertFalse(signedOut.url.absoluteString.contains("00008120"))
        XCTAssertEqual(PaymentProvider.priceRequest(endpoint, package: "com.example.tweak", token: "",
                                                    udid: "00008120-ABC", device: "iPhone15,3").method, "GET")
        let signedIn = PaymentProvider.priceRequest(endpoint, package: "com.example.tweak", token: "abc",
                                                    udid: "00008120-ABC", device: "iPhone15,3")
        XCTAssertEqual(signedIn.method, "POST")
        XCTAssertEqual(signedIn.body, ["token": "abc", "udid": "00008120-ABC", "device": "iPhone15,3"])
        XCTAssertEqual(signedIn.url, signedOut.url)
    }

    func testSignedOutRetryIsAPostWithoutTheUDID() {
        let endpoint = URL(string: "https://api.example.com/v1/sileo/")!
        let retry = PaymentProvider.signedOutPriceRetry(endpoint, package: "com.example.tweak", device: "iPhone15,3")
        XCTAssertEqual(retry.method, "POST")
        XCTAssertEqual(retry.body, ["device": "iPhone15,3"])
        XCTAssertEqual(retry.url.absoluteString, "https://api.example.com/v1/sileo/package/com.example.tweak/info")
    }

    func testPaths() {
        let endpoint = URL(string: "https://api.example.com/v1/sileo/")!
        XCTAssertEqual(PaymentProvider.url(endpoint, "info").absoluteString, "https://api.example.com/v1/sileo/info")
        XCTAssertEqual(PaymentProvider.url(endpoint, PaymentProvider.packagePath("com.example.tweak", "info")).absoluteString,
                       "https://api.example.com/v1/sileo/package/com.example.tweak/info")
        XCTAssertEqual(PaymentProvider.packagePath("a/b c", "purchase"), "package/a%2Fb%20c/purchase")
        let auth = PaymentProvider.authenticationURL(endpoint, udid: "00008120-ABC", model: "iPhone15,3")
        XCTAssertEqual(auth?.absoluteString, "https://api.example.com/v1/sileo/authenticate?udid=00008120-ABC&model=iPhone15,3")
    }

    func testCallback() {
        let url = URL(string: "sileo://authentication_success?token=abc123&payment_secret=s%2Bcret")!
        XCTAssertEqual(PaymentProvider.credentials(fromCallback: url),
                       PaymentProvider.Credentials(token: "abc123", paymentSecret: "s+cret"))
        XCTAssertNil(PaymentProvider.credentials(fromCallback: URL(string: "sileo://authentication_success")!))
        XCTAssertNil(PaymentProvider.credentials(fromCallback: URL(string: "https://evil.example/?token=x")!))
        XCTAssertTrue(PaymentProvider.isPaymentCompleted(URL(string: "sileo://payment_completed")!))
    }

    func testInfo() throws {
        let data = Data(#"{"name":"Nexus","icon":"/icon.png","description":"Tweaks","authentication_banner":{"message":"Sign in to buy","button":"Sign In"}}"#.utf8)
        let info = try PaymentProvider.info(data, base: URL(string: "https://api.example.com/v1/")!)
        XCTAssertEqual(info.name, "Nexus")
        XCTAssertEqual(info.icon?.absoluteString, "https://api.example.com/icon.png")
        XCTAssertEqual(info.bannerMessage, "Sign in to buy")
        XCTAssertEqual(info.bannerButton, "Sign In")
        XCTAssertThrowsError(try PaymentProvider.info(Data("{}".utf8), base: URL(string: "https://a.b/")!))
    }

    func testUserAndFailures() throws {
        let user = try PaymentProvider.user(Data(#"{"items":["com.a","com.b",""],"user":{"name":"Ali Hassan","email":"ali@example.com"}}"#.utf8))
        XCTAssertEqual(user, PaymentProvider.User(name: "Ali Hassan", email: "ali@example.com", purchases: ["com.a", "com.b"]))
        XCTAssertThrowsError(try PaymentProvider.user(Data(#"{"error":"Signed out","invalidate":true}"#.utf8))) { error in
            XCTAssertEqual((error as? PaymentProvider.Failure)?.invalidate, true)
            XCTAssertEqual((error as? PaymentProvider.Failure)?.message, "Signed out")
            XCTAssertEqual((error as? PaymentProvider.Failure)?.fromProvider, true)
        }
        XCTAssertThrowsError(try PaymentProvider.price(Data(#"{"error":"This item is currently not available for purchase."}"#.utf8))) { error in
            XCTAssertEqual((error as? PaymentProvider.Failure)?.fromProvider, true)
        }
        XCTAssertThrowsError(try PaymentProvider.price(Data("<html>".utf8))) { error in
            XCTAssertEqual((error as? PaymentProvider.Failure)?.fromProvider, false)
        }
        XCTAssertThrowsError(try PaymentProvider.user(Data(#"{"success":false}"#.utf8)))
        XCTAssertThrowsError(try PaymentProvider.user(Data("not json".utf8)))
    }

    func testPriceAndPurchase() throws {
        XCTAssertEqual(try PaymentProvider.price(Data(#"{"price":"$2.50","purchased":false,"available":true}"#.utf8)),
                       PaymentProvider.Price(price: "$2.50", purchased: false, available: true))
        XCTAssertEqual(try PaymentProvider.purchase(Data(#"{"status":0}"#.utf8)), .completed)
        XCTAssertEqual(try PaymentProvider.purchase(Data(#"{"status":1,"url":"https://pay.example/checkout/1"}"#.utf8)),
                       .actionRequired(URL(string: "https://pay.example/checkout/1")!))
        XCTAssertEqual(try PaymentProvider.purchase(Data(#"{"status":-1}"#.utf8)), .failed)
        XCTAssertThrowsError(try PaymentProvider.purchase(Data(#"{"status":1,"url":"http://pay.example/"}"#.utf8)))
        XCTAssertEqual(try PaymentProvider.downloadURL(Data(#"{"url":"https://dl.example/once/abc"}"#.utf8)).absoluteString,
                       "https://dl.example/once/abc")
    }

    func testInitials() {
        XCTAssertEqual(PaymentProvider.initials(name: "Ali Hassan", email: nil), "AH")
        XCTAssertEqual(PaymentProvider.initials(name: "ali", email: nil), "A")
        XCTAssertEqual(PaymentProvider.initials(name: nil, email: "zed@example.com"), "Z")
        XCTAssertNil(PaymentProvider.initials(name: nil, email: nil))
    }
}
