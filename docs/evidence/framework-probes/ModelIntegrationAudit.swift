import CoreAI
import CoreML
import Foundation

@main
struct ModelIntegrationAudit {
    static func main() throws {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("missing-\(UUID().uuidString).mlmodelc")
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuOnly
        var missingArtifactRejected = false
        do { _ = try MLModel(contentsOf: missing, configuration: configuration) }
        catch { missingArtifactRejected = true }
        guard missingArtifactRejected else { throw NSError(domain: "Audit", code: 1) }

        if #available(macOS 27.0, iOS 27.0, *) {
            let options = SpecializationOptions.cpuOnly
            print("core_ai_api=available specialization_options=constructed allowed_units=\(options.allowedComputeUnitKinds.count) host_available_units=\(ComputeUnitKind.availableKinds.count)")
        } else {
            print("core_ai_api=blocked os_unavailable")
        }
        print("core_ml_missing_artifact_rejection=passed compute_units=cpuOnly")
        print("inference=blocked no_approved_preconverted_artifact")
    }
}
