import Foundation
import AppKit
import Network
import Security
import CryptoKit

enum OAuthProvider: String, Codable, CaseIterable {
    case google, microsoft
}

struct OAuthConfiguration: Codable, Equatable {
    var provider: OAuthProvider
    var clientID: String
    /// Runtime only. The custom Codable keys intentionally exclude this secret.
    var clientSecret: String? = nil
    var tenant: String = "common"

    enum CodingKeys: String, CodingKey { case provider, clientID, tenant }

    var scopes: String {
        switch provider {
        case .google: return "https://mail.google.com/ openid email"
        case .microsoft: return "https://outlook.office.com/IMAP.AccessAsUser.All https://outlook.office.com/SMTP.Send offline_access openid profile email"
        }
    }

    var tokenURL: URL {
        switch provider {
        case .google: return URL(string: "https://oauth2.googleapis.com/token")!
        case .microsoft: return URL(string: "https://login.microsoftonline.com/\(tenant)/oauth2/v2.0/token")!
        }
    }

    func validate() throws {
        guard !clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              clientID.count < 1024,
              !clientID.contains(where: { $0.isWhitespace || $0.isNewline }) else { throw OAuthError.missingClientID }
        if provider == .microsoft {
            let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-")
            guard !tenant.isEmpty, tenant.count < 256, tenant.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
                throw OAuthError.invalidConfiguration
            }
        }
    }

    func authorizationURL(redirectURI: String, state: String, verifier: String, nonce: String, loginHint: String?) throws -> URL {
        try validate()
        let base = provider == .google ? "https://accounts.google.com/o/oauth2/v2/auth" : "https://login.microsoftonline.com/\(tenant)/oauth2/v2.0/authorize"
        var components = URLComponents(string: base)!
        var items: [URLQueryItem] = [
            .init(name: "client_id", value: clientID), .init(name: "response_type", value: "code"),
            .init(name: "redirect_uri", value: redirectURI), .init(name: "scope", value: scopes),
            .init(name: "state", value: state), .init(name: "nonce", value: nonce),
            .init(name: "code_challenge", value: OAuthUtilities.challenge(verifier)),
            .init(name: "code_challenge_method", value: "S256")
        ]
        if provider == .google {
            items += [.init(name: "access_type", value: "offline"), .init(name: "prompt", value: "consent select_account")]
        } else {
            items += [.init(name: "response_mode", value: "query"), .init(name: "prompt", value: "select_account")]
        }
        if let hint = loginHint, !hint.isEmpty { items.append(.init(name: "login_hint", value: hint)) }
        components.queryItems = items
        guard let url = components.url else { throw OAuthError.invalidConfiguration }
        return url
    }
}

struct OAuthCredential: Codable {
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Date
    var tokenType: String
    var authorizedEmail: String? = nil
}

private struct StoredOAuthCredential: Codable {
    var configuration: OAuthConfiguration
    var credential: OAuthCredential
    var transactionID: UUID? = nil
}

enum OAuthError: LocalizedError {
    case missingClientID, invalidConfiguration, alreadyAuthorizing, browserUnavailable
    case timeout, cancelled, callbackInvalid, identityInvalid, accountMismatch
    case noCredential, credentialChanged, refreshUnavailable, tokenResponse, network, invalidGrant
    case credentialExists
    case provider(String)

