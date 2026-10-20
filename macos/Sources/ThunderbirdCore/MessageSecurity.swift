/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import Foundation
import Security

public struct MessageSecurityStatus: Sendable, Hashable {
  public var technology: SecurityTechnology
  public var encrypted: Bool
  public var signatures: [SignatureInfo]
  public var error: String?

  public var summary: String {
    var parts: [String] = []
    if encrypted { parts.append("Encrypted") }
    if let signature = signatures.first {
      switch signature.status {
      case .good: parts.append("Signed by \(signature.signer.isEmpty ? signature.keyID : signature.signer)")
      case .bad: parts.append("Invalid signature")
      case .unknownKey: parts.append("Signed with an unknown key \(signature.keyID)")
      case .expiredKey: parts.append("Signed with an expired key")
      }
    }
    if let error { parts.append(error) }
    return parts.joined(separator: " · ")
  }

  public var isTrustworthy: Bool {
    error == nil && signatures.allSatisfy { $0.status == .good }
  }
}

/// S/MIME using the Security framework's CMS support and certificates in the user's keychain.
public enum SMIME {
  public static func identity(for email: String) -> SecIdentity? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassIdentity,
      kSecMatchEmailAddressIfPresent as String: email,
      kSecReturnRef as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var result: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let result else { return nil }
    return (result as! SecIdentity)
  }

  public static func certificate(for email: String) -> SecCertificate? {
    if let identity = identity(for: email) {
      var certificate: SecCertificate?
      if SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess { return certificate }
    }
    let query: [String: Any] = [
      kSecClass as String: kSecClassCertificate,
      kSecMatchEmailAddressIfPresent as String: email,
      kSecReturnRef as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var result: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let result else { return nil }
    return (result as! SecCertificate)
  }

  public static func hasIdentity(for email: String) -> Bool { identity(for: email) != nil }

  private static func encode(_ content: Data, signers: [SecIdentity], recipients: [SecCertificate], detached: Bool) throws -> Data {
    var encoded: CFData?
    let status = content.withUnsafeBytes { buffer in
      CMSEncodeContent(
        signers.isEmpty ? nil : signers as CFArray,
        recipients.isEmpty ? nil : recipients as CFArray,
        nil, detached, [], buffer.baseAddress!, content.count, &encoded)
    }
    guard status == errSecSuccess, let encoded else {
      throw MailError.server("S/MIME encoding failed (\(status)).")
    }
    return encoded as Data
  }

  public static func sign(_ content: Data, email: String) throws -> Data {
    guard let identity = identity(for: email) else {
      throw MailError.server("No S/MIME certificate for \(email) was found in your keychain.")
    }
    return try encode(content, signers: [identity], recipients: [], detached: true)
  }

  public static func encrypt(_ content: Data, recipients: [String], sender: String) throws -> Data {
    var certificates: [SecCertificate] = []
    for email in Set(recipients + [sender]) {
      guard let certificate = certificate(for: email) else {
        throw MailError.server("No S/MIME certificate is available for \(email).")
      }
      certificates.append(certificate)
    }
    return try encode(content, signers: [], recipients: certificates, detached: false)
  }

  /// Decodes enveloped or signed CMS data; pass `detachedContent` for multipart/signed messages.
  public static func decode(_ cms: Data, detachedContent: Data? = nil) -> (content: Data, status: MessageSecurityStatus) {
    var status = MessageSecurityStatus(technology: .smime, encrypted: false, signatures: [])
    var decoder: CMSDecoder?
    guard CMSDecoderCreate(&decoder) == errSecSuccess, let decoder else {
      status.error = "S/MIME isn't available."
      return (Data(), status)
    }
    _ = cms.withUnsafeBytes { CMSDecoderUpdateMessage(decoder, $0.baseAddress!, cms.count) }
    if let detachedContent {
      CMSDecoderSetDetachedContent(decoder, detachedContent as CFData)
    }
    guard CMSDecoderFinalizeMessage(decoder) == errSecSuccess else {
      status.error = "This message couldn't be decrypted. Your certificate may be missing."
      return (Data(), status)
    }
    var encrypted: DarwinBoolean = false
    CMSDecoderIsContentEncrypted(decoder, &encrypted)
    status.encrypted = encrypted.boolValue
    var content: CFData?
    CMSDecoderCopyContent(decoder, &content)

    var signerCount = 0
    CMSDecoderGetNumSigners(decoder, &signerCount)
    let policy = SecPolicyCreateBasicX509()
    for index in 0..<signerCount {
      var signerStatus = CMSSignerStatus.unsigned
      var trust: SecTrust?
      var verifyResult: OSStatus = 0
      CMSDecoderCopySignerStatus(decoder, index, policy, true, &signerStatus, &trust, &verifyResult)
      var email: CFString?
      CMSDecoderCopySignerEmailAddress(decoder, index, &email)
      var certificate: SecCertificate?
      CMSDecoderCopySignerCert(decoder, index, &certificate)
      if let certificate {
        SecItemAdd([kSecClass as String: kSecClassCertificate, kSecValueRef as String: certificate] as CFDictionary, nil)
      }
      let mapped: SignatureInfo.Status =
        switch signerStatus {
        case .valid: .good
        case .needsDetachedContent, .unsigned: .unknownKey
        default: .bad
        }
      status.signatures.append(SignatureInfo(status: mapped, signer: (email as String?) ?? "", keyID: ""))
    }
    return ((content as Data?) ?? detachedContent ?? Data(), status)
  }
}

