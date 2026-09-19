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
                  let frame = bestFrame(for: text, action: actions[index], in: analysis.texts,
                    scaleX: scaleX, scaleY: scaleY, canvasWidth: canvasWidth, canvasHeight: canvasHeight) else { continue }
            let targetHeight = max(1, Double(frame.height) * scaleY * 1.18)
            actions[index].x = Double(frame.minX) * scaleX
            actions[index].y = max(0, Double(frame.minY) * scaleY - targetHeight * 0.08)
            actions[index].width = max(1, Double(frame.width) * scaleX * 1.04)
            actions[index].height = targetHeight
            actions[index].fitText = true
            actions[index].singleLine = true
            if actions[index].tracking == nil { actions[index].tracking = 0 }
            if actions[index].fontWeight == nil {
                let relativeHeight = Double(frame.height) / Double(analysis.height)
                actions[index].fontWeight = relativeHeight >= 0.055 ? "black"
                    : relativeHeight >= 0.03 ? "bold" : "regular"
            }
        }
        return AIEditorPlan(message: plan.message, referenceAnalysis: plan.referenceAnalysis, actions: actions)
    }

    private static func bestFrame(for text: String, action: AIEditorAction,
                                  in observations: [AIReferenceTextObservation], scaleX: Double, scaleY: Double,
                                  canvasWidth: Double, canvasHeight: Double) -> CGRect? {
        let target = normalized(text)
        guard target.count >= 2 else { return nil }
        return observations.compactMap { observation -> (CGRect, Double)? in
            let candidate = normalized(observation.text)
            guard candidate.count >= 2 else { return nil }
            let textScore: Double
            let frame: CGRect
            if candidate == target {
                textScore = 1
                frame = observation.frame
            } else if let substring = substringFrame(text: text, in: observation.text, frame: observation.frame) {
                textScore = 0.92
                frame = substring
            } else if candidate.contains(target) || target.contains(candidate) {
                textScore = Double(min(candidate.count, target.count)) / Double(max(candidate.count, target.count))
                frame = observation.frame
            } else { return nil }
            guard textScore >= 0.45 else { return nil }
            let spatialPenalty: Double
            if let x = action.x, let y = action.y {
                let expectedX = x + (action.width ?? Double(frame.width) * scaleX) / 2
                let expectedY = y + (action.height ?? Double(frame.height) * scaleY) / 2
                let actualX = Double(frame.midX) * scaleX
                let actualY = Double(frame.midY) * scaleY
                spatialPenalty = min(1, hypot((expectedX - actualX) / canvasWidth,
                                              (expectedY - actualY) / canvasHeight)) * 0.85
            } else { spatialPenalty = 0 }
            return (frame, textScore - spatialPenalty + Double(observation.confidence) * 0.03)
        }.max { left, right in
            left.1 < right.1
        }?.0
    }

    private static func substringFrame(text: String, in candidate: String, frame: CGRect) -> CGRect? {
        let needle = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty, let range = candidate.range(of: needle, options: [.caseInsensitive]) else { return nil }
        let prefix = candidate[..<range.lowerBound], match = candidate[range]
        let total = visualWeight(candidate[...]), start = visualWeight(prefix), width = visualWeight(match)
        guard total > 0, width > 0 else { return nil }
        return CGRect(x: frame.minX + frame.width * CGFloat(start / total), y: frame.minY,
            width: frame.width * CGFloat(width / total), height: frame.height)
    }

    private static func visualWeight(_ value: Substring) -> Double {
        value.reduce(0) { total, character in
            guard let scalar = character.unicodeScalars.first else { return total }
            if CharacterSet.whitespacesAndNewlines.contains(scalar) { return total + 0.32 }
            if scalar.value >= 0x2E80 { return total + 1 }
            if CharacterSet.alphanumerics.contains(scalar) { return total + 0.62 }
            return total + 0.38
        }
    }

    private static func normalized(_ value: String) -> String {
        value.lowercased().unicodeScalars.filter(CharacterSet.alphanumerics.contains).map(String.init).joined()
    }
}