    var errorDescription: String? {
        switch self {
        case .missingClientID: return "请先在设置中填写自己注册的 OAuth 客户端 ID。搞门户邮件模块没有内置第三方应用的客户端 ID。"
        case .invalidConfiguration: return "OAuth 配置不正确，请核对客户端 ID 和 Microsoft 租户。"
        case .alreadyAuthorizing: return "另一个邮箱正在授权，请先完成或取消。"
        case .browserUnavailable: return "无法打开默认浏览器，请检查系统浏览器设置。"
        case .timeout: return "授权等待超时，请重新授权并在浏览器中完成登录。"
        case .cancelled: return "已取消授权。"
        case .callbackInvalid: return "授权回调校验失败，请重新授权。"
        case .identityInvalid: return "无法验证服务商返回的登录身份，未保存此次授权。"
        case .accountMismatch: return "授权时选择的账号与当前邮箱地址不同。请使用该邮箱的主登录地址，并在浏览器中选择对应账号。"
        case .credentialExists: return "此邮箱的凭据标识已经存在，未覆盖已有授权。请重新添加。"
        case .noCredential: return "此邮箱尚未完成授权，请先点击浏览器授权。"
        case .credentialChanged: return "OAuth 客户端配置已更改，请为此邮箱重新授权。"
        case .refreshUnavailable: return "服务商未返回长期授权，请重新授权。"
        case .tokenResponse: return "服务商返回的授权结果不完整，请重新授权。"
        case .network: return "无法连接授权服务，请检查网络后重试。"
        case .invalidGrant: return "授权已过期或被撤销，请重新授权。"
        case .provider(let code):
            switch code {
            case "access_denied": return "你或组织管理员拒绝了此次邮箱授权。"
            case "invalid_client", "unauthorized_client": return "OAuth 客户端配置未被服务商接受，请检查客户端 ID、应用类型及 Google 客户端密钥。"
            case "invalid_scope": return "应用尚未配置所需邮件权限，请参阅 OAuth 配置说明。"
            case "interaction_required", "login_required", "consent_required": return "服务商要求重新登录或同意权限，请重新授权。"
            default: return "服务商未批准此次授权，请核对应用配置和组织访问策略。"
            }
        }
    }
}

/// Values become available only after RS256/JWKS and OIDC claim validation.
struct OAuthAuthorization {
    var credential: OAuthCredential
    var email: String
    var microsoftTenantID: String?
}

/// Injectable storage allows isolated tests without ever opening the real Keychain.
struct OAuthCredentialStorage {
    var read: (String) throws -> Data?
    var save: (Data, String) throws -> Void
    var insert: (Data, String) throws -> Void
    var delete: (String) throws -> Void

    static var system: Self {
        Self(read: MailCredentialVault.readData, save: { try MailCredentialVault.saveData($0, for: $1) },
             insert: { try MailCredentialVault.insertData($0, for: $1) }, delete: MailCredentialVault.delete)
    }
}

@MainActor
final class OAuthManager {
    private var receiver: OAuthLoopbackReceiver?
    private var authorizationGeneration: UUID?
    private var authorizingAccountID: String?
    private var refreshes: [String: Task<OAuthCredential, Error>] = [:]
    private let session: URLSession
    private let openBrowser: (URL) -> Bool
    private let credentials: OAuthCredentialStorage

