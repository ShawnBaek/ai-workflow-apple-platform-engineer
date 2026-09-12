import Foundation
import FoundationModels

@Generable
struct LookupArguments {
    @Guide(description: "Number of results", .range(1...3))
    var limit: Int

    init(limit: Int) { self.limit = limit }
}

@Generable
struct GuidedVerdict {
    @Guide(description: "One of the accepted labels", .anyOf(["pass", "fail"]))
    var verdict: String
    @Guide(description: "Bounded confidence", .range(1...3))
    var confidence: Int
}

actor ToolRecorder {
    private(set) var calls = 0
    func record() { calls += 1 }
}

struct BoundedLookupTool: Tool {
    let name = "bounded_lookup"
    let description = "Returns at most three fixed local audit values."
    let recorder: ToolRecorder

    func call(arguments: LookupArguments) async throws -> String {
        guard (1...3).contains(arguments.limit) else {
            throw NSError(domain: "Audit", code: 1, userInfo: [NSLocalizedDescriptionKey: "limit out of bounds"])
        }
        await recorder.record()
        return ["alpha", "beta", "gamma"].prefix(arguments.limit).joined(separator: ",")
    }
}

@main
struct FoundationModelsAudit {
    static func main() async throws {
        let model = SystemLanguageModel.default
        print("foundation_models_availability=\(String(describing: model.availability)) locale_supported=\(model.supportsLocale(Locale.current))")

        let recorder = ToolRecorder()
        let tool = BoundedLookupTool(recorder: recorder)
        let schemaDescription = String(reflecting: GuidedVerdict.generationSchema)
        let direct = try await tool.call(arguments: LookupArguments(limit: 2))
        var outOfBoundsRejected = false
        do { _ = try await tool.call(arguments: LookupArguments(limit: 4)) }
        catch { outOfBoundsRejected = true }
        let directCalls = await recorder.calls
        guard direct == "alpha,beta" else {
            throw NSError(domain: "Audit", code: 2, userInfo: [NSLocalizedDescriptionKey: "bounded lookup returned unexpected values"])
        }
        guard directCalls == 1 else {
            throw NSError(domain: "Audit", code: 3, userInfo: [NSLocalizedDescriptionKey: "direct lookup call count differed"])
        }
        guard outOfBoundsRejected else {
            throw NSError(domain: "Audit", code: 4, userInfo: [NSLocalizedDescriptionKey: "out-of-range lookup was accepted"])
        }
        print("guided_schema=constructed description_chars=\(schemaDescription.count)")
        print("typed_tool_direct=\(direct) direct_calls=\(directCalls) out_of_bounds_rejected=\(outOfBoundsRejected)")

        guard model.isAvailable, model.supportsLocale(Locale.current) else {
            print("guided_generation=blocked model_unavailable")
            print("model_tool_call=blocked model_unavailable model_selected_calls=0")
            return
        }

        let guidedSession = LanguageModelSession(model: model, instructions: "Return only the requested structured assessment.")
        let guided = try await guidedSession.respond(to: "Classify this deterministic statement as pass: 2 + 2 equals 4.", generating: GuidedVerdict.self)
        print("guided_generation=ran verdict=\(guided.content.verdict) confidence=\(guided.content.confidence)")

        let toolSession = LanguageModelSession(model: model, tools: [tool], instructions: "Always call bounded_lookup exactly once with limit 1, then report its value.")
        let response = try await toolSession.respond(to: "Use the tool now.")
        let totalCalls = await recorder.calls
        let modelSelectedCalls = totalCalls - directCalls
        guard modelSelectedCalls == 1 else {
            throw NSError(domain: "Audit", code: 5, userInfo: [NSLocalizedDescriptionKey: "model-selected tool call count differed"])
        }
        print("model_tool_call=ran model_selected_calls=\(modelSelectedCalls) total_calls=\(totalCalls) response_chars=\(response.content.count)")
    }
}
