/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import Darwin
import Foundation

public struct OpenPGPKey: Sendable, Hashable, Identifiable {
  public var fingerprint: String
  public var keyID: String
  public var userID: String
  public var hasSecret: Bool
  public var isUsable: Bool
  public var expires: Date?
  public var id: String { fingerprint }

  public var email: String? {
    MailAddress.parseList(userID).first?.email
  }
}

public struct SignatureInfo: Sendable, Hashable {
  public enum Status: Sendable, Hashable {
    case good
    case bad
    case unknownKey
    case expiredKey
  }

  public var status: Status
  public var signer: String
  public var keyID: String
}

/// OpenPGP using RNP, the library Thunderbird bundles, loaded at runtime from the app bundle or an
/// installed Thunderbird.
public final class OpenPGP: @unchecked Sendable {
  public static let shared = OpenPGP()

  /// Supplies key passphrases. Called on a background thread; return nil to cancel.
  public nonisolated(unsafe) static var passphraseProvider: (@Sendable (String) -> String?)?

  private typealias Result = UInt32
  private typealias Handle = OpaquePointer?
  private typealias PassCallback = @convention(c) (
    OpaquePointer?, UnsafeMutableRawPointer?, OpaquePointer?, UnsafePointer<CChar>?, UnsafeMutablePointer<CChar>?, Int
  ) -> Bool

