// Retentativa com backoff exponencial + jitter e circuit breaker por tela.

public struct RetryPolicy: Sendable, Equatable {
    public var maxRetries: Int
    public var base: Duration
    public var maxDelay: Duration
    public var jitter: Duration

    public init(maxRetries: Int, base: Duration, maxDelay: Duration, jitter: Duration) {
        self.maxRetries = maxRetries
        self.base = base
        self.maxDelay = maxDelay
        self.jitter = jitter
    }

    /// 3 tentativas: a terceira falha seguida já abre o circuit breaker, então não há por que insistir.
    public static let ddc = RetryPolicy(maxRetries: 2, base: .milliseconds(50), maxDelay: .seconds(1), jitter: .milliseconds(25))

    /// Δt = min(Tmax, base·2^retry + uniform(0, jitter))
    public func delay(forRetry retry: Int, using rng: inout some RandomNumberGenerator) -> Duration {
        let exponential = base.timeInterval * pow2(max(0, retry))
        let noise = Double.random(in: 0...max(0, jitter.timeInterval), using: &rng)
        return .seconds(min(maxDelay.timeInterval, exponential + noise))
    }

    public func delay(forRetry retry: Int) -> Duration {
        var rng = SystemRandomNumberGenerator()
        return delay(forRetry: retry, using: &rng)
    }

    private func pow2(_ n: Int) -> Double {
        n >= 1023 ? .infinity : Double(sign: .plus, exponent: n, significand: 1)
    }
}

public struct CircuitBreaker: Sendable, Equatable {
    public enum State: Sendable, Equatable {
        case closed(failures: Int)
        case open(until: ContinuousClock.Instant)
        /// Isolamento vencido: uma única tentativa de sonda decide se fecha ou reabre.
        case halfOpen
    }

    public let threshold: Int
    public let cooldown: Duration
    public private(set) var state: State = .closed(failures: 0)

    public init(threshold: Int = 3, cooldown: Duration = .seconds(30)) {
        self.threshold = threshold
        self.cooldown = cooldown
    }

    public mutating func allowsRequest(at now: ContinuousClock.Instant) -> Bool {
        switch state {
        case .closed:
            return true
        case .open(let until):
            guard now >= until else { return false }
            state = .halfOpen
            return true
        case .halfOpen:
            return false
        }
    }

    public mutating func recordSuccess() {
        state = .closed(failures: 0)
    }

    public mutating func recordFailure(at now: ContinuousClock.Instant) {
        if case .closed(let failures) = state, failures + 1 < threshold {
            state = .closed(failures: failures + 1)
        } else {
            state = .open(until: now + cooldown)
        }
    }

    public func retryAfter(at now: ContinuousClock.Instant) -> Duration {
        if case .open(let until) = state, until > now { return now.duration(to: until) }
        return .zero
    }

    public var isOpen: Bool {
        if case .open = state { return true }
        return false
    }
}

extension Duration {
    public var timeInterval: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