/// Wraps outgoing entities in PGP/MIME or S/MIME, and unwraps incoming messages for display.
public struct MessageSecurity: EntityProtector {
  public init() {}

  public func protect(entity: Data, security: OutgoingSecurity, from: MailAddress, recipients: [MailAddress]) throws -> Data {
    switch security.technology {
    case .openPGP: try protectOpenPGP(entity, security: security, from: from, recipients: recipients)
    case .smime: try protectSMIME(entity, security: security, from: from, recipients: recipients)
    }
  }

  private func protectOpenPGP(
    _ entity: Data, security: OutgoingSecurity, from: MailAddress, recipients: [MailAddress]
  ) throws -> Data {
    let pgp = OpenPGP.shared
    guard pgp.isAvailable else { throw MailError.unsupported("OpenPGP (librnp.dylib wasn't found)") }
    let signer = security.signerKey ?? pgp.keys(for: from.email).first(where: \.hasSecret)?.fingerprint
    if security.sign && signer == nil {
      throw MailError.server("Set up a personal OpenPGP key for \(from.email) in Account Settings.")
    }
    let boundary = OutgoingMessage.makeBoundary()
    if security.encrypt {
      var fingerprints: [String] = []
      for address in recipients + [from] {
        guard let key = pgp.keys(for: address.email).first else {
          throw MailError.server("No OpenPGP public key is available for \(address.email). Import it first.")
        }
        fingerprints.append(key.fingerprint)
      }
      let encrypted = try pgp.encrypt(
        entity, to: Array(Set(fingerprints)), signWith: security.sign ? signer : nil)
      let lines = [
        "Content-Type: multipart/encrypted; protocol=\"application/pgp-encrypted\"; boundary=\"\(boundary)\"", "",
        "This is an OpenPGP/MIME encrypted message (RFC 4880 and 3156)",
        "--\(boundary)", "Content-Type: application/pgp-encrypted", "Content-Description: PGP/MIME version identification",
        "", "Version: 1", "",
        "--\(boundary)", "Content-Type: application/octet-stream; name=\"encrypted.asc\"",
        "Content-Description: OpenPGP encrypted message", "Content-Disposition: inline; filename=\"encrypted.asc\"",
        "", String(decoding: encrypted, as: UTF8.self).replacingOccurrences(of: "\r\n", with: "\n")
          .replacingOccurrences(of: "\n", with: "\r\n"),
        "--\(boundary)--",
      ]
      return Data(lines.joined(separator: "\r\n").utf8)
    }
    let signature = try pgp.signDetached(entity, with: signer!)
    var output = Data(
      [
        "Content-Type: multipart/signed; micalg=pgp-sha256; protocol=\"application/pgp-signature\"; boundary=\"\(boundary)\"",
        "", "This is an OpenPGP/MIME signed message (RFC 4880 and 3156)", "--\(boundary)", "",
      ].joined(separator: "\r\n").utf8)
    output.append(entity)
    output.append(
      Data(
        [
          "", "--\(boundary)", "Content-Type: application/pgp-signature; name=\"OpenPGP_signature.asc\"",
          "Content-Description: OpenPGP digital signature", "Content-Disposition: attachment; filename=\"OpenPGP_signature.asc\"",
          "", String(decoding: signature, as: UTF8.self).replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\n", with: "\r\n"),
          "--\(boundary)--",
        ].joined(separator: "\r\n").utf8))
    return output
  }

