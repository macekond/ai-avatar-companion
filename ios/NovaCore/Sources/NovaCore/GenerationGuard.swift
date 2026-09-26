import Foundation

/// Guards against a fire-and-forget async task (memory extraction, a
/// background save) applying its result after the state it was computed
/// against has moved on — e.g. a profile hot-swap. Port of the
/// object-identity check in `app/server.py`'s `_apply_extracted_memory` and
/// the same class of problem `MemoryManager`'s delete-tombstone guards
/// against; both are "don't let async work outlive its validity window."
public final class GenerationGuard {
    public struct Token: Equatable {
        fileprivate let value: Int
    }

    private var generation = 0

    public init() {}

    /// Capture a token representing "now" before starting async work.
    public func currentToken() -> Token {
        Token(value: generation)
    }

    /// Call when state moves on (e.g. a profile switch) — invalidates every
    /// token captured before this point.
    public func advance() {
        generation += 1
    }

    public func isCurrent(_ token: Token) -> Bool {
        token.value == generation
    }

    /// Run `action` only if `token` is still current; otherwise a silent no-op.
    public func apply(_ token: Token, _ action: () -> Void) {
        guard isCurrent(token) else { return }
        action()
    }
}
