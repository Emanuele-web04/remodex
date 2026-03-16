// FILE: LocalNetworkAuthorization.swift
// Purpose: Triggers and observes iOS local-network privacy access before LAN relay pairing.
// Layer: Service support
// Exports: LocalNetworkAuthorizationRequester, LocalNetworkAuthorizationStatus
// Depends on: Foundation, Network

import Foundation
import Network

private let dnsServicePolicyDeniedRawValue: Int32 = -65570

enum LocalNetworkAuthorizationStatus: Equatable {
    case unknown
    case granted
    case denied
}

@MainActor
final class LocalNetworkAuthorizationRequester: NSObject, NetServiceDelegate {
    private let serviceType = "_remodex-permission._tcp"
    private let serviceName = "RemodexLocalNetwork"

    private var browser: NWBrowser?
    private var netService: NetService?
    private var continuation: CheckedContinuation<LocalNetworkAuthorizationStatus, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var finished = false

    // Uses a Bonjour browse/publish round-trip so iOS shows the local-network prompt
    // before we attempt the real LAN websocket to the relay.
    func request(timeoutNanoseconds: UInt64 = 8_000_000_000) async -> LocalNetworkAuthorizationStatus {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            start()

            timeoutTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                self?.finish(.unknown)
            }
        }
    }

    nonisolated func netServiceDidPublish(_ sender: NetService) {
        Task { @MainActor [weak self] in
            self?.finish(.granted)
        }
    }

    nonisolated func netService(_ sender: NetService, didNotPublish errorDict: [String : NSNumber]) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            if isPolicyDenied(errorDict) {
                finish(.denied)
            } else {
                finish(.unknown)
            }
        }
    }
}

private extension LocalNetworkAuthorizationRequester {
    func start() {
        let parameters = NWParameters()
        parameters.includePeerToPeer = true

        let browser = NWBrowser(
            for: .bonjour(type: serviceType, domain: nil),
            using: parameters
        )
        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch state {
                case .ready:
                    finish(.granted)
                case .waiting(let error), .failed(let error):
                    if isPolicyDenied(error) {
                        finish(.denied)
                    }
                default:
                    break
                }
            }
        }
        browser.browseResultsChangedHandler = { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.finish(.granted)
            }
        }
        self.browser = browser
        browser.start(queue: .main)

        let netService = NetService(
            domain: "local.",
            type: "\(serviceType).",
            name: serviceName,
            port: 9
        )
        netService.delegate = self
        self.netService = netService
        netService.publish()
    }

    func finish(_ status: LocalNetworkAuthorizationStatus) {
        guard !finished else {
            return
        }
        finished = true
        timeoutTask?.cancel()
        timeoutTask = nil
        browser?.cancel()
        browser = nil
        netService?.stop()
        netService = nil
        continuation?.resume(returning: status)
        continuation = nil
    }

    func isPolicyDenied(_ error: NWError) -> Bool {
        guard case .dns(let dnsError) = error else {
            return false
        }
        return dnsError == dnsServicePolicyDeniedRawValue
    }

    func isPolicyDenied(_ errorDict: [String: NSNumber]) -> Bool {
        let code = errorDict[NetService.errorCode]?.intValue
        return code == Int(dnsServicePolicyDeniedRawValue)
    }
}
