import Testing
@testable import HetzCore

@Suite struct BackoffTests {
    let policy = RetryPolicy(maxRetries: 5, base: .milliseconds(50), maxDelay: .seconds(1), jitter: .milliseconds(25))

    @Test func staysWithinFormulaBounds() {
        var rng = SystemRandomNumberGenerator()
        for retry in 0..<16 {
            let exponential = 0.05 * Double(1 << retry)
            let lower = min(1.0, exponential), upper = min(1.0, exponential + 0.025)
            for _ in 0..<500 {
                let delay = policy.delay(forRetry: retry, using: &rng).timeInterval
                #expect(delay >= lower - 1e-9 && delay <= upper + 1e-9, "retry \(retry): \(delay) fora de [\(lower), \(upper)]")
            }
        }
    }

    @Test func jitterSpansZeroToMax() {
        // 4000 amostras uniformes em [0, 25 ms]: chegar a 1 ms das pontas é praticamente certo.
        let samples = (0..<4000).map { _ in policy.delay(forRetry: 1).timeInterval }
        #expect(abs(samples.min()! - 0.100) < 0.001)
        #expect(abs(samples.max()! - 0.125) < 0.001)
    }

    @Test func neverExceedsCapEvenForHugeRetries() {
        for retry in [5, 63, 1022, 1023, 5000, Int.max] {
            #expect(policy.delay(forRetry: retry) <= policy.maxDelay)
        }
    }

    @Test func negativeRetryCountsAsFirst() {
        let noJitter = RetryPolicy(maxRetries: 3, base: .milliseconds(50), maxDelay: .seconds(1), jitter: .zero)
        #expect(abs(noJitter.delay(forRetry: -3).timeInterval - 0.050) < 1e-9)
    }

    @Test func zeroJitterIsDeterministic() {
        let exact = RetryPolicy(maxRetries: 3, base: .milliseconds(10), maxDelay: .seconds(1), jitter: .zero)
        #expect(abs(exact.delay(forRetry: 3).timeInterval - 0.080) < 1e-9)
    }
}

@Suite struct CircuitBreakerTests {
    let t0 = ContinuousClock.now

    @Test func opensOnThirdConsecutiveFailure() {
        var breaker = CircuitBreaker()
        breaker.recordFailure(at: t0)
        breaker.recordFailure(at: t0)
        #expect(breaker.state == .closed(failures: 2))
        let allowed1 = breaker.allowsRequest(at: t0)
        #expect(allowed1)
        breaker.recordFailure(at: t0)
        #expect(breaker.state == .open(until: t0 + .seconds(30)))
        let allowed2 = breaker.allowsRequest(at: t0 + .seconds(29))
        #expect(!allowed2)
        #expect(breaker.retryAfter(at: t0 + .seconds(29)) == .seconds(1))
    }

    @Test func successResetsTheCount() {
        var breaker = CircuitBreaker()
        breaker.recordFailure(at: t0)
        breaker.recordFailure(at: t0)
        breaker.recordSuccess()
        breaker.recordFailure(at: t0)
        breaker.recordFailure(at: t0)
        #expect(breaker.state == .closed(failures: 2))
    }

    @Test func halfOpenAllowsSingleProbeAfterCooldown() {
        var breaker = tripped()
        let allowed3 = breaker.allowsRequest(at: t0 + .seconds(30))
        #expect(allowed3)
        #expect(breaker.state == .halfOpen)
        let allowed4 = breaker.allowsRequest(at: t0 + .seconds(30))
        #expect(!allowed4)
    }

    @Test func probeSuccessCloses() {
        var breaker = tripped()
        _ = breaker.allowsRequest(at: t0 + .seconds(31))
        breaker.recordSuccess()
        #expect(breaker.state == .closed(failures: 0))
        let allowed5 = breaker.allowsRequest(at: t0 + .seconds(31))
        #expect(allowed5)
    }

    @Test func probeFailureReopensForAnotherCooldown() {
        var breaker = tripped()
        let probe = t0 + .seconds(31)
        _ = breaker.allowsRequest(at: probe)
        breaker.recordFailure(at: probe)
        #expect(breaker.state == .open(until: probe + .seconds(30)))
        let allowed6 = breaker.allowsRequest(at: probe + .seconds(29))
        #expect(!allowed6)
    }

    private func tripped() -> CircuitBreaker {
        var breaker = CircuitBreaker()
        for _ in 0..<3 { breaker.recordFailure(at: t0) }
        return breaker
    }
}
