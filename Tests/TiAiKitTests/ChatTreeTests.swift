import Foundation
import Testing
@testable import TiAiKit

private func node(_ id: String, parent: String?, children: [String] = []) -> ChatMessage {
    var obj: [String: Any] = ["id": id, "role": "user", "content": "x", "childrenIds": children]
    if let parent { obj["parentId"] = parent }
    return try! JSONDecoder().decode(
        ChatMessage.self, from: try! JSONSerialization.data(withJSONObject: obj))
}

private func tree(_ nodes: [ChatMessage]) -> [String: ChatMessage] {
    Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
}

@Test("a regenerated question has two answers and the walk follows the newest")
func leafFollowsTheNewestBranch() {
    // u1 -> a1 (first answer) and u1 -> a2 (regenerated), a2 -> a3 (follow-up)
    let messages = tree([
        node("u1", parent: nil, children: ["a1", "a2"]),
        node("a1", parent: "u1"),
        node("a2", parent: "u1", children: ["a3"]),
        node("a3", parent: "a2"),
    ])
    #expect(ChatTree.leaf(below: "u1", in: messages) == "a3")
}

@Test("a message that lists itself as its child does not hang the walk")
func selfParentedMessageDoesNotLoop() {
    #expect(ChatTree.leaf(below: "u1", in: tree([node("u1", parent: nil, children: ["u1"])])) == "u1")
}

@Test("walking back up finds the branch on screen, not its sibling")
func branchChildPicksTheLiveBranch() {
    let messages = tree([
        node("u1", parent: nil, children: ["a1", "a2"]),
        node("a1", parent: "u1"),
        node("a2", parent: "u1", children: ["a3"]),
        node("a3", parent: "a2"),
    ])
    #expect(ChatTree.branchChild(of: "u1", leaf: "a3", in: messages) == "a2")
    #expect(ChatTree.branchChild(of: "u1", leaf: "a1", in: messages) == "a1")
    #expect(ChatTree.branchChild(of: "a3", leaf: "a3", in: messages) == nil)
}

@Test("the pager counts siblings and names the current one")
func positionCountsSiblings() {
    let messages = tree([
        node("u1", parent: nil, children: ["a1", "a2", "a3"]),
        node("a2", parent: "u1"),
    ])
    let position = ChatTree.position(of: "a2", in: messages)
    #expect(position?.index == 1)
    #expect(position?.total == 3)
    #expect(ChatTree.position(of: "u1", in: messages) == nil)
}

@Test("a run that stops growing is given up on, a run that grows is not")
func growthIsTheSignal() {
    var watch = RunWatch(stallLimit: 3)
    var dead = watch.observe(size: 10); #expect(!dead)
    dead = watch.observe(size: 10); #expect(!dead)
    dead = watch.observe(size: 11); #expect(!dead)   // moving again, counter resets
    dead = watch.observe(size: 11); #expect(!dead)
    dead = watch.observe(size: 11); #expect(!dead)
    dead = watch.observe(size: 11); #expect(dead)    // three polls with nothing new
}

@Test("a reading smaller than the last is a race, not a stall")
func shrinkingReadingsAreIgnored() {
    var watch = RunWatch(stallLimit: 2)
    var dead = watch.observe(size: 100); #expect(!dead)
    dead = watch.observe(size: 40); #expect(!dead)   // a refetch that lost the race
    dead = watch.observe(size: 100); #expect(!dead)
    dead = watch.observe(size: 100); #expect(dead)
}