    init(session: URLSession? = nil, credentials: OAuthCredentialStorage = .system,
         openBrowser: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) }) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 45
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        self.session = session ?? URLSession(configuration: configuration)
        self.credentials = credentials
        self.openBrowser = openBrowser
    }

    /// Retained for callers authorizing an already saved account.
    func authorize(accountID: String, configuration: OAuthConfiguration, loginHint: String? = nil) async throws -> OAuthCredential {
        try await authorizeUsingBrowser(accountID: accountID, configuration: configuration, loginHint: loginHint) { result, checkActive in
            try checkActive()
            try self.save(result.credential, accountID: accountID, configuration: configuration)
            return result.credential
        }
    }

    /// The caller performs any asynchronous mail checks, then checks the session once more
    /// immediately before its synchronous persistence transaction. Nothing is saved here.
    func authorizeUsingBrowser<T>(accountID: String? = nil, configuration: OAuthConfiguration, loginHint: String? = nil,
                                  finish: (OAuthAuthorization, @escaping () throws -> Void) async throws -> T) async throws -> T {
        try Task.checkCancellation()
        try configuration.validate()
        guard authorizationGeneration == nil else { throw OAuthError.alreadyAuthorizing }
        let verifier = try OAuthUtilities.randomString()
        let state = try OAuthUtilities.randomString()
        let nonce = try OAuthUtilities.randomString()
        let generation = UUID()
        authorizationGeneration = generation
        authorizingAccountID = accountID
        let callback = OAuthLoopbackReceiver(state: state, hostname: configuration.provider == .microsoft ? "localhost" : "127.0.0.1")
        receiver = callback
        defer {
            callback.cancel()
            if authorizationGeneration == generation { authorizationGeneration = nil; authorizingAccountID = nil; receiver = nil }
        }
        return try await withTaskCancellationHandler {
            let redirectURI = try await callback.start()
            try checkActive(generation)
            let authorizationURL = try configuration.authorizationURL(redirectURI: redirectURI, state: state, verifier: verifier, nonce: nonce, loginHint: loginHint)
            guard openBrowser(authorizationURL) else { throw OAuthError.browserUnavailable }
            let code = try await callback.waitForCode()
            try checkActive(generation)
            var values = ["grant_type": "authorization_code", "client_id": configuration.clientID,
                          "code": code, "redirect_uri": redirectURI, "code_verifier": verifier]
            if let secret = configuration.clientSecret, !secret.isEmpty { values["client_secret"] = secret }
            let response = try await requestToken(configuration: configuration, values: values)
            try checkActive(generation)
            guard let identityToken = response.idToken else { throw OAuthError.identityInvalid }
            let identity = try await verifiedIdentity(identityToken: identityToken, configuration: configuration, nonce: nonce)
            if let expected = loginHint?.trimmingCharacters(in: .whitespacesAndNewlines), !expected.isEmpty,
               identity.email.caseInsensitiveCompare(expected) != .orderedSame { throw OAuthError.accountMismatch }
            try checkActive(generation)
            let credential = try response.credential(existing: nil, email: identity.email)
            return try await finish(OAuthAuthorization(credential: credential, email: identity.email, microsoftTenantID: identity.tenantID),
                                    { try self.checkActive(generation) })
        } onCancel: {
            Task { @MainActor in
                if self.authorizationGeneration == generation { self.cancel() }
            }
        }
    }

    /// Atomic insert preserves credentials belonging to any existing identifier.
    func insertCredential(_ credential: OAuthCredential, accountID: String, configuration: OAuthConfiguration, transactionID: UUID) throws {
        let key = "oauth.\(accountID)"
        guard try credentials.read(key) == nil else { throw OAuthError.credentialExists }
        let data = try JSONEncoder().encode(StoredOAuthCredential(configuration: configuration, credential: credential, transactionID: transactionID))
        try credentials.insert(data, key)
    }

    /// Recovery only deletes the exact insertion owned by this transaction. A reused
    /// account identifier or a subsequently replaced credential is always preserved.
    func rollbackNewCredential(accountID: String, transactionID: UUID) throws {
        let key = "oauth.\(accountID)"
        guard let data = try credentials.read(key) else { return }
        let record = try JSONDecoder().decode(StoredOAuthCredential.self, from: data)
        guard record.transactionID == transactionID else { return }
        try credentials.delete(key)
    }

    func validAccessToken(accountID: String, configuration: OAuthConfiguration) async throws -> String {
        try configuration.validate()
        let existing = try stored(accountID)
        guard existing.configuration.provider == configuration.provider,
              existing.configuration.clientID == configuration.clientID,
              existing.configuration.tenant == configuration.tenant else { throw OAuthError.credentialChanged }
        if existing.credential.expiresAt.timeIntervalSinceNow > 90 { return existing.credential.accessToken }
        if let active = refreshes[accountID] { return try await active.value.accessToken }
        let task = Task { @MainActor in
            guard let refresh = existing.credential.refreshToken, !refresh.isEmpty else { throw OAuthError.refreshUnavailable }
            var values = ["grant_type": "refresh_token", "client_id": configuration.clientID, "refresh_token": refresh]
            if let secret = configuration.clientSecret, !secret.isEmpty { values["client_secret"] = secret }
            if configuration.provider == .microsoft { values["scope"] = configuration.scopes }
            let response = try await self.requestToken(configuration: configuration, values: values)
            try Task.checkCancellation()
            let credential = try response.credential(existing: existing.credential, email: existing.credential.authorizedEmail)
            try self.save(credential, accountID: accountID, configuration: configuration)
            return credential
        }
        refreshes[accountID] = task
        defer { refreshes[accountID] = nil }
        return try await task.value.accessToken
    }

    func cancel() {
        authorizationGeneration = nil
        authorizingAccountID = nil
        receiver?.cancel()
        receiver = nil
    }

    func disconnect(accountID: String) throws {
        if authorizingAccountID == accountID { cancel() }
        refreshes[accountID]?.cancel()
        refreshes[accountID] = nil
        try credentials.delete("oauth.\(accountID)")
    }

    func hasCredential(accountID: String) -> Bool {
        (try? credentials.read("oauth.\(accountID)")) != nil
    }

    private func checkActive(_ generation: UUID) throws {
        try Task.checkCancellation()
        guard authorizationGeneration == generation else { throw OAuthError.cancelled }
    }

    private func stored(_ accountID: String) throws -> StoredOAuthCredential {
        guard let data = try credentials.read("oauth.\(accountID)") else { throw OAuthError.noCredential }
        do { return try JSONDecoder().decode(StoredOAuthCredential.self, from: data) }
        catch { throw OAuthError.noCredential }
    }

    func save(_ credential: OAuthCredential, accountID: String, configuration: OAuthConfiguration) throws {
        let data = try JSONEncoder().encode(StoredOAuthCredential(configuration: configuration, credential: credential))
        try credentials.save(data, "oauth.\(accountID)")
    }

    private func requestToken(configuration: OAuthConfiguration, values: [String: String]) async throws -> OAuthTokenResponse {
        var request = URLRequest(url: configuration.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = OAuthUtilities.formData(values)
        do {
            let (data, response) = try await session.data(for: request)
            guard data.count < 1_048_576, let http = response as? HTTPURLResponse else { throw OAuthError.tokenResponse }
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            if let code = object?["error"] as? String {
                if code == "invalid_grant" { throw OAuthError.invalidGrant }
                throw OAuthError.provider(code)
            }
            guard (200..<300).contains(http.statusCode) else { throw OAuthError.tokenResponse }
            return try JSONDecoder().decode(OAuthTokenResponse.self, from: data)
        } catch let error as OAuthError { throw error }
        catch is CancellationError { throw OAuthError.cancelled }
        catch let error as URLError where error.code == .cancelled { throw OAuthError.cancelled }
        catch { throw OAuthError.network }
    }

    private func verifiedIdentity(identityToken: String, configuration: OAuthConfiguration, nonce: String) async throws -> (email: String, tenantID: String?) {
        let token = try OAuthUtilities.parseIdentityToken(identityToken)
        let jwksURL = configuration.provider == .google
            ? URL(string: "https://www.googleapis.com/oauth2/v3/certs")!
            : URL(string: "https://login.microsoftonline.com/\(configuration.tenant)/discovery/v2.0/keys")!
        let data: Data
        do {
            let (body, response) = try await session.data(from: jwksURL)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200, body.count < 1_048_576 else { throw OAuthError.identityInvalid }
            data = body
        } catch { throw OAuthError.identityInvalid }
        let keys = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard let candidates = keys?["keys"] as? [[String: Any]],
              let key = candidates.first(where: { $0["kid"] as? String == token.keyID && $0["kty"] as? String == "RSA" }),
              let modulus = key["n"] as? String, let exponent = key["e"] as? String,
              OAuthUtilities.verifyRS256(message: token.message, signature: token.signature, modulus: modulus, exponent: exponent) else { throw OAuthError.identityInvalid }
        let email = try OAuthUtilities.validateIdentityClaims(token.claims, configuration: configuration, nonce: nonce)
        return (email, configuration.provider == .microsoft ? token.claims["tid"] as? String : nil)
    }
}