  private func protectSMIME(
    _ entity: Data, security: OutgoingSecurity, from: MailAddress, recipients: [MailAddress]
  ) throws -> Data {
    var content = entity
    if security.sign {
      let signature = try SMIME.sign(entity, email: from.email)
      let boundary = OutgoingMessage.makeBoundary()
      var signed = Data(
        [
          "Content-Type: multipart/signed; protocol=\"application/pkcs7-signature\"; micalg=sha-256; boundary=\"\(boundary)\"",
          "", "This is a cryptographically signed message in MIME format.", "", "--\(boundary)", "",
        ].joined(separator: "\r\n").utf8)
      signed.append(entity)
      signed.append(
        Data(
          [
            "", "--\(boundary)", "Content-Type: application/pkcs7-signature; name=\"smime.p7s\"",
            "Content-Transfer-Encoding: base64", "Content-Disposition: attachment; filename=\"smime.p7s\"",
            "Content-Description: S/MIME Cryptographic Signature", "",
            signature.base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed]),
            "--\(boundary)--",
          ].joined(separator: "\r\n").utf8))
      content = signed
    }
    guard security.encrypt else { return content }
    let encrypted = try SMIME.encrypt(content, recipients: recipients.map(\.email), sender: from.email)
    return Data(
      [
        "Content-Type: application/pkcs7-mime; name=\"smime.p7m\"; smime-type=enveloped-data",
        "Content-Transfer-Encoding: base64", "Content-Disposition: attachment; filename=\"smime.p7m\"",
        "Content-Description: S/MIME Encrypted Message", "",
        encrypted.base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed]),
      ].joined(separator: "\r\n").utf8)
  }

  // MARK: - Incoming

  /// Decrypts and verifies a message. Returns the message to display (with decrypted content
  /// substituted) and its status, or nil status when the message isn't protected.
  public static func unprotect(_ data: Data) -> (data: Data, status: MessageSecurityStatus?) {
    let root = MIMEParser.parse(data)
    let protocolName = root.parameters["protocol"]?.lowercased()

    if root.contentType == "multipart/encrypted", protocolName == "application/pgp-encrypted", root.children.count >= 2 {
      var status = MessageSecurityStatus(technology: .openPGP, encrypted: true, signatures: [])
      do {
        let result = try OpenPGP.shared.decryptAndVerify(root.children[1].body)
        status.signatures = result.signatures
        return (replaceBody(of: data, with: result.plaintext), status)
      } catch {
        status.error = error.localizedDescription
        return (data, status)
      }
    }

    if root.contentType == "application/pkcs7-mime" || root.contentType == "application/x-pkcs7-mime" {
      let (content, status) = SMIME.decode(root.body)
      guard status.error == nil else { return (data, status) }
      let inner = replaceBody(of: data, with: content)
      let (nested, nestedStatus) = unprotect(inner)
      var merged = status
      if let nestedStatus { merged.signatures += nestedStatus.signatures }
      return (nested, merged)
    }

    if root.contentType == "multipart/signed", root.children.count >= 2 {
      let signed = root.children[0].raw
      let signature = root.children[1]
      if protocolName == "application/pgp-signature" {
        let signatures = OpenPGP.shared.verifyDetached(signed, signature: signature.body)
        var status = MessageSecurityStatus(technology: .openPGP, encrypted: false, signatures: signatures)
        if signatures.isEmpty {
          status.signatures = [SignatureInfo(status: .unknownKey, signer: "", keyID: "")]
        }
        return (data, status)
      }
      if protocolName?.contains("pkcs7-signature") == true {
        let (_, status) = SMIME.decode(signature.body, detachedContent: signed)
        return (data, status)
      }
    }

    if let text = firstText(root), text.contains("-----BEGIN PGP MESSAGE-----") || text.contains("-----BEGIN PGP SIGNED MESSAGE-----") {
      guard let start = text.range(of: "-----BEGIN PGP"), let end = text.range(of: "-----END PGP", range: start.upperBound..<text.endIndex),
        let lineEnd = text[end.upperBound...].firstIndex(of: "\n") ?? Optional(text.endIndex)
      else { return (data, nil) }
      let block = Data(text[start.lowerBound..<lineEnd].utf8)
      var status = MessageSecurityStatus(
        technology: .openPGP, encrypted: text.contains("BEGIN PGP MESSAGE"), signatures: [])
      do {
        let result = try OpenPGP.shared.decryptAndVerify(block)
        status.signatures = result.signatures
        let plain = String(decoding: result.plaintext, as: UTF8.self)
        let replaced = text.replacingCharacters(in: start.lowerBound..<lineEnd, with: plain)
        let entity = "Content-Type: text/plain; charset=UTF-8\r\nContent-Transfer-Encoding: 8bit\r\n\r\n" + replaced
        return (replaceBody(of: data, with: Data(entity.utf8)), status)
      } catch {
        status.error = error.localizedDescription
        return (data, status)
      }
    }
    return (data, nil)
  }

  private static func firstText(_ part: MIMEPart) -> String? {
    if part.isMultipart {
      return part.children.lazy.compactMap(firstText).first
    }
    return part.contentType == "text/plain" ? part.text : nil
  }

  /// Keeps the outer message headers (except MIME ones) and substitutes a new body entity,
  /// honouring protected headers such as Subject in the inner part.
  static func replaceBody(of message: Data, with entity: Data) -> Data {
    let outer = MIMEParser.parseHeaders(message)
    let inner = MIMEParser.parseHeaders(entity)
    var lines: [String] = []
    for field in outer.fields {
      let name = field.name.lowercased()
      if name.hasPrefix("content-") || name == "mime-version" { continue }
      if name == "subject", let protected = inner["Subject"] {
        lines.append("Subject: \(protected)")
        continue
      }
      lines.append("\(field.name): \(field.value)")
    }
    lines.append("MIME-Version: 1.0")
    var output = Data((lines.joined(separator: "\r\n") + "\r\n").utf8)
    output.append(entity)
    return output
  }
}