  private struct API {
    var ffiCreate: @convention(c) (UnsafeMutablePointer<Handle>, UnsafePointer<CChar>, UnsafePointer<CChar>) -> Result
    var setPassProvider: @convention(c) (Handle, PassCallback?, UnsafeMutableRawPointer?) -> Result
    var inputFromMemory: @convention(c) (UnsafeMutablePointer<Handle>, UnsafePointer<UInt8>?, Int, Bool) -> Result
    var inputFromPath: @convention(c) (UnsafeMutablePointer<Handle>, UnsafePointer<CChar>) -> Result
    var outputToMemory: @convention(c) (UnsafeMutablePointer<Handle>, Int) -> Result
    var outputToPath: @convention(c) (UnsafeMutablePointer<Handle>, UnsafePointer<CChar>) -> Result
    var outputGetBuffer: @convention(c) (Handle, UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>, UnsafeMutablePointer<Int>, Bool) -> Result
    var inputDestroy: @convention(c) (Handle) -> Result
    var outputDestroy: @convention(c) (Handle) -> Result
    var loadKeys: @convention(c) (Handle, UnsafePointer<CChar>, Handle, UInt32) -> Result
    var saveKeys: @convention(c) (Handle, UnsafePointer<CChar>, Handle, UInt32) -> Result
    var importKeys: @convention(c) (Handle, Handle, UInt32, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Result
    var locateKey: @convention(c) (Handle, UnsafePointer<CChar>, UnsafePointer<CChar>, UnsafeMutablePointer<Handle>) -> Result
    var keyDestroy: @convention(c) (Handle) -> Result
    var keyFingerprint: @convention(c) (Handle, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Result
    var keyID: @convention(c) (Handle, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Result
    var keyPrimaryUID: @convention(c) (Handle, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Result
    var keyHasSecret: @convention(c) (Handle, UnsafeMutablePointer<Bool>) -> Result
    var keyIsRevoked: @convention(c) (Handle, UnsafeMutablePointer<Bool>) -> Result
    var keyIsExpired: @convention(c) (Handle, UnsafeMutablePointer<Bool>) -> Result
    var keyValidTill: @convention(c) (Handle, UnsafeMutablePointer<UInt64>) -> Result
    var keyExport: @convention(c) (Handle, Handle, UInt32) -> Result
    var keyRemove: @convention(c) (Handle, UInt32) -> Result
    var iteratorCreate: @convention(c) (Handle, UnsafeMutablePointer<Handle>, UnsafePointer<CChar>) -> Result
    var iteratorNext: @convention(c) (Handle, UnsafeMutablePointer<UnsafePointer<CChar>?>) -> Result
    var iteratorDestroy: @convention(c) (Handle) -> Result
    var encryptCreate: @convention(c) (UnsafeMutablePointer<Handle>, Handle, Handle, Handle) -> Result
    var encryptAddRecipient: @convention(c) (Handle, Handle) -> Result
    var encryptAddSignature: @convention(c) (Handle, Handle, UnsafeMutablePointer<Handle>?) -> Result
    var encryptSetArmor: @convention(c) (Handle, Bool) -> Result
    var encryptExecute: @convention(c) (Handle) -> Result
    var encryptDestroy: @convention(c) (Handle) -> Result
    var signDetachedCreate: @convention(c) (UnsafeMutablePointer<Handle>, Handle, Handle, Handle) -> Result
    var signAddSignature: @convention(c) (Handle, Handle, UnsafeMutablePointer<Handle>?) -> Result
    var signSetArmor: @convention(c) (Handle, Bool) -> Result
    var signSetHash: @convention(c) (Handle, UnsafePointer<CChar>) -> Result
    var signExecute: @convention(c) (Handle) -> Result
    var signDestroy: @convention(c) (Handle) -> Result
    var verifyCreate: @convention(c) (UnsafeMutablePointer<Handle>, Handle, Handle, Handle) -> Result
    var verifyDetachedCreate: @convention(c) (UnsafeMutablePointer<Handle>, Handle, Handle, Handle) -> Result
    var verifyExecute: @convention(c) (Handle) -> Result
    var verifySignatureCount: @convention(c) (Handle, UnsafeMutablePointer<Int>) -> Result
    var verifySignatureAt: @convention(c) (Handle, Int, UnsafeMutablePointer<Handle>) -> Result
    var signatureStatus: @convention(c) (Handle) -> Result
    var signatureKey: @convention(c) (Handle, UnsafeMutablePointer<Handle>) -> Result
    var protectionInfo: @convention(c) (Handle, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?, UnsafeMutablePointer<Bool>?) -> Result
    var verifyDestroy: @convention(c) (Handle) -> Result
    var generate25519: @convention(c) (Handle, UnsafePointer<CChar>, UnsafePointer<CChar>?, UnsafeMutablePointer<Handle>) -> Result
    var bufferDestroy: @convention(c) (UnsafeMutableRawPointer?) -> Void
  }

  private static let exportArmored: UInt32 = 1 << 0
  private static let exportPublic: UInt32 = 1 << 1
  private static let exportSubkeys: UInt32 = 1 << 3
  private static let loadPublic: UInt32 = 1 << 0
  private static let loadSecret: UInt32 = 1 << 1
  private static let loadPermissive: UInt32 = 1 << 8
  private static let removeAll: UInt32 = 0b111

  private let api: API?
  private var ffi: Handle = nil
  private let lock = NSRecursiveLock()
  private let directory: URL
  private var passphraseCache: [String: String] = [:]
  public let libraryPath: String?

  public var isAvailable: Bool { api != nil && ffi != nil }

  private init() {
    let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    if let override = ProcessInfo.processInfo.environment["TB_OPENPGP_DIR"] {
      directory = URL(filePath: override, directoryHint: .isDirectory)
    } else {
      directory = support.appending(path: "Thunderbird for macOS/OpenPGP", directoryHint: .isDirectory)
    }
    var candidates: [String] = []
    if let override = ProcessInfo.processInfo.environment["TB_LIBRNP"] { candidates.append(override) }
    if let frameworks = Bundle.main.privateFrameworksPath { candidates.append("\(frameworks)/librnp.dylib") }
    candidates.append(Bundle.main.bundleURL.appending(path: "Contents/MacOS/librnp.dylib").path)
    candidates.append("/Applications/Thunderbird.app/Contents/MacOS/librnp.dylib")
    var loaded: (UnsafeMutableRawPointer, String)?
    for path in candidates where FileManager.default.fileExists(atPath: path) {
      if let handle = dlopen(path, RTLD_NOW | RTLD_LOCAL) {
        loaded = (handle, path)
        break
      }
    }
    libraryPath = loaded?.1
    api = loaded.flatMap { Self.bind($0.0) }
    guard let api else { return }
    _ = "GPG".withCString { format in api.ffiCreate(&ffi, format, format) }
    let context = Unmanaged.passUnretained(self).toOpaque()
    _ = api.setPassProvider(ffi, OpenPGP.passCallback, context)
    loadKeyrings()
  }

  private static func bind(_ handle: UnsafeMutableRawPointer) -> API? {
    func f<T>(_ name: String) -> T? {
      dlsym(handle, name).map { unsafeBitCast($0, to: T.self) }
    }
    guard let ffiCreate: @convention(c) (UnsafeMutablePointer<Handle>, UnsafePointer<CChar>, UnsafePointer<CChar>) -> Result = f("rnp_ffi_create"),
      let setPassProvider: @convention(c) (Handle, PassCallback?, UnsafeMutableRawPointer?) -> Result = f("rnp_ffi_set_pass_provider"),
      let inputFromMemory: @convention(c) (UnsafeMutablePointer<Handle>, UnsafePointer<UInt8>?, Int, Bool) -> Result = f("rnp_input_from_memory"),
      let inputFromPath: @convention(c) (UnsafeMutablePointer<Handle>, UnsafePointer<CChar>) -> Result = f("rnp_input_from_path"),
      let outputToMemory: @convention(c) (UnsafeMutablePointer<Handle>, Int) -> Result = f("rnp_output_to_memory"),
      let outputToPath: @convention(c) (UnsafeMutablePointer<Handle>, UnsafePointer<CChar>) -> Result = f("rnp_output_to_path"),
      let outputGetBuffer: @convention(c) (Handle, UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>, UnsafeMutablePointer<Int>, Bool) -> Result = f("rnp_output_memory_get_buf"),
      let inputDestroy: @convention(c) (Handle) -> Result = f("rnp_input_destroy"),
      let outputDestroy: @convention(c) (Handle) -> Result = f("rnp_output_destroy"),
      let loadKeys: @convention(c) (Handle, UnsafePointer<CChar>, Handle, UInt32) -> Result = f("rnp_load_keys"),
      let saveKeys: @convention(c) (Handle, UnsafePointer<CChar>, Handle, UInt32) -> Result = f("rnp_save_keys"),
      let importKeys: @convention(c) (Handle, Handle, UInt32, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Result = f("rnp_import_keys"),
      let locateKey: @convention(c) (Handle, UnsafePointer<CChar>, UnsafePointer<CChar>, UnsafeMutablePointer<Handle>) -> Result = f("rnp_locate_key"),
      let keyDestroy: @convention(c) (Handle) -> Result = f("rnp_key_handle_destroy"),
      let keyFingerprint: @convention(c) (Handle, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Result = f("rnp_key_get_fprint"),
      let keyID: @convention(c) (Handle, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Result = f("rnp_key_get_keyid"),
      let keyPrimaryUID: @convention(c) (Handle, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Result = f("rnp_key_get_primary_uid"),
      let keyHasSecret: @convention(c) (Handle, UnsafeMutablePointer<Bool>) -> Result = f("rnp_key_have_secret"),
      let keyIsRevoked: @convention(c) (Handle, UnsafeMutablePointer<Bool>) -> Result = f("rnp_key_is_revoked"),
      let keyIsExpired: @convention(c) (Handle, UnsafeMutablePointer<Bool>) -> Result = f("rnp_key_is_expired"),
      let keyValidTill: @convention(c) (Handle, UnsafeMutablePointer<UInt64>) -> Result = f("rnp_key_valid_till64"),
      let keyExport: @convention(c) (Handle, Handle, UInt32) -> Result = f("rnp_key_export"),
      let keyRemove: @convention(c) (Handle, UInt32) -> Result = f("rnp_key_remove"),
      let iteratorCreate: @convention(c) (Handle, UnsafeMutablePointer<Handle>, UnsafePointer<CChar>) -> Result = f("rnp_identifier_iterator_create"),
      let iteratorNext: @convention(c) (Handle, UnsafeMutablePointer<UnsafePointer<CChar>?>) -> Result = f("rnp_identifier_iterator_next"),
      let iteratorDestroy: @convention(c) (Handle) -> Result = f("rnp_identifier_iterator_destroy"),
      let encryptCreate: @convention(c) (UnsafeMutablePointer<Handle>, Handle, Handle, Handle) -> Result = f("rnp_op_encrypt_create"),
      let encryptAddRecipient: @convention(c) (Handle, Handle) -> Result = f("rnp_op_encrypt_add_recipient"),
      let encryptAddSignature: @convention(c) (Handle, Handle, UnsafeMutablePointer<Handle>?) -> Result = f("rnp_op_encrypt_add_signature"),
      let encryptSetArmor: @convention(c) (Handle, Bool) -> Result = f("rnp_op_encrypt_set_armor"),
      let encryptExecute: @convention(c) (Handle) -> Result = f("rnp_op_encrypt_execute"),
      let encryptDestroy: @convention(c) (Handle) -> Result = f("rnp_op_encrypt_destroy"),
      let signDetachedCreate: @convention(c) (UnsafeMutablePointer<Handle>, Handle, Handle, Handle) -> Result = f("rnp_op_sign_detached_create"),
      let signAddSignature: @convention(c) (Handle, Handle, UnsafeMutablePointer<Handle>?) -> Result = f("rnp_op_sign_add_signature"),
      let signSetArmor: @convention(c) (Handle, Bool) -> Result = f("rnp_op_sign_set_armor"),
      let signSetHash: @convention(c) (Handle, UnsafePointer<CChar>) -> Result = f("rnp_op_sign_set_hash"),
      let signExecute: @convention(c) (Handle) -> Result = f("rnp_op_sign_execute"),
      let signDestroy: @convention(c) (Handle) -> Result = f("rnp_op_sign_destroy"),
      let verifyCreate: @convention(c) (UnsafeMutablePointer<Handle>, Handle, Handle, Handle) -> Result = f("rnp_op_verify_create"),
      let verifyDetachedCreate: @convention(c) (UnsafeMutablePointer<Handle>, Handle, Handle, Handle) -> Result = f("rnp_op_verify_detached_create"),
      let verifyExecute: @convention(c) (Handle) -> Result = f("rnp_op_verify_execute"),
      let verifySignatureCount: @convention(c) (Handle, UnsafeMutablePointer<Int>) -> Result = f("rnp_op_verify_get_signature_count"),
      let verifySignatureAt: @convention(c) (Handle, Int, UnsafeMutablePointer<Handle>) -> Result = f("rnp_op_verify_get_signature_at"),
      let signatureStatus: @convention(c) (Handle) -> Result = f("rnp_op_verify_signature_get_status"),
      let signatureKey: @convention(c) (Handle, UnsafeMutablePointer<Handle>) -> Result = f("rnp_op_verify_signature_get_key"),
      let protectionInfo: @convention(c) (Handle, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?, UnsafeMutablePointer<Bool>?) -> Result = f("rnp_op_verify_get_protection_info"),
      let verifyDestroy: @convention(c) (Handle) -> Result = f("rnp_op_verify_destroy"),
      let generate25519: @convention(c) (Handle, UnsafePointer<CChar>, UnsafePointer<CChar>?, UnsafeMutablePointer<Handle>) -> Result = f("rnp_generate_key_25519"),
      let bufferDestroy: @convention(c) (UnsafeMutableRawPointer?) -> Void = f("rnp_buffer_destroy")
    else { return nil }
    return API(
      ffiCreate: ffiCreate, setPassProvider: setPassProvider, inputFromMemory: inputFromMemory,
      inputFromPath: inputFromPath, outputToMemory: outputToMemory, outputToPath: outputToPath,
      outputGetBuffer: outputGetBuffer, inputDestroy: inputDestroy, outputDestroy: outputDestroy,
      loadKeys: loadKeys, saveKeys: saveKeys, importKeys: importKeys, locateKey: locateKey, keyDestroy: keyDestroy,
      keyFingerprint: keyFingerprint, keyID: keyID, keyPrimaryUID: keyPrimaryUID, keyHasSecret: keyHasSecret,
      keyIsRevoked: keyIsRevoked, keyIsExpired: keyIsExpired, keyValidTill: keyValidTill, keyExport: keyExport,
      keyRemove: keyRemove, iteratorCreate: iteratorCreate, iteratorNext: iteratorNext,
      iteratorDestroy: iteratorDestroy, encryptCreate: encryptCreate, encryptAddRecipient: encryptAddRecipient,
      encryptAddSignature: encryptAddSignature, encryptSetArmor: encryptSetArmor, encryptExecute: encryptExecute,
      encryptDestroy: encryptDestroy, signDetachedCreate: signDetachedCreate, signAddSignature: signAddSignature,
      signSetArmor: signSetArmor, signSetHash: signSetHash, signExecute: signExecute, signDestroy: signDestroy,
      verifyCreate: verifyCreate, verifyDetachedCreate: verifyDetachedCreate, verifyExecute: verifyExecute,
      verifySignatureCount: verifySignatureCount, verifySignatureAt: verifySignatureAt,
      signatureStatus: signatureStatus, signatureKey: signatureKey, protectionInfo: protectionInfo,
      verifyDestroy: verifyDestroy, generate25519: generate25519, bufferDestroy: bufferDestroy)
  }

  private static let passCallback: PassCallback = { _, context, key, _, buffer, length in
    guard let context, let buffer else { return false }
    let engine = Unmanaged<OpenPGP>.fromOpaque(context).takeUnretainedValue()
    return engine.providePassphrase(key: key, buffer: buffer, length: length)
  }

  private func providePassphrase(key: Handle, buffer: UnsafeMutablePointer<CChar>, length: Int) -> Bool {
    let fingerprint = key.flatMap { string(api!.keyFingerprint, $0) } ?? ""
    let label = key.flatMap { string(api!.keyPrimaryUID, $0) } ?? fingerprint
    let passphrase = passphraseCache[fingerprint] ?? OpenPGP.passphraseProvider?(label)
    guard let passphrase, passphrase.utf8.count < length else { return false }
    passphraseCache[fingerprint] = passphrase
    _ = passphrase.withCString { strncpy(buffer, $0, length) }
    return true
  }

  // MARK: - Helpers

  private var publicRing: URL { directory.appending(path: "pubring.gpg") }
  private var secretRing: URL { directory.appending(path: "secring.gpg") }

  private func string(
    _ getter: @convention(c) (Handle, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Result, _ key: Handle
  ) -> String? {
    var pointer: UnsafeMutablePointer<CChar>?
    guard getter(key, &pointer) == 0, let pointer else { return nil }
    defer { api?.bufferDestroy(pointer) }
    return String(cString: pointer)
  }

  private func check(_ result: Result, _ what: String) throws {
    guard result == 0 else {
      throw MailError.server("OpenPGP \(what) failed (error 0x\(String(result, radix: 16))).")
    }
  }

  private func withInput<T>(_ data: Data, _ body: (Handle) throws -> T) throws -> T {
    guard let api else { throw MailError.unsupported("OpenPGP") }
    var input: Handle = nil
    let result = data.withUnsafeBytes { buffer in
      api.inputFromMemory(&input, buffer.bindMemory(to: UInt8.self).baseAddress, data.count, true)
    }
    try check(result, "input")
    defer { _ = api.inputDestroy(input) }
    return try body(input)
  }

  private func withOutput(_ body: (Handle) throws -> Void) throws -> Data {
    guard let api else { throw MailError.unsupported("OpenPGP") }
    var output: Handle = nil
    try check(api.outputToMemory(&output, 0), "output")
    defer { _ = api.outputDestroy(output) }
    try body(output)
    var buffer: UnsafeMutablePointer<UInt8>?
    var length = 0
    try check(api.outputGetBuffer(output, &buffer, &length, false), "output")
    guard let buffer else { return Data() }
    return Data(bytes: buffer, count: length)
  }

  private func loadKeyrings() {
    guard let api else { return }
    for (url, flags) in [(publicRing, Self.loadPublic), (secretRing, Self.loadSecret)]
    where FileManager.default.fileExists(atPath: url.path) {
      var input: Handle = nil
      guard url.path.withCString({ api.inputFromPath(&input, $0) }) == 0 else { continue }
      _ = "GPG".withCString { api.loadKeys(ffi, $0, input, flags | Self.loadPermissive) }
      _ = api.inputDestroy(input)
    }
  }

  private func saveKeyrings() {
    guard let api else { return }
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    for (url, flags) in [(publicRing, Self.loadPublic), (secretRing, Self.loadSecret)] {
      var output: Handle = nil
      guard url.path.withCString({ api.outputToPath(&output, $0) }) == 0 else { continue }
      _ = "GPG".withCString { api.saveKeys(ffi, $0, output, flags) }
      _ = api.outputDestroy(output)
    }
  }

  private func withKey<T>(_ fingerprint: String, _ body: (Handle) throws -> T) throws -> T {
    guard let api else { throw MailError.unsupported("OpenPGP") }
    var key: Handle = nil
    let result = "fingerprint".withCString { type in fingerprint.withCString { api.locateKey(ffi, type, $0, &key) } }
    guard result == 0, key != nil else { throw MailError.server("No OpenPGP key \(fingerprint) is available.") }
    defer { _ = api.keyDestroy(key) }
    return try body(key)
  }

  private func describe(_ key: Handle) -> OpenPGPKey? {
    guard let api, let fingerprint = string(api.keyFingerprint, key) else { return nil }
    var secret = false
    var revoked = false
    var expired = false
    var validTill: UInt64 = 0
    _ = api.keyHasSecret(key, &secret)
    _ = api.keyIsRevoked(key, &revoked)
    _ = api.keyIsExpired(key, &expired)
    _ = api.keyValidTill(key, &validTill)
    return OpenPGPKey(
      fingerprint: fingerprint,
      keyID: string(api.keyID, key) ?? "",
      userID: string(api.keyPrimaryUID, key) ?? "",
      hasSecret: secret,
      isUsable: !revoked && !expired,
      expires: validTill == 0 || validTill == UInt64.max ? nil : Date(timeIntervalSince1970: TimeInterval(validTill))
    )
  }

  // MARK: - Key management

  public func keys() -> [OpenPGPKey] {
    lock.lock()
    defer { lock.unlock() }
    guard let api else { return [] }
    var iterator: Handle = nil
    guard "fingerprint".withCString({ api.iteratorCreate(ffi, &iterator, $0) }) == 0 else { return [] }
    defer { _ = api.iteratorDestroy(iterator) }
    var result: [OpenPGPKey] = []
    var seen = Set<String>()
    while true {
      var identifier: UnsafePointer<CChar>?
      guard api.iteratorNext(iterator, &identifier) == 0, let identifier else { break }
      let fingerprint = String(cString: identifier)
      guard let key = try? withKey(fingerprint, { describe($0) }), !key.userID.isEmpty else { continue }
      if seen.insert(key.fingerprint).inserted { result.append(key) }
    }
    return result.sorted { $0.userID.localizedCaseInsensitiveCompare($1.userID) == .orderedAscending }
  }

  public func keys(for email: String) -> [OpenPGPKey] {
    keys().filter { $0.isUsable && $0.userID.lowercased().contains("<\(email.lowercased())>") }
  }

  @discardableResult
  public func importKeys(_ data: Data) throws -> Int {
    lock.lock()
    defer { lock.unlock() }
    guard let api else { throw MailError.unsupported("OpenPGP") }
    let before = keys().count
    try withInput(data) { input in
      try check(api.importKeys(ffi, input, Self.loadPublic | Self.loadSecret | Self.loadPermissive, nil), "import")
    }
    saveKeyrings()
    return keys().count - before
  }

  public func exportPublicKey(_ fingerprint: String) throws -> String {
    lock.lock()
    defer { lock.unlock() }
    guard let api else { throw MailError.unsupported("OpenPGP") }
    let data = try withKey(fingerprint) { key in
      try withOutput { output in
        try check(api.keyExport(key, output, Self.exportPublic | Self.exportSubkeys | Self.exportArmored), "export")
      }
    }
    return String(decoding: data, as: UTF8.self)
  }

  public func generateKey(name: String, email: String, passphrase: String?) throws -> OpenPGPKey {
    lock.lock()
    defer { lock.unlock() }
    guard let api else { throw MailError.unsupported("OpenPGP") }
    var key: Handle = nil
    let userID = MailAddress(name: name, email: email).formatted
    let result = userID.withCString { uid in
      if let passphrase, !passphrase.isEmpty {
        return passphrase.withCString { api.generate25519(ffi, uid, $0, &key) }
      }
      return api.generate25519(ffi, uid, nil, &key)
    }
    try check(result, "key generation")
    defer { _ = api.keyDestroy(key) }
    saveKeyrings()
    guard let described = describe(key) else { throw MailError.server("The new key couldn't be read.") }
    return described
  }

  public func deleteKey(_ fingerprint: String) throws {
    lock.lock()
    defer { lock.unlock() }
    guard let api else { throw MailError.unsupported("OpenPGP") }
    try withKey(fingerprint) { try check(api.keyRemove($0, Self.removeAll), "delete") }
    saveKeyrings()
  }

  /// Looks a key up on keys.openpgp.org (VKS), as Thunderbird's Key Assistant does, and imports it.
  public func discoverKey(for email: String) async throws -> Int {
    let encoded = email.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? email
    guard let url = URL(string: "https://keys.openpgp.org/vks/v1/by-email/\(encoded)") else { return 0 }
    let (data, response) = try await URLSession.shared.data(from: url)
    guard (response as? HTTPURLResponse)?.statusCode == 200 else { return 0 }
    return try importKeys(data)
  }

  // MARK: - Operations

  public func encrypt(_ data: Data, to recipients: [String], signWith signer: String?) throws -> Data {
    lock.lock()
    defer { lock.unlock() }
    guard let api else { throw MailError.unsupported("OpenPGP") }
    return try withInput(data) { input in
      try withOutput { output in
        var op: Handle = nil
        try check(api.encryptCreate(&op, ffi, input, output), "encryption")
        defer { _ = api.encryptDestroy(op) }
        for fingerprint in recipients {
          try withKey(fingerprint) { try check(api.encryptAddRecipient(op, $0), "adding recipient") }
        }
        if let signer {
          try withKey(signer) { try check(api.encryptAddSignature(op, $0, nil), "adding signature") }
        }
        _ = api.encryptSetArmor(op, true)
        try check(api.encryptExecute(op), "encryption")
      }
    }
  }

  public func signDetached(_ data: Data, with signer: String) throws -> Data {
    lock.lock()
    defer { lock.unlock() }
    guard let api else { throw MailError.unsupported("OpenPGP") }
    return try withInput(data) { input in
      try withOutput { output in
        var op: Handle = nil
        try check(api.signDetachedCreate(&op, ffi, input, output), "signing")
        defer { _ = api.signDestroy(op) }
        try withKey(signer) { try check(api.signAddSignature(op, $0, nil), "adding signature") }
        _ = api.signSetArmor(op, true)
        _ = "SHA256".withCString { api.signSetHash(op, $0) }
        try check(api.signExecute(op), "signing")
      }
    }
  }

  private func signatures(_ op: Handle) -> [SignatureInfo] {
    guard let api else { return [] }
    var count = 0
    _ = api.verifySignatureCount(op, &count)
    return (0..<count).compactMap { index in
      var signature: Handle = nil
      guard api.verifySignatureAt(op, index, &signature) == 0 else { return nil }
      let status = api.signatureStatus(signature)
      var key: Handle = nil
      _ = api.signatureKey(signature, &key)
      let described = key.flatMap { describe($0) }
      if key != nil { _ = api.keyDestroy(key) }
      let mapped: SignatureInfo.Status =
        switch status {
        case 0: .good
        case 0x1200_000C: .expiredKey
        case 0x1200_0005, 0x1200_000E: .unknownKey
        default: described == nil ? .unknownKey : .bad
        }
      return SignatureInfo(status: mapped, signer: described?.userID ?? "", keyID: described?.keyID ?? "")
    }
  }

  /// Decrypts and/or verifies an OpenPGP message (armored or binary, including cleartext-signed text).
  public func decryptAndVerify(_ data: Data) throws -> (plaintext: Data, encrypted: Bool, signatures: [SignatureInfo]) {
    lock.lock()
    defer { lock.unlock() }
    guard let api else { throw MailError.unsupported("OpenPGP") }
    var encrypted = false
    var found: [SignatureInfo] = []
    let plaintext = try withInput(data) { input in
      try withOutput { output in
        var op: Handle = nil
        try check(api.verifyCreate(&op, ffi, input, output), "decryption")
        defer { _ = api.verifyDestroy(op) }
        let result = api.verifyExecute(op)
        var mode: UnsafeMutablePointer<CChar>?
        if api.protectionInfo(op, &mode, nil, nil) == 0, let mode {
          encrypted = String(cString: mode) != "none"
          api.bufferDestroy(mode)
        }
        found = signatures(op)
        if result != 0 && found.isEmpty {
          throw MailError.server("This message couldn't be decrypted. The secret key may be missing.")
        }
      }
    }
    return (plaintext, encrypted, found)
  }

  public func verifyDetached(_ data: Data, signature: Data) -> [SignatureInfo] {
    lock.lock()
    defer { lock.unlock() }
    guard let api else { return [] }
    return (try? withInput(data) { input in
      try withInput(signature) { signatureInput in
        var op: Handle = nil
        try check(api.verifyDetachedCreate(&op, ffi, input, signatureInput), "verification")
        defer { _ = api.verifyDestroy(op) }
        _ = api.verifyExecute(op)
        return signatures(op)
      }
    }) ?? []
  }
}
