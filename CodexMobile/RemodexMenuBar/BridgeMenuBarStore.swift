// FILE: BridgeMenuBarStore.swift
// Purpose: Owns CLI gating, bridge polling, command execution, and local relay override persistence for the menu bar control center.
// Layer: Companion app state
// Exports: BridgeMenuBarStore
// Depends on: AppKit, Combine, Foundation, BridgeControlService, BridgeControlModels

import AppKit
import Combine
import Foundation

enum BridgeMenuBarActionError: LocalizedError {
    case missingCLI
    case brokenCLI(String)
    case pairingTimeout

    var errorDescription: String? {
        switch self {
        case .missingCLI:
            return "Install the global `remodex` CLI before using this companion."
        case .brokenCLI(let message):
            return message
        case .pairingTimeout:
            return "The bridge did not publish a fresh pairing session in time. Check the daemon logs and try again."
        }
    }
}

@MainActor
final class BridgeMenuBarStore: ObservableObject {
    @Published var snapshot: BridgeSnapshot?
    @Published var updateState = BridgePackageUpdateState.empty
    @Published var cliAvailability: BridgeCLIAvailability = .checking
    @Published var relayOverride: String
    @Published var localRelayURL: String?
    @Published var localRelayHostname: String
    @Published var localRelayBindHost: String
    @Published var localRelayPort: String
    @Published var isRefreshing = false
    @Published var isPerformingAction = false
    @Published var transientMessage = ""
    @Published var errorMessage = ""

    private static let relayOverrideKey = "remodex.menuBar.relayOverride"
    private static let localRelayHostnameKey = "remodex.menuBar.localRelay.hostname"
    private static let localRelayBindHostKey = "remodex.menuBar.localRelay.bindHost"
    private static let localRelayPortKey = "remodex.menuBar.localRelay.port"
    private let service: BridgeControlService
    private var refreshLoopTask: Task<Void, Never>?

    init(service: BridgeControlService? = nil) {
        self.service = service ?? BridgeControlService()
        self.relayOverride = UserDefaults.standard.string(forKey: Self.relayOverrideKey) ?? ""
        self.localRelayHostname = UserDefaults.standard.string(forKey: Self.localRelayHostnameKey) ?? ""
        self.localRelayBindHost = UserDefaults.standard.string(forKey: Self.localRelayBindHostKey) ?? "0.0.0.0"
        self.localRelayPort = UserDefaults.standard.string(forKey: Self.localRelayPortKey) ?? "9000"
        startRefreshLoop()

        Task {
            await self.bootstrap()
        }
    }

    deinit {
        refreshLoopTask?.cancel()
    }

    // Refreshes the bridge snapshot plus npm update metadata so the menu bar is the new control surface.
    func refresh(showSpinner: Bool = false) async {
        do {
            _ = try await performRefresh(
                showSpinner: showSpinner,
                clearSnapshotOnFailure: false
            )
        } catch {
            // Passive refreshes keep the last known snapshot so brief shell hiccups do not blank the menu bar.
        }
    }

    func saveRelayOverride(_ value: String) {
        relayOverride = value.trimmingCharacters(in: .whitespacesAndNewlines)
        UserDefaults.standard.set(relayOverride, forKey: Self.relayOverrideKey)
        Task {
            await self.refresh(showSpinner: true)
        }
    }

    func clearRelayOverride() {
        relayOverride = ""
        UserDefaults.standard.removeObject(forKey: Self.relayOverrideKey)
        Task {
            await self.refresh(showSpinner: true)
        }
    }

    func saveLocalRelaySettings(hostname: String, bindHost: String, port: String) {
        localRelayHostname = hostname.trimmingCharacters(in: .whitespacesAndNewlines)
        localRelayBindHost = bindHost.trimmingCharacters(in: .whitespacesAndNewlines)
        localRelayPort = port.trimmingCharacters(in: .whitespacesAndNewlines)

        UserDefaults.standard.set(localRelayHostname, forKey: Self.localRelayHostnameKey)
        UserDefaults.standard.set(localRelayBindHost, forKey: Self.localRelayBindHostKey)
        UserDefaults.standard.set(localRelayPort, forKey: Self.localRelayPortKey)
    }

