import CryptoKit
import Foundation

// Standalone macOS/iOS SDK check executable; compile with NativeTeslaClient.swift + PonyCore.
// Generates short-lived local values only. Does not use Keychain, UI or networking.
@main
struct NativeTeslaClientChecks {
    private enum Failure: Error { case checkFailed }

    static func main() throws {
        func check(_ condition: Bool) throws {
            guard condition else { throw Failure.checkFailed }
        }
        let verifier = try NativeTeslaPKCE.random()
        let state = try NativeTeslaPKCE.random()
        let grant = try NativeTeslaPKCE.random()
        try check(NativeTeslaPKCE.isOpaque(verifier))
        try check(NativeTeslaPKCE.isOpaque(state))
        try check(verifier != state && state != grant && verifier != grant)
        let challenge = NativeTeslaPKCE.challenge(for: verifier)
        try check(NativeTeslaPKCE.isOpaque(challenge) && challenge != verifier)
        let digest = Data(SHA256.hash(data: Data(verifier.utf8)))
        try check(NativeTeslaPKCE.base64URL(digest) == challenge)
        try check(!NativeTeslaPKCE.isOpaque(""))
        try check(!NativeTeslaPKCE.isOpaque(String(repeating: "+", count: 43)))

        let valid = NativeTeslaCallback.absolute + "?grant=\(grant)&state=\(state)"
        guard let validURL = URL(string: valid) else { throw Failure.checkFailed }
        try check(try NativeTeslaCallback.grant(from: validURL, expectedState: state) == grant)
        let invalid = [
            "other://auth?grant=\(grant)&state=\(state)",
            "pony-native://elsewhere?grant=\(grant)&state=\(state)",
            "pony-native://auth/?grant=\(grant)&state=\(state)",
            "pony-native://auth/extra?grant=\(grant)&state=\(state)",
            "pony-native://auth:443?grant=\(grant)&state=\(state)",
            "pony-native://user@auth?grant=\(grant)&state=\(state)",
            valid + "#extra", valid + "&extra=1", valid + "&state=\(state)",
            valid + "&grant=\(grant)",
            "pony-native://auth?grant=\(grant)",
            "pony-native://auth?grant=&state=\(state)",
            "pony-native://auth?grant=\(grant)&state=\(verifier)"
        ]
        for candidate in invalid {
            guard let url = URL(string: candidate) else { continue }
            do {
                _ = try NativeTeslaCallback.grant(from: url, expectedState: state)
                throw Failure.checkFailed
            } catch NativeTeslaError.invalidCallback { /* expected */ }
        }
        print("PASS native PKCE and strict callback checks")
    }
}
