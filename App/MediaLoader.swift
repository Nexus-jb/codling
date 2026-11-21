// SPDX-License-Identifier: Apache-2.0

import ImageIO
import SwiftUI
import UIKit

/// Downloads what package pages show: depictions, featured banners, icons
/// and screenshots. Responses are cached on disk as the servers allow.
final class MediaLoader {
    /// Set once at launch, before any view asks for media.
    static var shared: MediaLoader!

    let session: URLSession
    private let images = ImageCache()

    /// The largest depiction or banner file read.
    static let documentLimit = 4 << 20
    /// The largest image read.
    static let imageLimit = 24 << 20

    init(environment: RuntimeEnvironment) {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 120
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("com.nexusjb.codling/media", isDirectory: true)
        configuration.urlCache = URLCache(memoryCapacity: 16 << 20, diskCapacity: 256 << 20, directory: caches)
        configuration.httpAdditionalHeaders = [
            "User-Agent": "Codling/\(environment.version) (\(environment.deviceModel); iOS \(environment.systemVersion))",
            "X-Machine": environment.deviceModel,
            "X-Firmware": environment.systemVersion,
            // Codling is in English, so it asks for English content.
            "Accept-Language": "en",
        ]
        session = URLSession(configuration: configuration)
    }

    enum LoadError: Error {
        case message(String)

        var message: String {
            switch self {
            case .message(let text): return text
            }
        }
    }

    /// A file of at most limit bytes; throws with an English message.
    func data(from url: URL, limit: Int = MediaLoader.documentLimit) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(from: url)
        } catch {
            throw LoadError.message(RefreshError.describe(error))
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw LoadError.message("\(url.host ?? "The server") answered \(http.statusCode) (\(HTTPURLResponse.localizedString(forStatusCode: http.statusCode))).")
        }
        guard data.count <= limit else {
            throw LoadError.message("The file is larger than \(limit >> 20) MB.")
        }
        return data
    }

    /// The first of urls that loads as an image, scaled down so that its
    /// longer side is at most maxPixels.
    func image(_ urls: [URL], maxPixels: Int) async -> LoadedImage? {
        for url in urls {
            if let image = await images.image(url: url, maxPixels: maxPixels, load: { [session] in
                guard let (data, response) = try? await session.data(from: url),
                      (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true,
                      data.count <= MediaLoader.imageLimit else {
                    return nil
                }
                return LoadedImage.decode(data, maxPixels: maxPixels)
            }) {
                return image
            }
        }
        return nil
    }
}

/// A decoded image and its size before it was scaled down.
struct LoadedImage {
    let image: UIImage
    let pixelSize: CGSize

    static func decode(_ data: Data, maxPixels: Int) -> LoadedImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0 else {
            return nil
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = (properties?[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue ?? 0
        let height = (properties?[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue ?? 0
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        let size = width > 0 && height > 0 ? CGSize(width: width, height: height)
            : CGSize(width: image.width, height: image.height)
        return LoadedImage(image: UIImage(cgImage: image), pixelSize: size)
    }
}

/// Decoded images in memory, and one download per image at a time.
private actor ImageCache {
    private let memory = NSCache<NSString, Box>()
    private var loading: [String: Task<LoadedImage?, Never>] = [:]

    final class Box {
        let value: LoadedImage
        init(_ value: LoadedImage) { self.value = value }
    }

    init() {
        memory.totalCostLimit = 96 << 20
    }

    func image(url: URL, maxPixels: Int, load: @escaping @Sendable () async -> LoadedImage?) async -> LoadedImage? {
        let key = "\(maxPixels) \(url.absoluteString)"
        if let box = memory.object(forKey: key as NSString) {
            return box.value
        }
        if let task = loading[key] {
            return await task.value
        }
        let task = Task { await load() }
        loading[key] = task
        let image = await task.value
        loading[key] = nil
        if let image, let cgImage = image.image.cgImage {
            memory.setObject(Box(image), forKey: key as NSString, cost: cgImage.bytesPerRow * cgImage.height)
        }
        return image
    }
}

/// An image from the web, with a placeholder while it loads or when it
/// cannot be loaded.
struct RemoteImage<Placeholder: View>: View {
    let urls: [URL]
    var maxPixels = 1024
    var contentMode: ContentMode = .fill
    @ViewBuilder var placeholder: () -> Placeholder

    @State private var loaded: LoadedImage?

    var body: some View {
        ZStack {
            if let loaded {
                Image(uiImage: loaded.image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else {
                placeholder()
            }
        }
        .task(id: urls) {
            loaded = urls.isEmpty ? nil : await MediaLoader.shared.image(urls, maxPixels: maxPixels)
        }
    }
}

/// A package or source icon: the image when it loads, otherwise a symbol.
struct IconView: View {
    let urls: [URL]
    var symbol = "shippingbox.fill"
    var size: CGFloat = 44

    var body: some View {
        RemoteImage(urls: urls, maxPixels: Int(size * 3)) {
            ZStack {
                Color(.tertiarySystemFill)
                Image(systemName: symbol)
                    .font(.system(size: size * 0.45)) // fixed: a symbol sized to its tile
                    .foregroundColor(.secondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.225, style: .continuous))
        .accessibilityHidden(true)
    }
}