private struct OAuthTokenResponse: Decodable {
    var accessToken: String
    var refreshToken: String?
    var expiresIn: Double
    var tokenType: String
    var idToken: String?
    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token", refreshToken = "refresh_token", expiresIn = "expires_in", tokenType = "token_type", idToken = "id_token"
    }

    func credential(existing: OAuthCredential?, email: String?) throws -> OAuthCredential {
        guard !accessToken.isEmpty, accessToken.count < 131_072, expiresIn > 0, expiresIn.isFinite,
              tokenType.caseInsensitiveCompare("Bearer") == .orderedSame else { throw OAuthError.tokenResponse }
        return OAuthCredential(accessToken: accessToken, refreshToken: refreshToken ?? existing?.refreshToken,
                               expiresAt: Date().addingTimeInterval(expiresIn), tokenType: "Bearer", authorizedEmail: email)
    }
}

enum OAuthUtilities {
    static func randomString() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw OAuthError.invalidConfiguration }
        return base64URL(Data(bytes))
    }
    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    static func decodeBase64URL(_ value: String) -> Data? {
        let text = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        return Data(base64Encoded: text + String(repeating: "=", count: (4 - text.count % 4) % 4))
    }
    static func challenge(_ verifier: String) -> String { base64URL(Data(SHA256.hash(data: Data(verifier.utf8)))) }
    static func formData(_ values: [String: String]) -> Data {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let encoded = values.sorted { $0.key < $1.key }.map { key, value in
            "\(key.addingPercentEncoding(withAllowedCharacters: allowed)!)=\(value.addingPercentEncoding(withAllowedCharacters: allowed)!)"
        }.joined(separator: "&")
        return Data(encoded.utf8)
    }

    static func callbackResult(target: String, expectedState: String) throws -> String {
        guard target.hasPrefix("/?"), !target.contains("#"), target.count < 16_384,
              let components = URLComponents(string: "http://127.0.0.1\(target)"), components.path == "/" else { throw OAuthError.callbackInvalid }
        let items = components.queryItems ?? []
        let states = items.filter { $0.name == "state" }
        guard states.count == 1, states[0].value == expectedState else { throw OAuthError.callbackInvalid }
        let errors = items.filter { $0.name == "error" }
        if errors.count == 1, let code = errors[0].value { throw OAuthError.provider(code) }
        let codes = items.filter { $0.name == "code" }
        guard errors.isEmpty, codes.count == 1, let code = codes[0].value, !code.isEmpty else { throw OAuthError.callbackInvalid }
        return code
    }

    struct IdentityToken {
        var keyID: String
        var claims: [String: Any]
        var message: Data
        var signature: Data
    }
    static func parseIdentityToken(_ raw: String) throws -> IdentityToken {
        guard raw.count < 131_072 else { throw OAuthError.identityInvalid }
        let parts = raw.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, let headerData = decodeBase64URL(parts[0]), let claimsData = decodeBase64URL(parts[1]),
              let signature = decodeBase64URL(parts[2]),
              let header = (try? JSONSerialization.jsonObject(with: headerData)) as? [String: Any],
              let claims = (try? JSONSerialization.jsonObject(with: claimsData)) as? [String: Any],
              header["alg"] as? String == "RS256", let keyID = header["kid"] as? String, !keyID.isEmpty else { throw OAuthError.identityInvalid }
        return IdentityToken(keyID: keyID, claims: claims, message: Data("\(parts[0]).\(parts[1])".utf8), signature: signature)
    }

    static func validateIdentityClaims(_ claims: [String: Any], configuration: OAuthConfiguration, nonce: String, now: Date = Date()) throws -> String {
        let audiences = (claims["aud"] as? [String]) ?? (claims["aud"] as? String).map { [$0] } ?? []
        guard audiences.contains(configuration.clientID), claims["nonce"] as? String == nonce,
              let expiry = claims["exp"] as? Double, expiry > now.timeIntervalSince1970 - 30,
              let issued = claims["iat"] as? Double, issued <= now.timeIntervalSince1970 + 300,
              let subject = claims["sub"] as? String, !subject.isEmpty,
              let issuer = claims["iss"] as? String else { throw OAuthError.identityInvalid }
        if audiences.count > 1, claims["azp"] as? String != configuration.clientID { throw OAuthError.identityInvalid }
        if let authorizedParty = claims["azp"] as? String, authorizedParty != configuration.clientID { throw OAuthError.identityInvalid }
        if let notBefore = claims["nbf"] as? Double, notBefore > now.timeIntervalSince1970 + 30 { throw OAuthError.identityInvalid }
        let email: String?
        switch configuration.provider {
        case .google:
            guard issuer == "https://accounts.google.com" || issuer == "accounts.google.com",
                  claims["email_verified"] as? Bool == true else { throw OAuthError.identityInvalid }
            email = claims["email"] as? String
        case .microsoft:
            guard let tenant = claims["tid"] as? String, UUID(uuidString: tenant) != nil,
                  issuer == "https://login.microsoftonline.com/\(tenant)/v2.0" else { throw OAuthError.identityInvalid }
            if let configuredTenant = UUID(uuidString: configuration.tenant), UUID(uuidString: tenant) != configuredTenant { throw OAuthError.identityInvalid }
            if configuration.tenant.lowercased() == "consumers", tenant.lowercased() != "9188040d-6c67-4c5b-b112-36a304b66dad" { throw OAuthError.identityInvalid }
            if configuration.tenant.lowercased() == "organizations", tenant.lowercased() == "9188040d-6c67-4c5b-b112-36a304b66dad" { throw OAuthError.identityInvalid }
            // preferred_username may be a phone number; select only mailbox-shaped claims.
            email = [claims["preferred_username"] as? String, claims["email"] as? String].compactMap { $0 }.first { validIdentityEmail($0) }
        }
        guard let value = email, validIdentityEmail(value) else { throw OAuthError.identityInvalid }
        return value
    }

    static func validIdentityEmail(_ value: String) -> Bool {
        guard value.utf8.count <= 320, !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              value.range(of: "^[^\\s@<>(),;:\\\"\\\\\\[\\]]+@[^\\s@<>(),;:\\\"\\\\\\[\\]]+\\.[^\\s@<>(),;:\\\"\\\\\\[\\]]+$", options: .regularExpression) != nil else { return false }
        let parts = value.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].hasPrefix("."), !parts[0].hasSuffix("."), !parts[0].contains("..") else { return false }
        return parts[1].split(separator: ".", omittingEmptySubsequences: false).allSatisfy { label in
            !label.isEmpty && !label.hasPrefix("-") && !label.hasSuffix("-") && label.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "-" }
        }
    }

    static func verifyRS256(message: Data, signature: Data, modulus: String, exponent: String) -> Bool {
        guard let n = decodeBase64URL(modulus), let e = decodeBase64URL(exponent), n.count >= 256, n.count <= 1024,
              e.count > 0, e.count <= 8 else { return false }
        func length(_ count: Int) -> Data {
            if count < 128 { return Data([UInt8(count)]) }
            var remaining = count; var bytes: [UInt8] = []
            while remaining > 0 { bytes.insert(UInt8(remaining & 0xff), at: 0); remaining >>= 8 }
            return Data([0x80 | UInt8(bytes.count)] + bytes)
        }
        func integer(_ value: Data) -> Data {
            var value = value
            while value.count > 1 && value.first == 0 { value.removeFirst() }
            if let first = value.first, first & 0x80 != 0 { value.insert(0, at: 0) }
            return Data([0x02]) + length(value.count) + value
        }
        let body = integer(n) + integer(e)
        let der = Data([0x30]) + length(body.count) + body
        let attributes = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPublic] as [CFString: Any]
        guard let key = SecKeyCreateWithData(der as CFData, attributes as CFDictionary, nil) else { return false }
        return SecKeyVerifySignature(key, .rsaSignatureMessagePKCS1v15SHA256, message as CFData, signature as CFData, nil)
    }
}

