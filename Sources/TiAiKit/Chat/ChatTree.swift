import Foundation

/// Walking the message tree, kept apart from the model so it can be tested
/// without a chat, a client or a run.
///
/// The server stores a chat as a flat dictionary of messages, each naming its
/// parent and its children. Everything the app shows — the branch you are on, the
/// "3 of 4" pager, where a new answer attaches — is a walk over that structure.
public enum ChatTree {
    /// The last message below `id`, following the newest child at each step.
    ///
    /// The server lists at least one message as its own child, so the walk
    /// refuses to revisit anything it has already stood on.
    public static func leaf(below id: String, in messages: [String: ChatMessage]) -> String {
        var cursor = id
        var seen: Set<String> = [id]
        while let node = messages[cursor],
            let next = node.childrenIDs.last(where: { !seen.contains($0) }) {
            seen.insert(next)
            cursor = next
        }
        return cursor
    }

    /// The child of `messageID` that leads to `leaf` — the message the branch
    /// you are looking at ends on. Walking up from the leaf is the only way to
    /// find it: a regenerated user message has several children and only one of
    /// them is the branch on screen.
    public static func branchChild(of messageID: String, leaf: String,
                                   in messages: [String: ChatMessage]) -> String? {
        var id = leaf
        // A cycle would hang the app, and the server has been known to point a
        // message at itself. Fifty hops is far more tree than any chat here.
        for _ in 0..<500 {
            guard let node = messages[id], let parent = node.parentID else { return nil }
            if parent == messageID { return id }
            id = parent
        }
        return nil
    }

    /// Sibling order for the pager: the position of `id` among its parent's
    /// children, and how many there are.
    public static func position(of id: String, in messages: [String: ChatMessage]) -> (index: Int, total: Int)? {
        guard let node = messages[id], let parent = node.parentID,
              let siblings = messages[parent]?.childrenIDs,
              let at = siblings.firstIndex(of: id)
        else { return nil }
        return (at, siblings.count)
    }
}

/// Deciding whether a run that stopped talking is still running.
///
/// A chat abandoned server-side — browser closed mid-run, worker died — keeps
/// `done: false` forever. Polling that until the budget runs out shows a spinner
/// on a dead chat, which is its own bug. So *growth* is the signal: if neither
/// the answer nor the reasoning has moved in half a minute, nothing is coming.
public struct RunWatch {
    /// How many consecutive polls may show no growth before the run is given up
    /// on.
    public var stallLimit: Int
    private var largest = 0
    private var stalled = 0

    public init(stallLimit: Int) {
        self.stallLimit = stallLimit
    }

    /// Report the size of the answer so far; returns whether the run looks dead.
    ///
    /// Sizes only ever grow, so a smaller reading is a refetch racing a save and
    /// is ignored rather than counted as a stall.
    public mutating func observe(size: Int) -> Bool {
        if size > largest {
            largest = size
            stalled = 0
            return false
        }
        // Smaller than the last reading means a refetch that lost a race with a
        // save. It says nothing about whether the run is alive, so it must not be
        // counted as a stall.
        if size < largest { return false }
        stalled += 1
        return stalled >= stallLimit
    }
}
