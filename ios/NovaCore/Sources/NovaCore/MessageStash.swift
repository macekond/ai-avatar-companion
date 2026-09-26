import Foundation

/// Enforces the "one reader on the socket" invariant (see CLAUDE.md and
/// `_next_raw`/`buffered_msgs` in `app/server.py`): everything reads through
/// a single entry point that drains a FIFO stash before touching the real
/// receiver, so a message set aside by one phase (onboarding, the listening
/// phase, a barge-in watcher) for the main loop is delivered exactly once,
/// in order, and never triggers a real read while stashed messages remain.
///
/// A caller that needs to "put back" a message it read but doesn't own must
/// push it here — never into whatever list a `next()` loop pops from
/// directly, which would re-serve the same message forever (the real bug
/// this class exists to prevent).
public final class MessageStash<Message> {
    private var stash: [Message] = []
    private let receive: () async -> Message

    public init(receive: @escaping () async -> Message) {
        self.receive = receive
    }

    /// Push a message to be delivered on the next `next()` call, ahead of
    /// anything from the underlying receiver.
    public func push(_ message: Message) {
        stash.append(message)
    }

    /// Drain the stash (FIFO) before falling back to the real receiver.
    public func next() async -> Message {
        if !stash.isEmpty {
            return stash.removeFirst()
        }
        return await receive()
    }
}
