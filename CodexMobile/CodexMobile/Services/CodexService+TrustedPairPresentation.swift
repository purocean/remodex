// FILE: CodexService+TrustedPairPresentation.swift
// Purpose: Derives a compact UI-facing summary for the connected or remembered Mac pair.
// Layer: Service extension
// Exports: CodexTrustedPairPresentation, CodexService trusted-pair presentation helpers
// Depends on: Foundation

import Foundation

struct CodexTrustedPairPresentation: Equatable, Sendable {
    let deviceId: String?
    let title: String
    let name: String
    let systemName: String?
    let detail: String?
}

enum SidebarMacNicknameStore {
    private static let keyPrefix = "codex.sidebarMacNickname."

    // Keeps sidebar aliases scoped to a stable Mac id instead of a single global setting.
    static func nickname(for deviceId: String?) -> String {
        guard let storageKey = storageKey(for: deviceId) else {
            return ""
        }

        return UserDefaults.standard.string(forKey: storageKey) ?? ""
    }

    // Clears blank aliases so stale names do not survive after users switch back to the system name.
    static func setNickname(_ nickname: String, for deviceId: String?) {
        guard let storageKey = storageKey(for: deviceId) else {
            return
        }

        let trimmed = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            UserDefaults.standard.removeObject(forKey: storageKey)
            return
        }

        UserDefaults.standard.set(trimmed, forKey: storageKey)
    }

    private static func storageKey(for deviceId: String?) -> String? {
        guard let deviceId = deviceId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !deviceId.isEmpty else {
            return nil
        }

        return keyPrefix + deviceId
    }
}

enum RelayURLPresetStore {
    private static let keyPrefix = "codex.relayURLPresets."

    static func presets(for deviceId: String?) -> [String] {
        guard let storageKey = storageKey(for: deviceId),
              let rawValues = UserDefaults.standard.array(forKey: storageKey) as? [String] else {
            return []
        }

        var seen = Set<String>()
        return rawValues.compactMap { normalizeRelayURL($0) }.filter { seen.insert($0).inserted }
    }

    static func savePreset(_ relayURL: String, for deviceId: String?) {
        guard let storageKey = storageKey(for: deviceId),
              let normalized = normalizeRelayURL(relayURL) else {
            return
        }

        var updated = presets(for: deviceId)
        updated.removeAll { $0 == normalized }
        updated.insert(normalized, at: 0)
        UserDefaults.standard.set(updated, forKey: storageKey)
    }

    static func deletePreset(_ relayURL: String, for deviceId: String?) {
        guard let storageKey = storageKey(for: deviceId),
              let normalized = normalizeRelayURL(relayURL) else {
            return
        }

        let updated = presets(for: deviceId).filter { $0 != normalized }
        if updated.isEmpty {
            UserDefaults.standard.removeObject(forKey: storageKey)
        } else {
            UserDefaults.standard.set(updated, forKey: storageKey)
        }
    }

    static func normalizeRelayURL(_ relayURL: String) -> String? {
        let trimmed = relayURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private static func storageKey(for deviceId: String?) -> String? {
        guard let deviceId = deviceId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !deviceId.isEmpty else {
            return nil
        }

        return keyPrefix + deviceId
    }
}

extension CodexService {
    // Builds the minimal pair summary shown by Home and Settings so both surfaces stay in sync.
    var trustedPairPresentation: CodexTrustedPairPresentation? {
        let macName = trustedPairDisplayName
        let macFingerprint = trustedPairFingerprint
        guard macName != nil || macFingerprint != nil else {
            return nil
        }

        let fallbackName = "Mac \(macFingerprint ?? "")".trimmingCharacters(in: .whitespacesAndNewlines)
        let systemName = macName ?? fallbackName
        let nickname = SidebarMacNicknameStore.nickname(for: trustedPairDeviceId)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveName = nickname.isEmpty ? systemName : nickname

        return CodexTrustedPairPresentation(
            deviceId: trustedPairDeviceId,
            title: trustedPairTitle,
            name: effectiveName,
            systemName: nickname.isEmpty ? nil : systemName,
            detail: trustedPairDetail(displayName: macName, fingerprint: macFingerprint)
        )
    }

    var editableRelayURL: String? {
        if let relayURL = normalizedRelayURL {
            return relayURL
        }

        guard let relayURL = preferredTrustedMacRecord?.relayURL?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !relayURL.isEmpty else {
            return nil
        }
        return relayURL
    }

    func updatePreferredRelayURL(_ relayURL: String) {
        guard let normalizedRelayURL = RelayURLPresetStore.normalizeRelayURL(relayURL) else {
            return
        }

        SecureStore.writeString(normalizedRelayURL, for: CodexSecureKeys.relayUrl)
        self.relayUrl = normalizedRelayURL

        if let preferredTrustedMacDeviceId,
           var trustedMac = trustedMacRegistry.records[preferredTrustedMacDeviceId] {
            trustedMac.relayURL = normalizedRelayURL
            trustedMac.lastUsedAt = Date()
            trustedMacRegistry.records[preferredTrustedMacDeviceId] = trustedMac
            SecureStore.writeCodable(trustedMacRegistry, for: CodexSecureKeys.trustedMacRegistry)
        }

        if !isConnected, let trustedMac = preferredTrustedMacRecord {
            secureMacFingerprint = codexSecureFingerprint(for: trustedMac.macIdentityPublicKey)
            secureConnectionState = .liveSessionUnresolved
        }
    }
}

private extension CodexService {
    // Chooses the Mac identity the UI should surface first: the live relay target when available,
    // otherwise the preferred trusted Mac remembered for reconnect.
    var visibleTrustedMacRecord: CodexTrustedMacRecord? {
        if let normalizedRelayMacDeviceId,
           let trustedMac = trustedMacRegistry.records[normalizedRelayMacDeviceId] {
            return trustedMac
        }

        return preferredTrustedMacRecord
    }

    // Reuses the connected device id when available, otherwise falls back to the saved preferred Mac.
    var trustedPairDeviceId: String? {
        normalizedRelayMacDeviceId ?? visibleTrustedMacRecord?.macDeviceId
    }

    var trustedPairDisplayName: String? {
        nonEmptyTrimmedString(visibleTrustedMacRecord?.displayName)
    }

    var trustedPairFingerprint: String? {
        nonEmptyTrimmedString(secureMacFingerprint)
            ?? normalizedRelayMacIdentityPublicKey.map { codexSecureFingerprint(for: $0) }
            ?? visibleTrustedMacRecord.map { codexSecureFingerprint(for: $0.macIdentityPublicKey) }
    }

    var trustedPairTitle: String {
        if isConnected || secureConnectionState == .encrypted {
            return "Connected Pair"
        }

        switch secureConnectionState {
        case .handshaking:
            return "Pairing Mac"
        case .liveSessionUnresolved, .reconnecting, .trustedMac:
            return "Saved Pair"
        case .rePairRequired:
            return "Previous Pair"
        case .updateRequired, .notPaired:
            return "Trusted Pair"
        case .encrypted:
            return "Connected Pair"
        }
    }

    // Shows both the human name and stable fingerprint when we have them, but keeps the summary compact.
    func trustedPairDetail(displayName: String?, fingerprint: String?) -> String? {
        var parts: [String] = [secureConnectionState.statusLabel]
        if displayName != nil, let fingerprint {
            parts.append(fingerprint)
        }
        let joined = parts.joined(separator: " · ")
        return joined.isEmpty ? nil : joined
    }

    func nonEmptyTrimmedString(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value
    }
}
