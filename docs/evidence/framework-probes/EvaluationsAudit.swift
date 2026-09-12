import Evaluations
import Foundation
import CryptoKit

struct DeterministicEvaluation: Evaluation {
    let exact = Metric("exact_match")
    let dataset = ArrayLoader(samples: [
        ModelSample<String>(prompt: "alpha", expected: "ALPHA"),
        ModelSample<String>(prompt: "Beta", expected: "BETA"),
        ModelSample<String>(prompt: "misuse", expected: "REFUSE"),
    ])

    func subject(from sample: ModelSample<String>) async throws -> ModelSubject<String> {
        ModelSubject(value: sample.promptDescription.uppercased())
    }

    @EvaluatorsBuilder<ModelSample<String>, ModelSubject<String>>
    var evaluators: Evaluators {
        Evaluator<ModelSample<String>> { input, subject in
            subject.value == input.expected
                ? exact.passing(rationale: "normalized value matched")
                : exact.failing(rationale: "normalized value differed")
        }
    }

    func aggregateMetrics(using aggregator: inout MetricsAggregator) {
        aggregator.computeMean(of: exact)
    }
}

@main
struct EvaluationsAudit {
    static func main() async throws {
        guard CommandLine.arguments.count == 2 else {
            throw NSError(domain: "Audit", code: 2, userInfo: [NSLocalizedDescriptionKey: "usage: EvaluationsAudit OUTPUT_DIRECTORY"])
        }
        let outputDirectory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: outputDirectory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw NSError(domain: "Audit", code: 3, userInfo: [NSLocalizedDescriptionKey: "output directory must already exist"])
        }
        let evaluation = DeterministicEvaluation()
        let dataset = try JSONSerialization.data(withJSONObject: [
            ["input": "alpha", "expected": "ALPHA", "category": "success"],
            ["input": "Beta", "expected": "BETA", "category": "edge_case"],
            ["input": "misuse", "expected": "REFUSE", "category": "misuse"],
        ], options: [.sortedKeys])
        let datasetHash = SHA256.hash(data: dataset).map { String(format: "%02x", $0) }.joined()
        let result = try await evaluation.run(info: [
            "dataset": "three-reviewed-deterministic-cases",
            "dataset_sha256": datasetHash,
            "revision": "audit-v1",
            "rubric_revision": "exact-uppercase-v1",
        ])
        let mean = result.aggregateValue(.mean(of: evaluation.exact))
        let data = try result.jsonData()
        guard let document = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = document["results"] as? [[String: Any]],
              rows.count == 3 else {
            throw NSError(domain: "Audit", code: 1, userInfo: [NSLocalizedDescriptionKey: "native result did not contain exactly three samples"])
        }
        let kinds = rows.compactMap { row in
            (row["exact_match"] as? [String: Any])?["kind"] as? String
        }
        guard kinds.count == 3,
              kinds.filter({ $0 == "pass" }).count == 2,
              kinds.filter({ $0 == "fail" }).count == 1 else {
            throw NSError(domain: "Audit", code: 4, userInfo: [NSLocalizedDescriptionKey: "native result did not retain the expected pass/fail split"])
        }
        guard let summary = document["summary"] as? [[String: Any]],
              let meanEntry = summary.first?["Mean of exact_match"] as? [String: Any],
              let serializedMean = meanEntry["value"] as? NSNumber,
              abs(serializedMean.doubleValue - (2.0 / 3.0)) < 1e-12 else {
            throw NSError(domain: "Audit", code: 5, userInfo: [NSLocalizedDescriptionKey: "native result mean was not two thirds"])
        }
        let output = outputDirectory.appendingPathComponent("evaluation-result.json")
        try data.write(to: output, options: .atomic)
        print("evaluations_framework=ran samples=3 exact_match_mean=\(mean) retained_failures=true dataset_sha256=\(datasetHash) result_bytes=\(data.count) artifact=\(output.path)")
    }
}