    func startBridge() {
        let previousPairingDate = snapshot?.pairingSession?.createdDate
        runAction(successMessage: "Bridge avviato.") {
            try await self.requireCLIAvailability()
            try await self.service.startBridge(relayOverride: self.effectiveRelayOverride)
            try await self.waitForFreshPairing(after: previousPairingDate)
        }
    }

    func stopBridge() {
        runAction(successMessage: "Bridge fermato.") {
            try await self.requireCLIAvailability()
            try await self.service.stopBridge(relayOverride: self.effectiveRelayOverride)
            try await self.refreshAfterAction()
        }
    }

    func startLocalRelay() {
        runAction(successMessage: "Local relay started.") {
            try self.validateLocalRelaySettings()
            let relayURL = try await self.service.startLocalRelay(
                hostnameOverride: self.localRelayHostname,
                bindHostOverride: self.localRelayBindHost,
                portOverride: self.validatedLocalRelayPort
            )
            self.localRelayURL = relayURL
            self.relayOverride = relayURL
            UserDefaults.standard.set(relayURL, forKey: Self.relayOverrideKey)
            try await self.refreshAfterAction()
        }
    }

    func stopLocalRelay() {
        runAction(successMessage: "Local relay stopped.") {
            self.service.stopLocalRelay()
            self.localRelayURL = nil
            try? await self.service.stopBridge(relayOverride: self.effectiveRelayOverride)
            try await self.refreshAfterAction()
        }
    }

    func quitApp() {
        guard !isPerformingAction else {
            return
        }

        isPerformingAction = true
        transientMessage = ""
        errorMessage = ""

        Task {
            defer {
                self.isPerformingAction = false
            }

            try? await self.service.stopBridge(relayOverride: self.effectiveRelayOverride)
            self.service.stopLocalRelay()
            self.localRelayURL = nil
            NSApplication.shared.terminate(nil)
        }
    }

    func resumeLastThread() {
        runAction(successMessage: "Ultimo thread riaperto in Codex.") {
            try await self.requireCLIAvailability()
            try await self.service.resumeLastThread(relayOverride: self.effectiveRelayOverride)
            try await self.refreshAfterAction()
        }
    }

    func resetPairing() {
        runAction(successMessage: "Pairing resettato.") {
            try await self.requireCLIAvailability()
            try await self.service.resetPairing(relayOverride: self.effectiveRelayOverride)
            try await self.refreshAfterAction()
        }
    }

    func updateBridgePackage() {
        runAction(successMessage: "Bridge aggiornato all’ultima release.") {
            try await self.requireCLIAvailability()
            try await self.service.updateBridgePackage()
            if self.snapshot?.launchdLoaded == true {
                try await self.service.startBridge(relayOverride: self.effectiveRelayOverride)
            }
            try await self.refreshAfterAction()
        }
    }

    func retryCLISetup() {
        Task {
            await self.refresh(showSpinner: true)
        }
    }

    func openLogsFolder() {
        let path = snapshot?.stateDirectoryPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let targetPath = (path?.isEmpty == false) ? path! : "\(NSHomeDirectory())/.remodex"
        NSWorkspace.shared.open(URL(fileURLWithPath: targetPath))
    }

