import Foundation

enum CompoundBrushDiagnosticSeverity: Int, Sendable, Equatable, Comparable {
    case information
    case warning

    static func < (
        lhs: CompoundBrushDiagnosticSeverity,
        rhs: CompoundBrushDiagnosticSeverity
    ) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

struct CompoundBrushDiagnostic: Identifiable, Sendable, Equatable {
    let id: String
    let severity: CompoundBrushDiagnosticSeverity
    let message: String
}

enum CompoundBrushDiagnostics {
    static func evaluate(_ brush: BrushSettings) -> [CompoundBrushDiagnostic] {
        var diagnostics: [CompoundBrushDiagnostic] = []
        let compound = brush.compoundBrush
        let secondary = compound.secondary
        let primarySize = max(brush.size, 1)
        let secondarySize = secondary.resolvedBaseSize(for: primarySize)
        let relativeSize = secondarySize / primarySize

        if compound.enabled == false {
            diagnostics.append(.init(
                id: "disabled",
                severity: .information,
                message: "组合笔刷尚未启用，结果通道只会显示 A。"
            ))
        }

        if secondary.spacingPercent >= 140 {
            diagnostics.append(.init(
                id: "secondary-spacing-gaps",
                severity: .warning,
                message: "B 间距很大，快速笔迹可能出现明显断裂。"
            ))
        }

        if relativeSize < 0.18 {
            diagnostics.append(.init(
                id: "secondary-too-small",
                severity: .warning,
                message: "B 相对 A 过小，纹理在正常缩放下可能难以辨认。"
            ))
        } else if relativeSize > 3.2 {
            diagnostics.append(.init(
                id: "secondary-too-large",
                severity: .warning,
                message: "B 相对 A 过大，纹理容易退化成整块覆盖。"
            ))
        }

        if brush.spacingPercent <= 7,
           secondary.spacingPercent <= 10,
           max(brush.scatterAmount, brush.jitterAmount) > 0.5 {
            diagnostics.append(.init(
                id: "dense-stamp-load",
                severity: .warning,
                message: "A、B 都处于高密度采样并带有明显散布，长笔迹可能增加渲染负担。"
            ))
        }

        if brush.pressureOpacityAmount >= 0.8,
           compound.globalPressureOpacityAmount >= 0.8 {
            diagnostics.append(.init(
                id: "stacked-opacity-pressure",
                severity: .information,
                message: "A 与整体透明压感同时很强，轻压结果可能比预期更淡。"
            ))
        }

        let mix = compound.pressureMix
        let mixRange = max(
            mix.primaryAtLowPressure,
            mix.primaryAtMidPressure,
            mix.primaryAtHighPressure
        ) - min(
            mix.primaryAtLowPressure,
            mix.primaryAtMidPressure,
            mix.primaryAtHighPressure
        )
        if mixRange < 0.05 {
            diagnostics.append(.init(
                id: "flat-pressure-mix",
                severity: .information,
                message: "轻、中、重压力的 A/B 比例几乎相同，压感组合不会产生明显迁移。"
            ))
        }

        return diagnostics.sorted { lhs, rhs in
            if lhs.severity != rhs.severity {
                return lhs.severity > rhs.severity
            }
            return lhs.id < rhs.id
        }
    }
}
