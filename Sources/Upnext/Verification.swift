import CryptoKit
import Foundation
import Security

enum VerificationError: LocalizedError {
    case sizeMismatch(expected: Int64, actual: Int64)
    case checksumMismatch
    case badSparkleSignature
    case invalidCodeSignature(String)
    case teamMismatch(expected: String, actual: String?)

    var errorDescription: String? {
        switch self {
        case let .sizeMismatch(expected, actual):
            return "Download size was \(actual) bytes, expected \(expected)."
        case .checksumMismatch:
            return "The download's checksum doesn't match the published one."
        case .badSparkleSignature:
            return "The download's signature doesn't match the developer's key."
        case let .invalidCodeSignature(detail):
            return "The downloaded app's code signature is invalid (\(detail))."
        case let .teamMismatch(expected, actual):
            return "The downloaded app is signed by a different developer "
                + "(\(actual ?? "unsigned") instead of \(expected))."
        }
    }
}

enum Verification {
    static func checkSize(of file: URL, expected: Int64?) throws {
        guard let expected, expected > 0 else { return }
        let size = Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1)
        // Feeds are sometimes stale on length alone; only fail when wildly off.
        if size >= 0, size != expected, abs(size - expected) > max(expected / 100, 1024) {
            throw VerificationError.sizeMismatch(expected: expected, actual: size)
        }
    }

    static func checkSHA256(of file: URL, expected: String?) throws {
        guard let expected else { return }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 * 1024 * 1024), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard digest == expected.lowercased() else { throw VerificationError.checksumMismatch }
    }

    /// Verifies a Sparkle EdDSA signature the same way Sparkle does, using the
    /// public key embedded in the installed app.
    static func checkSparkleSignature(of file: URL, signature: String?, publicKey: String?) throws {
        guard let publicKey, let keyData = Data(base64Encoded: publicKey) else { return }
        // The app pins a key, so an unsigned or badly signed download is rejected.
        guard let signature, let sigData = Data(base64Encoded: signature),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData) else {
            throw VerificationError.badSparkleSignature
        }
        let data = try Data(contentsOf: file, options: .alwaysMapped)
        guard key.isValidSignature(sigData, for: data) else {
            throw VerificationError.badSparkleSignature
        }
    }

    // MARK: Code signing

    static func teamIdentifier(of bundle: URL) -> String? {
        guard let code = staticCode(bundle) else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info)
                == errSecSuccess,
              let dict = info as? [String: Any] else { return nil }
        return dict[kSecCodeInfoTeamIdentifier as String] as? String
    }

    /// Checks the new bundle is intact and comes from the same developer as the
    /// one it replaces.
    static func checkCodeSignature(newBundle: URL, replacing oldBundle: URL) throws {
        let oldTeam = teamIdentifier(of: oldBundle)

        guard let code = staticCode(newBundle) else {
            throw VerificationError.invalidCodeSignature("unreadable")
        }
        var error: Unmanaged<CFError>?
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode)
        let status = SecStaticCodeCheckValidityWithErrors(code, flags, nil, &error)
        if status == errSecCSUnsigned {
            // Unsigned apps can only replace unsigned apps.
            if let oldTeam { throw VerificationError.teamMismatch(expected: oldTeam, actual: nil) }
            return
        }
        guard status == errSecSuccess else {
            let detail = (error?.takeRetainedValue()).map { CFErrorCopyDescription($0) as String }
                ?? "OSStatus \(status)"
            throw VerificationError.invalidCodeSignature(detail)
        }

        if let oldTeam {
            let newTeam = teamIdentifier(of: newBundle)
            guard newTeam == oldTeam else {
                throw VerificationError.teamMismatch(expected: oldTeam, actual: newTeam)
            }
        }
    }

    private static func staticCode(_ url: URL) -> SecStaticCode? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess else { return nil }
        return code
    }
}