    func openStdoutLog() {
        guard let snapshot else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: snapshot.stdoutLogPath))
    }

    func openStderrLog() {
        guard let snapshot else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: snapshot.stderrLogPath))
    }

    private var effectiveRelayOverride: String? {
        relayOverride.isEmpty ? nil : relayOverride
    }

    private var validatedLocalRelayPort: Int? {
        let trimmed = localRelayPort.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return 9000
        }

        guard let port = Int(trimmed), (1...65535).contains(port) else {
            return nil
        }

        return port
    }

    private func validateLocalRelaySettings() throws {
        guard validatedLocalRelayPort != nil else {
            throw BridgeControlError.commandFailed(
                command: "run-local-remodex.sh",
                message: "Relay port must be an integer between 1 and 65535."
            )
        }
    }

    var isLocalRelayRunning: Bool {
        service.isLocalRelayRunning
    }

    var isCLIAvailable: Bool {
        cliAvailability.isAvailable
    }

    private func startRefreshLoop() {
        refreshLoopTask = Task { [weak self] in
            guard let self else { return }

            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(480))
                guard !Task.isCancelled else { return }
                await self.refresh(showSpinner: false)
            }
        }
    }

    // Performs the first load in two stages so the UI can show a dedicated "install the CLI" blocker.
    private func bootstrap() async {
        let cliAvailability = await refreshCLIAvailability()
        guard cliAvailability.isAvailable else {
            snapshot = nil
            updateState = .empty
            localRelayURL = service.activeLocalRelayURL
            return
        }

        await refresh(showSpinner: true)
    }

    @discardableResult
    private func refreshCLIAvailability() async -> BridgeCLIAvailability {
        let availability = await service.detectCLIAvailability()
        cliAvailability = availability
        return availability
    }

    private func requireCLIAvailability() async throws {
        switch await refreshCLIAvailability() {
        case .available:
            return
        case .missing:
            throw BridgeMenuBarActionError.missingCLI
        case .broken(let message):
            throw BridgeMenuBarActionError.brokenCLI(message)
        case .checking:
            throw BridgeMenuBarActionError.missingCLI
        }
    }

    private func resolveUpdateState(installedVersion: String) async -> BridgePackageUpdateState {
        let latestVersionResult = await service.fetchLatestPackageVersion()
        switch latestVersionResult {
        case .success(let latestVersion):
            return BridgePackageUpdateState(
                installedVersion: installedVersion,
                latestVersion: latestVersion,
                errorMessage: nil
            )
        case .failure(let error):
            return BridgePackageUpdateState(
                installedVersion: installedVersion,
                latestVersion: nil,
                errorMessage: error.localizedDescription
            )
        }
    }

    // Lets command handlers fail loudly when the follow-up snapshot cannot be trusted.
    private func refreshAfterAction() async throws {
        _ = try await performRefresh(
            showSpinner: false,
            clearSnapshotOnFailure: true
        )
    }

    @discardableResult
    private func performRefresh(
        showSpinner: Bool,
        clearSnapshotOnFailure: Bool
    ) async throws -> BridgeSnapshot? {
        if showSpinner {
            isRefreshing = true
        }

        defer {
            isRefreshing = false
        }

        let cliAvailability = await refreshCLIAvailability()
        guard cliAvailability.isAvailable else {
            snapshot = nil
            updateState = .empty
            transientMessage = ""
            errorMessage = ""
            return nil
        }

        do {
            let snapshot = try await service.loadSnapshot(relayOverride: effectiveRelayOverride)
            self.snapshot = snapshot
            self.localRelayURL = service.activeLocalRelayURL
            self.errorMessage = ""
            self.updateState = await resolveUpdateState(installedVersion: snapshot.currentVersion)
            return snapshot
        } catch {
            if clearSnapshotOnFailure {
                snapshot = nil
                updateState = .empty
            }
            localRelayURL = service.activeLocalRelayURL
            errorMessage = error.localizedDescription
            throw error
        }
    }

    // Treats a missing fresh QR as a real start failure so the menu bar never reports a false success.
    private func waitForFreshPairing(after previousPairingDate: Date?) async throws {
        for _ in 0..<20 {
            do {
                let nextSnapshot = try await service.loadSnapshot(relayOverride: effectiveRelayOverride)
                let nextPairingDate = nextSnapshot.pairingSession?.createdDate
                self.snapshot = nextSnapshot
                self.updateState = await resolveUpdateState(installedVersion: nextSnapshot.currentVersion)
                if previousPairingDate == nil {
                    if nextSnapshot.pairingSession?.pairingPayload != nil {
                        return
                    }
                } else if let nextPairingDate,
                          let previousPairingDate,
                          nextPairingDate > previousPairingDate {
                    return
                }
            } catch {
                self.errorMessage = error.localizedDescription
            }

            try? await Task.sleep(for: .milliseconds(500))
        }

        throw BridgeMenuBarActionError.pairingTimeout
    }

    private func runAction(
        successMessage: String,
        operation: @escaping @MainActor () async throws -> Void
    ) {
        guard !isPerformingAction else {
            return
        }

        isPerformingAction = true
        transientMessage = ""
        errorMessage = ""

        Task {
            defer {
                self.isPerformingAction = false
            }

            do {
                try await operation()
                self.transientMessage = successMessage
            } catch {
                self.errorMessage = error.localizedDescription
            }
        }
    }
}
