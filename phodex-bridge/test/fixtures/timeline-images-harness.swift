import Foundation

// Minimal app-state types; all image parsing and timeline projection use production code.
struct CodexMessage: Identifiable, Equatable {
    enum Role { case user, assistant, system }
    enum Kind { case chat, thinking, toolActivity, fileChange, commandExecution, subagentAction, plan, userInputPrompt, autoApprovalReview, asyncUserInputAnswer }
    struct Review: Equatable { enum Status { case approved, denied }; var status: Status }
    var id: String
    var role: Role = .assistant
    var kind: Kind = .chat
    var assistantPhase: String? = "commentary"
    var text: String
    var turnId: String? = "turn"
    var isStreaming = false
    var asyncUserInput: String? = nil
    var autoApprovalReview: Review? = nil
    var shouldDisplayInlinePlanResult = false
}

enum FileChangeBlockPresentationBuilder {
    struct Presentation { var bodyText: String }
    static func build(from messages: [CodexMessage]) -> Presentation? { nil }
}

@main struct TimelineImageChecks {
    static func main() {
        let caption = "Here is the weather forecast for this week."
        let image = "![Weather](<Cards/weather.png>)"
        let card = CodexMessage(id: "card", text: caption + "\n\n" + image)
        let user = CodexMessage(id: "user", role: .user, assistantPhase: nil, text: "Compare the weather")
        for phase: String? in ["commentary", nil] {
            var candidate = card
            candidate.assistantPhase = phase
            for finalText in ["The two cities have different weather.", caption + " The second city is cooler."] {
                let final = CodexMessage(id: "final", assistantPhase: "final_answer", text: finalText)
                let items = TurnTimelineRenderProjection.project(messages: [user, candidate, final], completedTurnIDs: ["turn"])
                precondition(items.map(\.id) == ["user", "card", "final"], "mixed image card must remain visible")
                guard case .message(let visibleCard) = items[1] else { fatalError("card must keep its item identity") }
                precondition(visibleCard == candidate)
            }
        }
        let finalWithImage = CodexMessage(id: "final", assistantPhase: "final_answer", text: "Final forecast.\n\n" + image)
        let deduplicated = TurnTimelineRenderProjection.project(messages: [user, card, finalWithImage], completedTurnIDs: ["turn"])
        precondition(!deduplicated.contains { $0.id == "card" }, "a preview already in the final answer stays in previous messages")
        let literal = CodexMessage(id: "literal", text: "Example: `" + image + "`")
        let final = CodexMessage(id: "final", assistantPhase: "final_answer", text: "Done.")
        let codeExample = TurnTimelineRenderProjection.project(messages: [user, literal, final], completedTurnIDs: ["turn"])
        precondition(!codeExample.contains { $0.id == "literal" }, "code examples must not become image cards")
        print("timeline image visibility checks passed")
    }
}
