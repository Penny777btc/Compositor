import CoreGraphics
import Foundation

/// Applies trustworthy local measurements after the model has chosen semantic layers.
/// It only adjusts text whose content matches OCR, so requests that intentionally replace copy keep the model's layout.
nonisolated enum AIReferencePlanRefiner {
    static func refine(_ plan: AIEditorPlan, analysis: AIReferenceLocalAnalysis,
                       existingCanvas: CGSize?, strategy: AIReferenceStrategy) -> AIEditorPlan {
        guard strategy != .editable else { return plan }
        let canvasWidth = plan.actions.first(where: { $0.type == "create_canvas" })?.width
            ?? existingCanvas.map { Double($0.width) }
        let canvasHeight = plan.actions.first(where: { $0.type == "create_canvas" })?.height
            ?? existingCanvas.map { Double($0.height) }
        guard let canvasWidth, let canvasHeight, canvasWidth > 0, canvasHeight > 0 else { return plan }
        let scaleX = canvasWidth / Double(analysis.width), scaleY = canvasHeight / Double(analysis.height)
        var actions = plan.actions
        for index in actions.indices where actions[index].type == "add_text" {
            guard let text = actions[index].text,
                  let observation = bestObservation(for: text, in: analysis.texts) else { continue }
            let frame = observation.frame
            let targetHeight = max(1, Double(frame.height) * scaleY * 1.18)
            actions[index].x = Double(frame.minX) * scaleX
            actions[index].y = max(0, Double(frame.minY) * scaleY - targetHeight * 0.08)
            actions[index].width = max(1, Double(frame.width) * scaleX * 1.04)
            actions[index].height = targetHeight
            actions[index].fitText = true
            if actions[index].tracking == nil { actions[index].tracking = 0 }
            if actions[index].fontWeight == nil {
                let relativeHeight = Double(frame.height) / Double(analysis.height)
                actions[index].fontWeight = relativeHeight >= 0.055 ? "black"
                    : relativeHeight >= 0.03 ? "bold" : "regular"
            }
        }
        return AIEditorPlan(message: plan.message, referenceAnalysis: plan.referenceAnalysis, actions: actions)
    }

    private static func bestObservation(for text: String,
                                        in observations: [AIReferenceTextObservation]) -> AIReferenceTextObservation? {
        let target = normalized(text)
        guard target.count >= 2 else { return nil }
        return observations.compactMap { observation -> (AIReferenceTextObservation, Double)? in
            let candidate = normalized(observation.text)
            guard candidate.count >= 2 else { return nil }
            let score: Double
            if candidate == target { score = 1 }
            else if candidate.contains(target) || target.contains(candidate) {
                score = Double(min(candidate.count, target.count)) / Double(max(candidate.count, target.count))
            } else { return nil }
            guard score >= 0.72 else { return nil }
            return (observation, score)
        }.max { left, right in
            if left.1 != right.1 { return left.1 < right.1 }
            return left.0.confidence < right.0.confidence
        }?.0
    }

    private static func normalized(_ value: String) -> String {
        value.lowercased().unicodeScalars.filter(CharacterSet.alphanumerics.contains).map(String.init).joined()
    }
}
