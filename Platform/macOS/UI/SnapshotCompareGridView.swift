import SwiftUI
import UniformTypeIdentifiers

struct SnapshotCompareGridView: View {
    @ObservedObject var hostViewModel: WorkspaceViewModel
    @ObservedObject var session: SnapshotCompareSessionState
    @State private var draggedSnapshotID: UUID?

    private let maxSnapshotSlots = 6
    private let gridSpacing: CGFloat = 14
    private let outerPadding: CGFloat = 18
    private let controlsBarHeight: CGFloat = 54
    private let cardHeaderHeight: CGFloat = 38
    private let filmstripWidth: CGFloat = 190

    var body: some View {
        GeometryReader { geometry in
            let canvasSize = hostViewModel.workspace.document.canvasSize
            let aspectRatio = CGFloat(canvasSize.width) / max(CGFloat(canvasSize.height), 1)
            let rightRegionWidth = max(geometry.size.width - (outerPadding * 2) - filmstripWidth - 16, 240)
            let availableHeight = max(geometry.size.height - (outerPadding * 2) - controlsBarHeight - 14, 160)
            let cellWidth = max((rightRegionWidth - gridSpacing) / 2, 120)
            let cardHeight = max((availableHeight - gridSpacing) / 2, 90)
            let canvasHeightLimit = max(cardHeight - cardHeaderHeight - 10, 40)
            let fittedCanvasHeight = min(canvasHeightLimit, cellWidth / max(aspectRatio, 0.0001))
            let fittedCanvasWidth = fittedCanvasHeight * aspectRatio

            VStack(spacing: 14) {
                controlsBar

                HStack(alignment: .top, spacing: 16) {
                    snapshotFilmstrip
                        .frame(width: filmstripWidth)
                        .frame(maxHeight: .infinity)

                    compareGrid(
                        canvasSize: CGSize(width: fittedCanvasWidth, height: fittedCanvasHeight)
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
            }
            .padding(outerPadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(red: 0.18, green: 0.18, blue: 0.19))
        }
    }

    private var controlsBar: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("快照对比")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Color.white.opacity(0.94))
                Text("拖拽左侧快照到右侧 3 个对比位，右下角固定显示进入时冻结的当前画面。")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.62))
            }

            Spacer(minLength: 10)

            Button("应用于主画布") {
                hostViewModel.applySelectedSavedSnapshotToMainCanvas()
            }
            .buttonStyle(.borderedProminent)
            .disabled(session.selectedSnapshotID == nil)

            Button("导出快照") {
                hostViewModel.exportSavedSnapshotsToDisk()
            }
            .buttonStyle(.bordered)

            Button("取消") {
                hostViewModel.cancelSnapshotCompare()
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

    private var snapshotFilmstrip: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("已保存快照")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.88))
                Spacer(minLength: 8)
                Text("\(hostViewModel.savedSnapshotCount)/6")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(Color(red: 0.94, green: 0.35, blue: 0.58))
            }
            .padding(.horizontal, 4)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 10) {
                    ForEach(Array(hostViewModel.savedSnapshots.enumerated()), id: \.element.id) { index, snapshot in
                        snapshotThumbnailCard(snapshot, index: index + 1)
                    }

                    ForEach(0..<max(0, maxSnapshotSlots - hostViewModel.savedSnapshots.count), id: \.self) { placeholderIndex in
                        emptySnapshotPlaceholder(index: hostViewModel.savedSnapshots.count + placeholderIndex + 1)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private func compareGrid(canvasSize: CGSize) -> some View {
        VStack(spacing: gridSpacing) {
            HStack(spacing: gridSpacing) {
                compareSlotCard(.topLeading, title: "对比 1", canvasSize: canvasSize)
                compareSlotCard(.topTrailing, title: "对比 2", canvasSize: canvasSize)
            }
            HStack(spacing: gridSpacing) {
                compareSlotCard(.bottomLeading, title: "对比 3", canvasSize: canvasSize)
                currentCanvasCard(canvasSize: canvasSize)
            }
        }
    }

    private func snapshotThumbnailCard(_ snapshot: CanvasSavedSnapshot, index: Int) -> some View {
        let isSelected = session.selectedSnapshotID == snapshot.id

        return Button {
            hostViewModel.selectSavedSnapshotForCompare(snapshot.id)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text("快照 \(index)")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color.white.opacity(0.9))
                    Spacer(minLength: 6)
                    if isSelected {
                        Text("已选")
                            .font(.system(size: 10, weight: .bold))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(
                                Capsule()
                                    .fill(Color(red: 0.94, green: 0.35, blue: 0.58).opacity(0.22))
                            )
                    }
                }

                snapshotPreviewImage(
                    snapshot.thumbnailImage,
                    canvasSize: CGSize(width: 146, height: 118),
                    placeholderTitle: "空白快照"
                )
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(isSelected ? Color(red: 0.94, green: 0.35, blue: 0.58).opacity(0.14) : Color.white.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isSelected ? Color(red: 0.94, green: 0.35, blue: 0.58) : Color.white.opacity(0.12), lineWidth: isSelected ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
        .overlay(alignment: .topTrailing) {
            Button {
                hostViewModel.deleteSavedSnapshot(snapshot.id)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color.white.opacity(0.92))
                    .padding(6)
            }
            .buttonStyle(.plain)
            .help("删除快照 \(index)")
        }
        .onDrag {
            draggedSnapshotID = snapshot.id
            return NSItemProvider(object: snapshot.id.uuidString as NSString)
        }
    }

    private func emptySnapshotPlaceholder(index: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("快照 \(index)")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Color.white.opacity(0.4))

            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.white.opacity(0.18), style: StrokeStyle(lineWidth: 1, dash: [6, 5]))
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.white.opacity(0.03))
                )
                .frame(height: 118)
                .overlay {
                    Text("等待保存")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.38))
                }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.white.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    private func compareSlotCard(
        _ slot: SnapshotCompareSlot,
        title: String,
        canvasSize: CGSize
    ) -> some View {
        let assignedSnapshot = session.assignedSnapshotID(for: slot).flatMap(hostViewModel.savedSnapshot(with:))
        let isSelected = assignedSnapshot?.id == session.selectedSnapshotID

        return VStack(spacing: 8) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.9))
                Spacer(minLength: 8)
                if let assignedSnapshot,
                   let index = hostViewModel.savedSnapshotDisplayIndex(for: assignedSnapshot.id) {
                    Text("快照 \(index)")
                        .font(.system(size: 11, weight: .bold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill((isSelected ? Color.accentColor : Color.white).opacity(isSelected ? 0.28 : 0.14))
                        )
                }
            }
            .padding(.horizontal, 10)
            .frame(height: cardHeaderHeight - 8)

            ZStack(alignment: .topTrailing) {
                snapshotPreviewImage(
                    assignedSnapshot?.previewImage ?? assignedSnapshot?.thumbnailImage,
                    canvasSize: canvasSize,
                    placeholderTitle: "拖拽快照到这里"
                )

                if assignedSnapshot != nil {
                    Button {
                        hostViewModel.clearSavedSnapshotCompareSlot(slot)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(Color.white.opacity(0.92))
                            .padding(8)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.white.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(isSelected ? Color.accentColor : Color.white.opacity(0.12), lineWidth: isSelected ? 2 : 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onTapGesture {
            if let assignedSnapshot {
                hostViewModel.selectSavedSnapshotForCompare(assignedSnapshot.id)
            }
        }
        .onDrop(of: [UTType.plainText.identifier], isTargeted: nil) { providers in
            handleSnapshotDrop(providers: providers, to: slot)
        }
    }

    private func currentCanvasCard(canvasSize: CGSize) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Text("当前画面")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.9))
                Spacer(minLength: 8)
                Text("冻结")
                    .font(.system(size: 11, weight: .bold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule()
                            .fill(Color.orange.opacity(0.22))
                    )
            }
            .padding(.horizontal, 10)
            .frame(height: cardHeaderHeight - 8)

            snapshotPreviewImage(
                session.frozenCurrentSnapshot.previewImage ?? session.frozenCurrentSnapshot.thumbnailImage,
                canvasSize: canvasSize,
                placeholderTitle: "当前画面"
            )
        }
        .frame(maxWidth: .infinity)
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.white.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.orange.opacity(0.6), lineWidth: 1.5)
        )
    }

    private func snapshotPreviewImage(
        _ image: CGImage?,
        canvasSize: CGSize,
        placeholderTitle: String
    ) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.22),
                            Color.white.opacity(0.14)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: canvasSize.width, height: canvasSize.height)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .shadow(color: Color.black.opacity(0.16), radius: 10, x: 0, y: 6)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.32))
                    Text(placeholderTitle)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.4))
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: max(canvasSize.height + 24, 124))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func handleSnapshotDrop(
        providers: [NSItemProvider],
        to slot: SnapshotCompareSlot
    ) -> Bool {
        if let draggedSnapshotID {
            hostViewModel.assignSavedSnapshot(draggedSnapshotID, to: slot)
            self.draggedSnapshotID = nil
            return true
        }

        guard let provider = providers.first(where: { $0.canLoadObject(ofClass: NSString.self) }) else {
            return false
        }

        provider.loadObject(ofClass: NSString.self) { object, _ in
            guard
                let rawID = object as? NSString,
                let uuid = UUID(uuidString: String(rawID))
            else {
                return
            }

            DispatchQueue.main.async {
                hostViewModel.assignSavedSnapshot(uuid, to: slot)
            }
        }

        return true
    }
}
