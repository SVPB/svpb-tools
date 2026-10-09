import Crypto
import Foundation

// MARK: - S3Signer

/// Signs a request for an S3-compatible object store with AWS Signature Version 4.
///
/// TNG talks to exactly one such store — the DigitalOcean Space its nightly database
/// backup goes to (#4) — and puts one object a day into it. That is a hundred lines of
/// HMAC, not a reason to take on an AWS SDK and everything it brings with it.
///
/// Only what a single-request upload needs is here: no query-string signing, no chunked
/// payloads, no presigned URLs. Header names are lowercased and sorted as the
/// specification requires, so a caller may pass them in any case.
struct S3Signer: Sendable {

    let accessKey: String
    let secretKey: String

    /// The signing region. DigitalOcean accepts its own region slug (`sfo3`) here, and
    /// also `us-east-1`; AWS needs the bucket's real region.
    let region: String

    static let service = "s3"
    static let algorithm = "AWS4-HMAC-SHA256"

    /// The headers to add to a request so that the store will accept it: `x-amz-date`,
    /// `x-amz-content-sha256` and `Authorization`.
    ///
    /// - Parameters:
    ///   - method: `PUT`, `GET`, …
    ///   - path: The request path, unencoded — `/bucket/tng/2026-10-08.sqlite`.
    ///   - host: The `Host` header, which is always signed.
    ///   - headers: Any further headers to sign, such as `Content-Type`.
    ///   - payloadHash: Lowercase hex SHA-256 of the body.
    ///   - date: The signing time; the store rejects one more than fifteen minutes out.
    func signedHeaders(
        method: String,
        path: String,
        host: String,
        headers: [String: String] = [:],
        payloadHash: String,
        date: Date
    ) -> [(String, String)] {
        let amzDate = Self.timestamp(date)
        let day = String(amzDate.prefix(8))

        var signed = [String: String]()
        for (name, value) in headers {
            signed[name.lowercased()] = value.trimmingCharacters(in: .whitespaces)
        }
        signed["host"] = host
        signed["x-amz-date"] = amzDate
        signed["x-amz-content-sha256"] = payloadHash

        let names = signed.keys.sorted()
        let canonicalHeaders = names.map { "\($0):\(signed[$0]!)\n" }.joined()
        let signedHeaderList = names.joined(separator: ";")

        let canonicalRequest = [
            method,
            Self.encodePath(path),
            "",  // no query string
            canonicalHeaders,
            signedHeaderList,
            payloadHash,
        ].joined(separator: "\n")

        let scope = "\(day)/\(region)/\(Self.service)/aws4_request"
        let stringToSign = [
            Self.algorithm,
            amzDate,
            scope,
            Self.hex(SHA256.hash(data: Data(canonicalRequest.utf8))),
        ].joined(separator: "\n")

        let signature = Self.hex(HMAC<SHA256>.authenticationCode(
            for: Data(stringToSign.utf8), using: signingKey(day: day)))

        let authorization = "\(Self.algorithm) Credential=\(accessKey)/\(scope), "
            + "SignedHeaders=\(signedHeaderList), Signature=\(signature)"

        return [
            ("x-amz-date", amzDate),
            ("x-amz-content-sha256", payloadHash),
            ("Authorization", authorization),
        ]
    }

    /// The day's signing key: the secret, folded through the date, region, service and
    /// the literal `aws4_request`.
    private func signingKey(day: String) -> SymmetricKey {
        var key = SymmetricKey(data: Data("AWS4\(secretKey)".utf8))
        for part in [day, region, Self.service, "aws4_request"] {
            key = SymmetricKey(data: Data(HMAC<SHA256>.authenticationCode(
                for: Data(part.utf8), using: key)))
        }
        return key
    }

    // MARK: - Helpers

    /// Lowercase hex SHA-256 of a body, for `payloadHash`.
    static func payloadHash(_ body: Data) -> String {
        hex(SHA256.hash(data: body))
    }

    /// `20261008T031500Z`.
    static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter.string(from: date)
    }

    /// Percent-encodes every path segment, leaving the slashes between them. S3 encodes
    /// once — unlike every other AWS service, which encodes the path twice.
    static func encodePath(_ path: String) -> String {
        var unreserved = CharacterSet.alphanumerics
        unreserved.insert(charactersIn: "-._~/")
        // `alphanumerics` is Unicode-wide; the specification means ASCII only.
        return path.unicodeScalars.map { scalar in
            scalar.isASCII && unreserved.contains(scalar)
                ? String(scalar)
                : String(scalar).utf8.map { String(format: "%%%02X", $0) }.joined()
        }.joined()
    }

    private static func hex<D: Sequence>(_ bytes: D) -> String where D.Element == UInt8 {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}
