import Foundation

/// Rejects reference-reconstruction plans that describe important visual material but never create it.
/// This is provider-neutral so Codex and Claude receive the same correction.
nonisolated enum AIReferencePlanGuard {
    private static let reconstructionCues = [
        "rebuild", "recreate", "replicate", "imitate", "mimic", "similar", "match this", "reference image",
        "还原", "复刻", "模仿", "仿照", "类似", "相似", "同款", "参考图"
    ]
    private static let rasterCues = [
        "photo", "image", "screenshot", "logo", "product", "illustration", "texture", "collage", "landscape",
        "照片", "图片", "图像", "截图", "标志", "产品", "插画", "纹理", "拼贴", "山景", "云朵"
    ]
    private static let pathCues = [
        "arrow", "crown", "underline", "doodle", "hand-drawn", "scribble", "stroke",
        "箭头", "皇冠", "下划线", "涂鸦", "手绘", "线条"
    ]

    static func revisionReason(for plan: AIEditorPlan, userText: String) -> String? {
        let request = userText.lowercased()
        guard reconstructionCues.contains(where: request.contains) else { return nil }

        let strategy = ([plan.referenceAnalysis?.summary, plan.referenceAnalysis?.visualStyle]
            .compactMap { $0 } + (plan.referenceAnalysis?.composition ?? []) +
            (plan.referenceAnalysis?.layerStrategy ?? [])).joined(separator: " ").lowercased()
        let types = Set(plan.actions.map(\.type))
        let hasRasterAction = !types.isDisjoint(with: ["extract_reference_region", "generate_image"])
        let hasPathAction = types.contains("add_path") || types.contains("add_torn_paper")
        var issues: [String] = []

        if rasterCues.contains(where: strategy.contains), !hasRasterAction {
            issues.append("the analysis names raster artwork, screenshots, or imagery but the actions never place it")
        }
        if pathCues.contains(where: strategy.contains), !hasPathAction {
            issues.append("the analysis names hand-drawn or line artwork but the actions never create an editable path")
        }
        let editableTextCount = plan.actions.filter { ["add_text", "edit_text"].contains($0.type) }.count
        let hasVisualReconstruction = hasRasterAction || hasPathAction || types.contains("add_shape")
        if editableTextCount >= 3, !hasVisualReconstruction {
            issues.append("the result is typography-only even though this is a visual reconstruction request")
        }
        return issues.isEmpty ? nil : issues.joined(separator: "; ")
    }

    static func revisionPrompt(originalPrompt: String, rejectedPlan: AIEditorPlan, reason: String) -> String {
        let actionTypes = rejectedPlan.actions.map(\.type).joined(separator: ", ")
        return originalPrompt + """


        IMPORTANT — the previous plan was rejected by Compositor's reference-fidelity guard.
        Reason: \(reason).
        Previous action types: \(actionTypes).

        Return a complete replacement plan. Convert every prominent non-text region from the reference analysis into an
        actual action. For exact supplied screenshots, logos, product images, or collage pieces, use
        extract_reference_region with measured source pixel rectangles and individual target frames. Do not extract the
        whole poster as one flattened layer. For paper strips use add_torn_paper; for arrows, crowns, underlines, and
        doodles, use add_path. Use generate_image
        only for genuinely missing pixels that cannot be extracted from the supplied reference. Keep all typography as
        native editable text. A reference reconstruction may not be a text-and-background-only plan when the reference
        visibly contains other major elements.
        """
    }
}
