import Foundation
import Network

/// Network state as a policy input, not an error source.
///
/// Note the division of labour with the background session: the *system* already waits for
/// connectivity and retries background tasks on its own. This governor exists for the decisions
/// iOS will not make for us — whether an expensive (cellular) or constrained (Low Data Mode)
/// path is acceptable for this particular job's policy.
public actor NetworkGovernor {

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "dev.amphora.network")
    private var current: NetworkStatus
    private var observers: [@Sendable (NetworkStatus) -> Void] = []

    public init(initialStatus: NetworkStatus = .unavailable) {
        current = initialStatus
    }

    public func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            Task { await self?.update(from: path) }
        }
        monitor.start(queue: queue)
    }

    public func stop() { monitor.cancel() }

    public func status() -> NetworkStatus { current }

    public func observe(_ handler: @escaping @Sendable (NetworkStatus) -> Void) {
        observers.append(handler)
    }

    private func update(from path: NWPath) {
        let next: NetworkStatus
        switch path.status {
        case .satisfied:
            // `isExpensive` covers cellular and personal hotspot; `isConstrained` is Low Data Mode.
            // A Wi-Fi → cellular handover flips these without the path ever becoming unsatisfied,
            // so policy must be re-evaluated here and not only on connect/disconnect.
            next = path.isConstrained ? .constrained : (path.isExpensive ? .expensive : .unrestricted)
        default:
            next = .unavailable
        }
        guard next != current else { return }
        current = next
        observers.forEach { $0(next) }
    }

    public func permits(_ policy: UploadPolicy) -> Bool {
        switch current {
        case .unavailable: return false
        case .constrained: return policy.allowsConstrainedNetwork
        case .expensive: return policy.allowsExpensiveNetwork
        case .unrestricted: return true
        }
    }
}

public enum NetworkStatus: Sendable { case unavailable, constrained, expensive, unrestricted }
