import Foundation

@main
struct MailEmbeddedOAuthTests {
    static var assertions = 0
    static func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        assertions += 1
        guard try condition() else { throw NSError(domain: "OAuthTests", code: assertions, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    static func rejects(_ message: String, _ block: () throws -> Void) throws {
        do { try block() } catch { assertions += 1; return }
        try check(false, message)
    }

    @MainActor
    static func main() async {
        do { try await run() }
        catch {
            fputs("OAuth tests failed after \(assertions) checks: \(error)\n", stderr)
            exit(1)
        }
    }

    @MainActor
    static func run() async throws {
        // RFC 7636 Appendix B test vector, not copied from our implementation.
        try check(OAuthUtilities.challenge("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk") == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM", "PKCE challenge differs from RFC")
        let random = try OAuthUtilities.randomString()
        try check(random.count == 43 && !random.contains("="), "Verifier length or encoding")
        try check(random != OAuthUtilities.randomString(), "Verifier repeats")
        let state = "expected-state"
        try check(OAuthUtilities.callbackResult(target: "/?code=hello%2Bworld&state=expected-state", expectedState: state) == "hello+world", "Valid callback encoding")
        for target in ["/?code=a&state=wrong", "/?code=a", "/?code=a&state=expected-state&state=expected-state", "/?code=a&code=b&state=expected-state", "https://evil.example/?code=a&state=expected-state", "//evil.example/?code=a&state=expected-state", "/callback?code=a&state=expected-state", "/?code=a&state=expected-state#fragment"] {
            try rejects("Accepted malformed state/callback: \(target)") { _ = try OAuthUtilities.callbackResult(target: target, expectedState: state) }
        }
        do {
            _ = try OAuthUtilities.callbackResult(target: "/?error=access_denied&state=expected-state", expectedState: state)
            try check(false, "Denial accepted")
        } catch OAuthError.provider(let error) { try check(error == "access_denied", "Incorrect provider denial") }

        let google = OAuthConfiguration(provider: .google, clientID: "own-client.apps.googleusercontent.com", clientSecret: "SECRET-MUST-NOT-PERSIST")
        let encoded = try JSONEncoder().encode(google)
        try check(!String(decoding: encoded, as: UTF8.self).contains("SECRET"), "Client secret leaked into persisted configuration")
        try check(JSONDecoder().decode(OAuthConfiguration.self, from: encoded).clientSecret == nil, "Decoded runtime secret")
        let authURL = try google.authorizationURL(redirectURI: "http://127.0.0.1:42567/", state: "x", verifier: random, nonce: "nonce", loginHint: "account@example.org")
        let params = URLComponents(url: authURL, resolvingAgainstBaseURL: false)!.queryItems!
        try check(params.contains(.init(name: "code_challenge_method", value: "S256")), "Missing PKCE method")
        try check(params.contains(.init(name: "scope", value: "https://mail.google.com/ openid email")), "Missing Gmail scope")
        try check(!authURL.absoluteString.contains("SECRET"), "Client secret leaked into browser URL")
        try rejects("Invalid Microsoft tenant accepted") { try OAuthConfiguration(provider: .microsoft, clientID: "client", tenant: "../evil?q=1").validate() }
        try rejects("Missing ID accepted") { try OAuthConfiguration(provider: .google, clientID: "").validate() }
        let form = String(decoding: OAuthUtilities.formData(["x": "a+b &/ü"]), as: UTF8.self)
        try check(form == "x=a%2Bb%20%26%2F%C3%BC", "Form escaping corrupts secrets/codes")

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var claims: [String: Any] = ["iss": "https://accounts.google.com", "sub": "123", "aud": google.clientID, "nonce": "nonce", "iat": now.timeIntervalSince1970, "exp": now.timeIntervalSince1970 + 3600, "email": "test@example.org", "email_verified": true]
        try check(OAuthUtilities.validateIdentityClaims(claims, configuration: google, nonce: "nonce", now: now) == "test@example.org", "Valid Google identity rejected")
        for (key, value) in [("aud", "other-client" as Any), ("nonce", "replayed-nonce" as Any), ("iss", "https://attacker.example" as Any), ("exp", now.timeIntervalSince1970 - 100 as Any), ("iat", now.timeIntervalSince1970 + 600 as Any), ("email_verified", false as Any)] {
            var bad = claims; bad[key] = value
            try rejects("Invalid claim accepted: \(key)") { _ = try OAuthUtilities.validateIdentityClaims(bad, configuration: google, nonce: "nonce", now: now) }
        }
        let microsoft = OAuthConfiguration(provider: .microsoft, clientID: "own-ms-client")
        let tenant = "9188040d-6c67-4c5b-b112-36a304b66dad"
        claims["iss"] = "https://login.microsoftonline.com/\(tenant)/v2.0"
        claims["tid"] = tenant
        claims["aud"] = microsoft.clientID
        claims["preferred_username"] = "mail@outlook.com"
        try check(OAuthUtilities.validateIdentityClaims(claims, configuration: microsoft, nonce: "nonce", now: now) == "mail@outlook.com", "Valid Microsoft identity rejected")
        var wrongTenant = microsoft; wrongTenant.tenant = UUID().uuidString
        try rejects("Unexpected Microsoft tenant accepted") { _ = try OAuthUtilities.validateIdentityClaims(claims, configuration: wrongTenant, nonce: "nonce", now: now) }

        try testRSAVerification()
        let fakeHeader = OAuthUtilities.base64URL(Data("{\"alg\":\"none\",\"kid\":\"fake\"}".utf8))
        try rejects("Unsecured JWT accepted") { _ = try OAuthUtilities.parseIdentityToken("\(fakeHeader).e30.") }

        // Actual local TCP callback, including a hostile state that must not consume the session.
        let receiver = OAuthLoopbackReceiver(state: state, hostname: "127.0.0.1")
        let redirect = try await receiver.start()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        let session = URLSession(configuration: configuration)
        let (_, badResponse) = try await session.data(from: URL(string: redirect + "?code=injected&state=wrong")!)
        try check((badResponse as? HTTPURLResponse)?.statusCode == 400, "Bad callback not rejected")
        let waiter = Task { @MainActor in try await receiver.waitForCode() }
        let (body, goodResponse) = try await session.data(from: URL(string: redirect + "?code=real-code&state=expected-state")!)
        try check((goodResponse as? HTTPURLResponse)?.statusCode == 200, "Good callback did not complete")
        try check(!String(decoding: body, as: UTF8.self).contains("real-code"), "Authorization code reflected into page")
        let code = try await waiter.value
        try check(code == "real-code", "Wrong callback code delivered")
        let cancelled = OAuthLoopbackReceiver(state: state, hostname: "localhost")
        _ = try await cancelled.start()
        cancelled.cancel()
        do { _ = try await cancelled.waitForCode(); try check(false, "Cancelled receiver yielded code") }
        catch OAuthError.cancelled { assertions += 1 }
        session.invalidateAndCancel()
        print("OAuth tests passed: \(assertions) checks; no real account or email used.")
    }

    static func testRSAVerification() throws {
        // Fixed 2048-bit fixture generated offline with OpenSSL genrsa, rsa
        // -RSAPublicKey_out -outform DER, and dgst -sha256 -sign over header.payload.
        // Only public n/e and the signature remain; no runtime key generation or Keychain.
        let modulus = "vDgOfPUJzMo9GARQBgYqxlZ9nFgEWewb_K6ivuenyZQYa-tdxbID5VHL5QC8bCrm0n-XlrGZ5RkVRfQAmJXZwTnJou1qGpHhfCdnsq1GmC-1Ux6jT3Wqn9B7GNMoTHEYR---RYqlzZL1j9rcjNeHOZjrXEWGigmwpydvA_Rnk7HBoIBcwaKik8TGOh7ckhf_izdycL7FIiqWZbHoZgprvuTVIQssjwFMeMAqyZmr-tpJqOTAQmqaD2pYLBfRkOptNDKw3FduXWcViEY7djZTt_jTMLqAX7Bkkov7OrYL7cA3w2d_xdKo3jHluqQACVAk5tNwSfSQVoVFD91EfmC59w"
        let exponent = "AQAB"
        guard let signature = OAuthUtilities.decodeBase64URL("TEbulwo0Ayqkr8PZ6s9kPJURq8_fIPpryjg2Cyk7YThlleb1Smk7kWTxLtB1L3Y6wGGggVG3huX_zsNjsdo8CJ-M001mKd3Um0NaHtZGgitSvBaHVwKjdST6NH5k1zD_tAipPE9aeg7e_SHxy6x4MO2ELOZJ2sRcBng1zg5CI0bAK-jYuXPxduew8_9ofgLUXjRT5YnJKRqJHQXOx4I1q3xC5zyKoqCAt-2agDPNyHEYtcd6pMCb86w8KrmqozfPCJOUqzNBCQcRAtl9U7vbNUSBUSdhddXZ3P87dl00rbersp7tc_OlDr8S_enFQQmnBKtOP5PkFj_W5uiHg3wkxw"),
              var wrongModulus = OAuthUtilities.decodeBase64URL(modulus) else { throw OAuthError.identityInvalid }
        wrongModulus[0] ^= 0x01
        let message = Data("header.payload".utf8)
        try check(OAuthUtilities.verifyRS256(message: message, signature: signature, modulus: modulus, exponent: exponent), "Valid RSA signature rejected")
        try check(!OAuthUtilities.verifyRS256(message: Data("altered.payload".utf8), signature: signature, modulus: modulus, exponent: exponent), "Tampered RSA signature accepted")
        try check(!OAuthUtilities.verifyRS256(message: message, signature: signature, modulus: OAuthUtilities.base64URL(wrongModulus), exponent: exponent), "Wrong RSA public key accepted")
        try check(!OAuthUtilities.verifyRS256(message: message, signature: signature, modulus: "AAAA", exponent: exponent), "Invalid RSA key accepted")
    }
}
