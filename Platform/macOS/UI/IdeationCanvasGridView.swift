import SwiftUI

struct IdeationCanvasGridView: View {
    @ObservedObject var hostViewModel: WorkspaceViewModel
    @ObservedObject var session: IdeationSessionState

    private let gridSpacing: CGFloat = 14
    private let outerPadding: CGFloat = 18
    private let controlsBarHeight: CGFloat = 54
    private let branchHeaderHeight: CGFloat = 38

    var body: some View {
        GeometryReader { geometry in
            let canvasSize = hostViewModel.workspace.document.canvasSize
            let aspectRatio = CGFloat(canvasSize.width) / max(CGFloat(canvasSize.height), 1)
            let availableWidth = max(geometry.size.width - (outerPadding * 2) - gridSpacing, 100)
            let availableHeight = max(
                geometry.size.height - (outerPadding * 2) - controlsBarHeight - 14,
                100
            )
            let cellWidth = availableWidth / 2
            let cardHeight = max((availableHeight - gridSpacing) / 2, 80)
            let canvasHeightLimit = max(cardHeight - branchHeaderHeight - 8, 40)
            let fittedCellHeight = min(canvasHeightLimit, cellWidth / max(aspectRatio, 0.0001))
            let fittedCellWidth = fittedCellHeight * aspectRatio

            VStack(spacing: 14) {
                controlsBar

                if session.canvasDisplayMode == .focused {
                    focusedBranchCanvas(
                        size: CGSize(
                            width: min(availableWidth, availableHeight * aspectRatio),
                            height: min(availableHeight, availableWidth / max(aspectRatio, 0.0001))
                        )
                    )
                } else {
                    VStack(spacing: gridSpacing) {
                        HStack(spacing: gridSpacing) {
                            branchCard(session.branches[0], size: CGSize(width: fittedCellWidth, height: fittedCellHeight))
                            branchCard(session.branches[1], size: CGSize(width: fittedCellWidth, height: fittedCellHeight))
                        }
                        HStack(spacing: gridSpacing) {
                            branchCard(session.branches[2], size: CGSize(width: fittedCellWidth, height: fittedCellHeight))
                            branchCard(session.branches[3], size: CGSize(width: fittedCellWidth, height: fittedCellHeight))
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
            }
            .padding(outerPadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .background(Color(red: 0.18, green: 0.18, blue: 0.19))
        }
    }

    private var controlsBar: some View {
        HStack(spacing: 10) {
            Picker("推进模式", selection: $session.mode) {
                ForEach(IdeationSessionState.ProgressMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 240)

            Button(session.canvasDisplayMode == .focused ? "返回四宫格" : "临时放大画布") {
                if session.canvasDisplayMode == .focused {
                    session.returnToGridCanvasLayout()
                } else {
                    session.focusSelectedBranchCanvas()
                }
            }
            .buttonStyle(.bordered)

            Spacer(minLength: 8)

            Button("应用于主画布") {
                hostViewModel.applySelectedIdeationVariantToMainCanvas()
            }
            .buttonStyle(.borderedProminent)

            Button("导出四个草图") {
                hostViewModel.exportIdeationVariantsToDisk()
            }
            .buttonStyle(.bordered)

            Button("取消") {
                hostViewModel.cancelIdeationSession()
            }
            .buttonStyle(.bordered)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(height: controlsBarHeight)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.white.opacity(0.08))
        )
    }

    private func branchCard(_ branch: IdeationSessionState.Branch, size: CGSize) -> some View {
        VStack(spacing: 8) {
            Button {
                session.selectBranch(branch.index)
            } label: {
                HStack(spacing: 8) {
                    Text(branch.title)
                        .font(.system(size: 12, weight: .semibold))
                    Spacer(minLength: 8)
                    if session.selectedBranchIndex == branch.index {
                        Text("当前")
                            .font(.system(size: 11, weight: .bold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                Capsule()
                                    .fill(Color.accentColor.opacity(0.22))
                            )
                    }
                }
                .foregroundStyle(Color.white.opacity(0.9))
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(session.selectedBranchIndex == branch.index ? Color.accentColor.opacity(0.18) : Color.white.opacity(0.06))
                )
            }
            .buttonStyle(.plain)
            .frame(height: branchHeaderHeight - 8)

            CanvasContainerView(
                viewModel: branch.viewModel,
                onCanvasInteraction: {
                    session.activateBranch(branch.index, adoptingEditingContext: false)
                }
            )
                .frame(width: size.width, height: size.height)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(
                            session.selectedBranchIndex == branch.index ? Color.accentColor : Color.white.opacity(0.12),
                            lineWidth: session.selectedBranchIndex == branch.index ? 2 : 1
                        )
                )
        }
        .frame(width: size.width, height: size.height + branchHeaderHeight)
    }

    private func focusedBranchCanvas(size: CGSize) -> some View {
        let branch = session.branches[session.selectedBranchIndex]

        return VStack(spacing: 12) {
            HStack(spacing: 10) {
                Label("当前仅临时放大查看 \(branch.title)，这不是主画布", systemImage: "rectangle.on.rectangle")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.92))

                Spacer(minLength: 8)

                Button("返回四宫格") {
                    session.returnToGridCanvasLayout()
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.orange.opacity(0.18))
            )

            CanvasContainerView(
                viewModel: branch.viewModel,
                onCanvasInteraction: {
                    session.activateBranch(branch.index, adoptingEditingContext: false)
                }
            )
            .frame(width: size.width, height: size.height)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(Color.orange.opacity(0.8), lineWidth: 2)
            )
            .shadow(color: Color.black.opacity(0.2), radius: 16, x: 0, y: 10)

            Text("放大查看不会改变同步推进 / 差异推进状态，只是临时专注编辑当前小画布。")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.72))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}
