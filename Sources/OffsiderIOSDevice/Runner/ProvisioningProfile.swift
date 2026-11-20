import Foundation
import OffsiderCore
import Security

/// The expiry of a bundle's `embedded.mobileprovision`, read with Security's CMS decoder; the signature is not checked, as only the date is used.
enum ProvisioningProfile {
    static let fileName = "embedded.mobileprovision"
    static let maxBytes = 1 << 20
    /// Renewed this close to its end; a rebuild that keeps the same still-valid profile is kept, so the margin stays short.
    static let renewalMargin: TimeInterval = 60 * 60

    private struct Dates: Decodable {
        let ExpirationDate: Date
    }

    /// Nil when the bundle has no profile, or one this cannot read.
    static func expiry(inBundle path: String) -> Date? {
        let file = (path as NSString).appendingPathComponent(fileName)
        guard let data = UntrustedRead.contents(atPath: file, maxBytes: maxBytes) else { return nil }
        return expiry(of: data)
    }

    static func expiry(of data: Data) -> Date? {
        guard let content = content(of: data) else { return nil }
        return (try? PropertyListDecoder().decode(Dates.self, from: content))?.ExpirationDate
    }

    private static func content(of data: Data) -> Data? {
        guard !data.isEmpty, data.count <= maxBytes else { return nil }
        var made: CMSDecoder?
        guard CMSDecoderCreate(&made) == errSecSuccess, let decoder = made else { return nil }
        let updated = data.withUnsafeBytes { bytes in
            bytes.baseAddress.map { CMSDecoderUpdateMessage(decoder, $0, bytes.count) } ?? errSecParam
        }
        guard updated == errSecSuccess, CMSDecoderFinalizeMessage(decoder) == errSecSuccess else { return nil }
        var content: CFData?
        guard CMSDecoderCopyContent(decoder, &content) == errSecSuccess, let content else { return nil }
        return content as Data
    }
}