/// IPv4 loopback only, never listens on LAN interfaces. Authorizations expire in 3 minutes.
@MainActor
final class OAuthLoopbackReceiver {
    private let state: String
    private let hostname: String
    private var listener: NWListener?
    private var startContinuation: CheckedContinuation<String, Error>?
    private var codeContinuation: CheckedContinuation<String, Error>?
    private var result: Result<String, Error>?
    private var timeout: Task<Void, Never>?
    private var connections: [UUID: NWConnection] = [:]
    private var expectedHost: String = ""

    init(state: String, hostname: String) { self.state = state; self.hostname = hostname }

    func start() async throws -> String {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let server = try NWListener(using: parameters)
        listener = server
        server.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in self?.accept(connection) }
        }
        return try await withCheckedThrowingContinuation { continuation in
            startContinuation = continuation
            server.stateUpdateHandler = { [weak self] status in
                Task { @MainActor in
                    guard let self else { return }
                    switch status {
                    case .ready:
                        guard let port = server.port, let pending = self.startContinuation else { return }
                        self.startContinuation = nil
                        self.expectedHost = "\(self.hostname):\(port.rawValue)"
                        self.timeout?.cancel()
                        self.timeout = Task { @MainActor [weak self] in
                            do { try await Task.sleep(nanoseconds: 180_000_000_000) } catch { return }
                            self?.finish(.failure(OAuthError.timeout))
                        }
                        pending.resume(returning: "http://\(self.expectedHost)/")
                    case .failed, .cancelled: self.finish(.failure(OAuthError.callbackInvalid))
                    default: break
                    }
                }
            }
            timeout = Task { @MainActor [weak self] in
                do { try await Task.sleep(nanoseconds: 5_000_000_000) } catch { return }
                self?.finish(.failure(OAuthError.timeout))
            }
            server.start(queue: .main)
        }
    }

    func waitForCode() async throws -> String {
        if let result { return try result.get() }
        return try await withCheckedThrowingContinuation { codeContinuation = $0 }
    }

    func cancel() { finish(.failure(OAuthError.cancelled)) }

    private func finish(_ final: Result<String, Error>) {
        guard result == nil else { return }
        result = final
        timeout?.cancel(); timeout = nil
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel(); listener = nil
        for connection in connections.values { connection.cancel() }
        connections.removeAll()
        if let pending = startContinuation {
            startContinuation = nil
            pending.resume(throwing: final.failureValue ?? OAuthError.callbackInvalid)
        }
        if let pending = codeContinuation { codeContinuation = nil; pending.resume(with: final) }
    }

    private func accept(_ connection: NWConnection) {
        guard result == nil, connections.count < 8 else { connection.cancel(); return }
        let id = UUID()
        connections[id] = connection
        connection.start(queue: .main)
        Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: 10_000_000_000) } catch { return }
            if let pending = self?.connections.removeValue(forKey: id) { pending.cancel() }
        }
        receive(connection, id: id, buffered: Data())
    }

    private func receive(_ connection: NWConnection, id: UUID, buffered: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, complete, error in
            Task { @MainActor in
                guard let self, self.connections[id] != nil else { return }
                var buffer = buffered
                if let data { buffer.append(data) }
                if buffer.count > 16_384 || error != nil { self.close(id); return }
                if let boundary = buffer.range(of: Data("\r\n\r\n".utf8)) {
                    self.process(buffer.prefix(upTo: boundary.lowerBound), connection: connection, id: id)
                } else if complete { self.close(id) }
                else { self.receive(connection, id: id, buffered: buffer) }
            }
        }
    }

    private func process(_ headerData: Data, connection: NWConnection, id: UUID) {
        guard let header = String(data: headerData, encoding: .utf8) else { close(id); return }
        let lines = header.components(separatedBy: "\r\n")
        let request = (lines.first ?? "").split(separator: " ", omittingEmptySubsequences: false)
        let hosts = lines.dropFirst().filter { $0.lowercased().hasPrefix("host:") }.map { String($0.dropFirst(5)).trimmingCharacters(in: .whitespaces) }
        guard request.count == 3, request[0] == "GET", hosts == [expectedHost] else {
            respond(connection, id: id, status: "400 Bad Request", message: "无效的授权回调。", outcome: nil); return
        }
        do {
            let code = try OAuthUtilities.callbackResult(target: String(request[1]), expectedState: state)
            respond(connection, id: id, status: "200 OK", message: "已收到授权结果，请返回搞门户的邮件窗口。应用将继续验证账号并保存授权。", outcome: .success(code))
        } catch let error as OAuthError {
            if case .provider = error {
                respond(connection, id: id, status: "200 OK", message: "本次授权未完成，请返回搞门户的邮件窗口查看原因。", outcome: .failure(error))
            } else {
                respond(connection, id: id, status: "400 Bad Request", message: "授权回调校验失败，请回到原授权页面继续。", outcome: nil)
            }
        } catch { close(id) }
    }

    private func respond(_ connection: NWConnection, id: UUID, status: String, message: String, outcome: Result<String, Error>?) {
        let body = Data("<!doctype html><html lang=\"zh-CN\"><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width\"><title>搞门户 · 邮件</title><body><h1>搞门户 · 邮件</h1><p>\(message)</p></body></html>".utf8)
        let header = Data("HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nReferrer-Policy: no-referrer\r\nContent-Security-Policy: default-src 'none'; frame-ancestors 'none'; base-uri 'none'\r\nConnection: close\r\n\r\n".utf8)
        connection.send(content: header + body, completion: .contentProcessed { [weak self] _ in
            Task { @MainActor in
                self?.close(id)
                if let outcome { self?.finish(outcome) }
            }
        })
    }
    private func close(_ id: UUID) { connections.removeValue(forKey: id)?.cancel() }
}

private extension Result {
    var failureValue: Failure? { if case .failure(let error) = self { return error }; return nil }
}
