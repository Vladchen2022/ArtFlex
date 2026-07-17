import AppKit
import SwiftUI

enum BlockReferencePanelTab: String, CaseIterable {
    case build
    case transform
    case reference
    case camera
    case scene

    var displayName: String {
        switch self {
        case .build: return "建模"
        case .transform: return "变换"
        case .reference: return "参考"
        case .camera: return "相机"
        case .scene: return "场景"
        }
    }

    var symbolName: String {
        switch self {
        case .build: return "cube"
        case .transform: return "move.3d"
        case .reference: return "ruler"
        case .camera: return "camera"
        case .scene: return "square.3.layers.3d"
        }
    }
}

enum BlockReferencePanelPresentation: CaseIterable, Equatable {
    case library
    case context
    case objects
    case cameraSlots
}

private enum BlockReferenceLibraryCategory: String, CaseIterable, Hashable {
    case primitives = "基础体"
    case people = "人物"
    case architecture = "建筑"
}

private enum BlockReferenceLibrarySelection: Hashable {
    case builtIn(BlockReferenceLibraryCategory)
    case custom(UUID)
}

private enum BlockReferencePendingModuleSave {
    case new(categoryID: UUID, preferredObjectID: UUID)
    case saveAsNew(categoryID: UUID, instanceObjectID: UUID)
}

private enum BlockReferenceTransformDetail: String {
    case geometry = "构造"
    case pivot = "枢轴"
    case organization = "组织"
    case array = "阵列"

    var symbolName: String {
        switch self {
        case .geometry: return "slider.horizontal.3"
        case .pivot: return "scope"
        case .organization: return "square.3.layers.3d"
        case .array: return "square.grid.3x3"
        }
    }
}

struct BlockReferenceParameterPanel: View {
    @ObservedObject var viewModel: WorkspaceViewModel
    let presentation: BlockReferencePanelPresentation
    @Binding var selectedTab: BlockReferencePanelTab
    @State private var selectedLibrarySelection: BlockReferenceLibrarySelection = .builtIn(.primitives)
    @State private var isNewModuleCategoryAlertPresented = false
    @State private var newModuleCategoryName = ""
    @State private var pendingModuleSave: BlockReferencePendingModuleSave?
    @State private var pendingModuleName = ""
    @State private var isModuleNameAlertPresented = false
    @State private var arrayCount = 3
    @State private var arraySpacing = 40.0
    @State private var radialDegrees = 360.0
    @State private var arrayAxis = BlockReferenceAxis.x
    @State private var workingPlaneMoveAxis = BlockReferenceAxis.z
    @State private var workingPlaneMoveDistance = 10.0
    @State private var expandedTransformDetail: BlockReferenceTransformDetail?

    var body: some View {
        if let scene = viewModel.blockReferenceScene {
            switch presentation {
            case .library:
                libraryPanel
            case .context:
                contextPanel(scene)
            case .objects:
                objectManagerPanel(scene)
            case .cameraSlots:
                cameraSlotList(scene)
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Text("体块参考已清除")
                    .font(.system(size: 12, weight: .semibold))
                Button("创建体块参考场景") {
                    viewModel.createEmptyBlockReferenceScene()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func contextPanel(_ scene: BlockReferenceScene) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("工具与参数")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.92))
                Spacer()
                Text(selectedTab.displayName)
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundStyle(Color.white.opacity(0.5))
            }

            Picker("3D 面板", selection: $selectedTab) {
                ForEach(BlockReferencePanelTab.allCases, id: \.self) { tab in
                    Label(tab.displayName, systemImage: tab.symbolName).tag(tab)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .controlSize(.small)

            Text(contextInstruction(scene))
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.72))
                .fixedSize(horizontal: false, vertical: true)

            switch selectedTab {
            case .build:
                buildOperationControls
            case .transform:
                if let object = viewModel.selectedBlockReferenceObject {
                    if viewModel.selectedBlockReferenceObjectIDs.count > 1 {
                        multipleSelectionControls(activeObject: object)
                        transformDetailControls(object: object, includesGeometry: false)
                    } else {
                        selectedObjectControls(object)
                        transformDetailControls(
                            object: object,
                            includesGeometry: object.moduleKind?.isParametric == true
                                || object.moduleKind == .poseableHuman
                        )
                    }
                } else {
                    emptyTabHint("先在画布或“建模”标签选择体块。")
                }
            case .reference:
                snapControls(scene)
                referenceConstructionControls(scene)
                if let object = viewModel.selectedBlockReferenceObject {
                    objectStyleControls(object)
                }
            case .camera:
                perspectiveMatchControls
                cameraControls(scene.camera)
                perspectiveLineControls(scene)
            case .scene:
                displayControls(scene)
                sceneSnapshotControls(scene)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(Color.white.opacity(0.88))
        .environment(\.colorScheme, .dark)
    }

    private var buildOperationControls: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                modeButton(.select, image: "cursorarrow")
                modeButton(.measure, image: "ruler")
                modeButton(.pickWorkPlane, image: "square.3.layers.3d")
            }
            Toggle("表面直接建模", isOn: Binding(
                get: { viewModel.blockReferenceEditorState.buildsDirectlyOnSurfaces },
                set: { viewModel.setBlockReferenceBuildsDirectlyOnSurfaces($0) }
            ))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(Color.white.opacity(0.82))
            .help("开启后，选择基础体块并在现有体块表面拖动，即以该表面作为本次工作面")

            Text("从左侧体块库选择模型；在画布工作面拖出基面，再拖拉高度。")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.46))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var libraryPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("体块库")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.92))
                Spacer()
                Text("选择后在画布创建")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.42))
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5) {
                    ForEach(BlockReferenceLibraryCategory.allCases, id: \.self) { category in
                        libraryCategoryButton(
                            title: category.rawValue,
                            selection: .builtIn(category)
                        )
                    }
                    ForEach(viewModel.blockReferenceModuleLibrary.categories) { category in
                        libraryCategoryButton(
                            title: category.name,
                            selection: .custom(category.id)
                        )
                    }
                    Button {
                        newModuleCategoryName = ""
                        isNewModuleCategoryAlertPresented = true
                    } label: {
                        Image(systemName: "plus")
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .help("新建体块类目")
                }
            }

            switch selectedLibrarySelection {
            case .builtIn(.primitives):
                LazyVGrid(columns: blockLibraryColumns, spacing: 7) {
                    modeButton(.box, image: "cube", horizontalLayout: true)
                    modeButton(.cylinder, image: "cylinder", horizontalLayout: true)
                    modeButton(.cone, image: "triangle", horizontalLayout: true)
                    modeButton(.sphere, image: "circle", horizontalLayout: true)
                }
            case .builtIn(.people):
                LazyVGrid(columns: blockLibraryColumns, spacing: 7) {
                    moduleButton(.standingHuman)
                    moduleButton(.seatedHuman)
                    moduleButton(.poseableHuman)
                }
            case .builtIn(.architecture):
                LazyVGrid(columns: blockLibraryColumns, spacing: 7) {
                    moduleButton(.stairs)
                    moduleButton(.doorFrame)
                    moduleButton(.roomBox)
                    moduleButton(.table)
                }
            case .custom(let categoryID):
                let modules = viewModel.blockReferenceModuleLibrary.modules(in: categoryID)
                if modules.isEmpty {
                    Text("此类目为空。选中场景体块后，在“场景对象”中右键存入这里。")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.42))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, minHeight: 58, alignment: .topLeading)
                } else {
                    LazyVGrid(columns: blockLibraryColumns, spacing: 7) {
                        ForEach(modules) { asset in
                            customModuleButton(asset)
                        }
                    }
                }
            }

        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(Color.white.opacity(0.88))
        .environment(\.colorScheme, .dark)
        .alert("新建体块类目", isPresented: $isNewModuleCategoryAlertPresented) {
            TextField("例如：交通工具", text: $newModuleCategoryName)
            Button("取消", role: .cancel) {}
            Button("新建") {
                if let categoryID = viewModel.createBlockReferenceModuleCategory(named: newModuleCategoryName) {
                    selectedLibrarySelection = .custom(categoryID)
                }
            }
        } message: {
            Text("类目会持久保存在体块库中。")
        }
    }

    private func libraryCategoryButton(
        title: String,
        selection: BlockReferenceLibrarySelection
    ) -> some View {
        let isSelected = selectedLibrarySelection == selection
        return Button {
            selectedLibrarySelection = selection
        } label: {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .lineLimit(1)
                .padding(.horizontal, 9)
                .frame(minHeight: 24)
                .foregroundStyle(isSelected ? Color.white : Color.white.opacity(0.7))
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isSelected ? Color.accentColor : Color.white.opacity(0.07))
                )
        }
        .buttonStyle(.plain)
    }

    private var blockLibraryColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 7), count: 2)
    }

    private func objectManagerPanel(_ scene: BlockReferenceScene) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            objectList(scene, showsTitle: false, maximumHeight: 330)
            Divider().overlay(Color.white.opacity(0.08))
            objectManagerActions(scene)
            moduleBasePointControls(scene)
        }
        .frame(maxWidth: .infinity, minHeight: 220, alignment: .topLeading)
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(Color.white.opacity(0.88))
        .environment(\.colorScheme, .dark)
        .alert("保存到体块库", isPresented: $isModuleNameAlertPresented) {
            TextField("模块名称", text: $pendingModuleName)
            Button("取消", role: .cancel) {
                pendingModuleSave = nil
            }
            Button("保存") {
                commitPendingModuleSave()
            }
        } message: {
            Text("模块会保留各个体块，并以当前枢轴作为基准点。")
        }
    }

    private func objectManagerActions(_ scene: BlockReferenceScene) -> some View {
        HStack(spacing: 7) {
            Button {
                viewModel.selectAllBlockReferenceObjects()
            } label: {
                Image(systemName: "checkmark.circle")
            }
            .help("选择全部体块")
            .disabled(scene.objects.isEmpty)

            Button {
                viewModel.duplicateSelectedBlockReferenceObject()
            } label: {
                Image(systemName: "plus.square.on.square")
            }
            .help("复制所选")
            .disabled(viewModel.selectedBlockReferenceObjectIDs.isEmpty)

            Button(role: .destructive) {
                viewModel.deleteSelectedBlockReferenceObject()
            } label: {
                Image(systemName: "trash")
            }
            .help("删除所选")
            .disabled(viewModel.selectedBlockReferenceObjectIDs.isEmpty)

            Spacer()

            Menu {
                Button("隔离所选") { viewModel.isolateSelectedBlockReferenceObjects() }
                    .disabled(viewModel.selectedBlockReferenceObjectIDs.isEmpty)
                Button("显示全部") { viewModel.showAllBlockReferenceObjects() }
                    .disabled(scene.objects.isEmpty)
                Button("编组所选") { viewModel.groupSelectedBlockReferenceObjects() }
                    .disabled(viewModel.selectedBlockReferenceObjectIDs.count < 2)
                Button("解组所选") { viewModel.ungroupSelectedBlockReferenceObjects() }
                    .disabled(viewModel.selectedBlockReferenceObjectIDs.isEmpty)
                Divider()
                Button("完全清除场景", role: .destructive) {
                    viewModel.clearBlockReferenceScene()
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .help("更多场景对象操作")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    private func moduleBasePointControls(_ scene: BlockReferenceScene) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider().overlay(Color.white.opacity(0.08))
            HStack(spacing: 6) {
                Button {
                    viewModel.beginPickingBlockReferenceModuleBasePoint()
                } label: {
                    Label("拾取模块基准点", systemImage: "scope")
                }
                Button("使用所选中心") {
                    viewModel.useSelectionCenterAsBlockReferencePivot()
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
            .disabled(viewModel.selectedBlockReferenceObjectIDs.isEmpty)

            Text(scene.pivotMode == .custom
                 ? "已设置：载入模块时此点落在活动工作面原点"
                 : "默认使用所选体块中心作为模块基准点")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.43))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func objectList(
        _ scene: BlockReferenceScene,
        showsTitle: Bool = true,
        maximumHeight: CGFloat = 190
    ) -> some View {
        let selection = viewModel.selectedBlockReferenceObjectIDs
        let activeID = viewModel.blockReferenceEditorState.selectedObjectID
        return VStack(alignment: .leading, spacing: 6) {
            if showsTitle {
                HStack {
                    sectionTitle("场景对象")
                    Spacer()
                    if !selection.isEmpty {
                        Text("已选 \(selection.count)")
                            .font(.system(size: 10, weight: .semibold).monospacedDigit())
                            .foregroundStyle(Color.accentColor)
                    }
                }
            }

            if scene.objects.isEmpty {
                Text("暂无体块；从左侧体块库选择模型后在画布拖建。")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.38))
                    .frame(maxWidth: .infinity, minHeight: 42, alignment: .leading)
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(Array(scene.objects.reversed())) { object in
                            objectRow(
                                object,
                                isSelected: selection.contains(object.id),
                                isActive: activeID == object.id
                            )
                        }
                    }
                }
                .frame(maxHeight: maximumHeight)
            }
        }
    }

    private func contextInstruction(_ scene: BlockReferenceScene) -> String {
        switch selectedTab {
        case .build:
            return viewModel.blockReferenceEditorState.instruction
        case .transform:
            return viewModel.selectedBlockReferenceObjectIDs.isEmpty
                ? "先在画布或场景对象面板选择体块，再进行精确变换。"
                : "调整所选体块的位置、旋转、尺寸、枢轴、阵列与组织关系。"
        case .reference:
            return "管理活动工作面、捕捉、测量、构造辅助线和剖切观察。"
        case .camera:
            return viewModel.blockReferenceEditorState.perspectiveMatch.isActive
                ? viewModel.blockReferenceEditorState.instruction
                : "调整观察相机，或用画面直边匹配现有图片的透视。"
        case .scene:
            return scene.objects.isEmpty
                ? "设置体块参考的显示方式；创建对象后可保存完整场景快照。"
                : "控制整体显示，并保存或恢复包含相机与工作面的场景快照。"
        }
    }

    private func objectRow(
        _ object: BlockReferenceObject,
        isSelected: Bool,
        isActive: Bool
    ) -> some View {
        HStack(spacing: 6) {
            Button {
                let modifiers = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
                viewModel.selectBlockReferenceObject(object.id, extending: modifiers.contains(.shift))
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: object.geometrySymbolName)
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 14)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(object.name)
                            .font(.system(size: 10, weight: isActive ? .bold : .semibold))
                            .lineLimit(1)
                        Text(object.geometryDisplayName)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Color.white.opacity(0.38))
                    }
                    Spacer(minLength: 4)
                    if isActive {
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 6, height: 6)
                    }
                }
                .foregroundStyle(Color.white.opacity(object.isVisible ? 0.88 : 0.38))
                .padding(.horizontal, 7)
                .frame(maxWidth: .infinity, minHeight: 34)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(isSelected ? Color.accentColor.opacity(isActive ? 0.28 : 0.14) : Color.white.opacity(0.045))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(isActive ? Color.accentColor.opacity(0.9) : Color.clear, lineWidth: 1)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                viewModel.setBlockReferenceObjectVisibility(object.id, isVisible: !object.isVisible)
            } label: {
                Image(systemName: object.isVisible ? "eye" : "eye.slash")
                    .frame(width: 16, height: 24)
            }
            .help(object.isVisible ? "隐藏体块" : "显示体块")

            Button {
                viewModel.setBlockReferenceObjectLocked(object.id, isLocked: !object.isLocked)
            } label: {
                Image(systemName: object.isLocked ? "lock.fill" : "lock.open")
                    .frame(width: 16, height: 24)
            }
            .help(object.isLocked ? "解锁体块" : "锁定体块")
        }
        .buttonStyle(.borderless)
        .controlSize(.mini)
        .contextMenu {
            objectModuleContextMenu(object)
        }
    }

    @ViewBuilder
    private func objectModuleContextMenu(_ object: BlockReferenceObject) -> some View {
        Button("拾取模块基准点…") {
            if !viewModel.selectedBlockReferenceObjectIDs.contains(object.id) {
                viewModel.selectBlockReferenceObject(object.id, extending: false)
            }
            viewModel.beginPickingBlockReferenceModuleBasePoint()
        }
        Button("基准点使用所选中心") {
            if !viewModel.selectedBlockReferenceObjectIDs.contains(object.id) {
                viewModel.selectBlockReferenceObject(object.id, extending: false)
            }
            viewModel.useSelectionCenterAsBlockReferencePivot()
        }
        Divider()
        if let instance = viewModel.blockReferenceCustomModuleInstance(containing: object.id) {
            let asset = viewModel.blockReferenceModuleAsset(for: instance)
            Button("编辑模块部件") {
                viewModel.beginEditingBlockReferenceModuleInstance(containing: object.id)
            }
            Button("保存并替换“\(asset?.name ?? "原模块")”") {
                viewModel.replaceEditedBlockReferenceModule(containing: object.id)
            }
            .disabled(asset == nil)
            Menu("另存为新模块") {
                ForEach(viewModel.blockReferenceModuleLibrary.categories) { category in
                    Button(category.name) {
                        prepareModuleSave(
                            .saveAsNew(categoryID: category.id, instanceObjectID: object.id),
                            suggestedName: "\(asset?.name ?? object.name) 副本"
                        )
                    }
                }
            }
            Divider()
            Button("不回存体块库（保留场景修改）") {
                viewModel.detachBlockReferenceModuleInstance(containing: object.id)
            }
        } else {
            Menu("将所选体块存入体块库") {
                ForEach(viewModel.blockReferenceModuleLibrary.categories) { category in
                    Button(category.name) {
                        prepareModuleSave(
                            .new(categoryID: category.id, preferredObjectID: object.id),
                            suggestedName: viewModel.suggestedBlockReferenceModuleName(
                                preferredObjectID: object.id
                            )
                        )
                    }
                }
            }
        }
    }

    private func prepareModuleSave(
        _ pending: BlockReferencePendingModuleSave,
        suggestedName: String
    ) {
        pendingModuleSave = pending
        pendingModuleName = suggestedName
        isModuleNameAlertPresented = true
    }

    private func commitPendingModuleSave() {
        guard let pendingModuleSave else { return }
        switch pendingModuleSave {
        case .new(let categoryID, let preferredObjectID):
            _ = viewModel.saveSelectedBlockReferenceObjectsAsModule(
                named: pendingModuleName,
                categoryID: categoryID,
                preferredObjectID: preferredObjectID
            )
        case .saveAsNew(let categoryID, let instanceObjectID):
            _ = viewModel.saveEditedBlockReferenceModuleAsNew(
                containing: instanceObjectID,
                named: pendingModuleName,
                categoryID: categoryID
            )
        }
        self.pendingModuleSave = nil
    }

    private func displayControls(_ scene: BlockReferenceScene) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Toggle("显示", isOn: Binding(
                    get: { scene.display.isVisible },
                    set: { value in viewModel.setBlockReferenceVisibility(value) }
                ))
                Toggle("面", isOn: Binding(
                    get: { scene.display.showsFaces },
                    set: { value in viewModel.setBlockReferenceShowsFaces(value) }
                ))
                Toggle("边", isOn: Binding(
                    get: { scene.display.showsEdges },
                    set: { value in viewModel.setBlockReferenceShowsEdges(value) }
                ))
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(Color.white.opacity(0.82))

            HStack(spacing: 8) {
                Text("模式")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.72))
                Picker("模式", selection: Binding(
                    get: { scene.display.mode },
                    set: { viewModel.setBlockReferenceDisplayMode($0) }
                )) {
                    ForEach(BlockReferenceDisplayMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .controlSize(.mini)
            }

            parameterSlider(
                title: "透明度",
                valueText: "\(Int((scene.display.opacity * 100).rounded()))%",
                value: Binding(
                    get: { Double(scene.display.opacity) },
                    set: { viewModel.setBlockReferenceOpacity(Float($0)) }
                ),
                range: 0.05...1
            )
        }
    }

    private func snapControls(_ scene: BlockReferenceScene) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("捕捉与工作面")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                ForEach(BlockReferenceSnapKind.allCases, id: \.self) { kind in
                    Toggle(kind.displayName, isOn: Binding(
                        get: { scene.snap.enabledKinds.contains(kind) },
                        set: { viewModel.setBlockReferenceSnapKind(kind, enabled: $0) }
                    ))
                    .toggleStyle(.button)
                    .controlSize(.small)
                }
            }

            parameterSlider(
                title: "网格",
                valueText: String(format: "%.0f", scene.snap.gridSpacing),
                value: Binding(
                    get: { scene.snap.gridSpacing },
                    set: { value in viewModel.setBlockReferenceGridSpacing(value) }
                ),
                range: 2...200
            )

            HStack(spacing: 8) {
                Button("恢复默认地面") { viewModel.resetBlockReferenceWorkingPlane() }
                Button("清除测量") { viewModel.clearBlockReferenceMeasurements() }
                    .disabled(scene.measurements.isEmpty)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            let plane = scene.workingPlane
            Text(String(
                format: "活动工作面  原点 %.1f / %.1f / %.1f  法线 %.2f / %.2f / %.2f",
                plane.origin.x, plane.origin.y, plane.origin.z,
                plane.normal.x, plane.normal.y, plane.normal.z
            ))
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundStyle(Color.cyan.opacity(0.82))
            .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 7) {
                    Text("移动工作面")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.68))
                    Picker("世界轴", selection: $workingPlaneMoveAxis) {
                        ForEach(BlockReferenceAxis.allCases, id: \.self) { axis in
                            Text(axis.displayName).tag(axis)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                }
                HStack(spacing: 6) {
                    BlockNumberField(
                        label: "距离",
                        value: workingPlaneMoveDistance,
                        scrubSensitivity: 0.5,
                        minimumValue: 0,
                        onEditingChanged: { _ in }
                    ) { workingPlaneMoveDistance = $0 }
                    Button("负向") {
                        viewModel.translateBlockReferenceWorkingPlane(
                            axis: workingPlaneMoveAxis,
                            distance: -abs(workingPlaneMoveDistance)
                        )
                    }
                    Button("正向") {
                        viewModel.translateBlockReferenceWorkingPlane(
                            axis: workingPlaneMoveAxis,
                            distance: abs(workingPlaneMoveDistance)
                        )
                    }
                    .buttonStyle(.borderedProminent)
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .disabled(abs(workingPlaneMoveDistance) <= 0.000_001)
                Text("按世界 X/Y/Z 轴平移工作面；斜面沿自身法线移动仍使用下方“网格偏移”。")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.42))
            }
        }
    }

    private func selectedObjectControls(_ object: BlockReferenceObject) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider().overlay(Color.white.opacity(0.08))
            HStack {
                sectionTitle("所选 \(object.name)")
                Spacer()
                Button {
                    viewModel.duplicateSelectedBlockReferenceObject()
                } label: {
                    Image(systemName: "plus.square.on.square")
                }
                Button(role: .destructive) {
                    viewModel.deleteSelectedBlockReferenceObject()
                } label: {
                    Image(systemName: "trash")
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)

            numericTransformControls(object)

            if object.allowsGeometryEditing {
                TripleBlockNumberFields(
                    title: "尺寸",
                    labels: ["宽", "深", "高"],
                    values: [object.dimensions.width, object.dimensions.depth, object.dimensions.height],
                    scrubSensitivity: 0.2,
                    minimumValue: 1,
                    onEditingChanged: viewModel.setBlockReferenceParameterEditing
                ) { axis, value in
                    var dimensions = object.dimensions
                    if axis == 0 { dimensions.width = value }
                    if axis == 1 { dimensions.depth = value }
                    if axis == 2 { dimensions.height = value }
                    viewModel.setSelectedBlockReferenceDimensions(dimensions)
                }
            } else {
                Text(object.moduleKind == .poseableHuman
                    ? "可摆姿人体 · 内部体块不可拆分，不参与布尔运算。"
                    : "固定人体模块 · 比例和内部体块不可编辑，不参与布尔运算。")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.46))
                    .fixedSize(horizontal: false, vertical: true)
            }

            TripleBlockNumberFields(
                title: "位置",
                labels: ["X", "Y", "Z"],
                values: [object.position.x, object.position.y, object.position.z],
                scrubSensitivity: 0.5,
                minimumValue: nil,
                onEditingChanged: viewModel.setBlockReferenceParameterEditing
            ) { axis, value in
                var position = object.position
                if axis == 0 { position.x = value }
                if axis == 1 { position.y = value }
                if axis == 2 { position.z = value }
                viewModel.setSelectedBlockReferencePosition(position)
            }

            TripleBlockNumberFields(
                title: "旋转",
                labels: ["X°", "Y°", "Z°"],
                values: [
                    object.rotation.xDegrees,
                    object.rotation.yDegrees,
                    object.rotation.zDegrees
                ],
                scrubSensitivity: 0.5,
                minimumValue: nil,
                onEditingChanged: viewModel.setBlockReferenceParameterEditing
            ) { axis, value in
                var rotation = object.rotation
                if axis == 0 { rotation.xDegrees = value }
                if axis == 1 { rotation.yDegrees = value }
                if axis == 2 { rotation.zDegrees = value }
                viewModel.setSelectedBlockReferenceRotation(rotation)
            }
        }
    }

    private func multipleSelectionControls(activeObject: BlockReferenceObject) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider().overlay(Color.white.opacity(0.08))
            HStack {
                sectionTitle("已选 \(viewModel.selectedBlockReferenceObjectIDs.count) 个 · 活动：\(activeObject.name)")
                Spacer()
                Button {
                    viewModel.duplicateSelectedBlockReferenceObject()
                } label: {
                    Image(systemName: "plus.square.on.square")
                }
                Button(role: .destructive) {
                    viewModel.deleteSelectedBlockReferenceObject()
                } label: {
                    Image(systemName: "trash")
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)

            numericTransformControls(activeObject)
            if viewModel.selectedBlockReferenceObjectIDs.count == 2 {
                booleanControls(activeObject: activeObject)
            }
            Text("组合变换以所选体块中心为枢轴；尺寸仍需单独选择体块调整。")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.42))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func booleanControls(activeObject: BlockReferenceObject) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider().overlay(Color.white.opacity(0.08))
            HStack {
                sectionTitle("布尔 · 主体：\(activeObject.name)")
                Spacer()
            }
            HStack(spacing: 6) {
                Button("合并") {
                    viewModel.applyBlockReferenceBoolean(.union)
                }
                Button("减去") {
                    viewModel.applyBlockReferenceBoolean(.subtract)
                }
                .help("活动对象 − 另一个对象")
                Button("相交") {
                    viewModel.applyBlockReferenceBoolean(.intersection)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(!viewModel.canApplyBlockReferenceBoolean)

            Text("减去方向：活动对象 − 另一个对象；结果替换两个源体块，可撤销。")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.42))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func numericTransformControls(_ object: BlockReferenceObject) -> some View {
        let transform = viewModel.blockReferenceEditorState.numericTransform
        let isEditingObject = transform?.originalTransforms[object.id] != nil
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Button("移动 G") {
                    viewModel.beginBlockReferenceNumericTransform(.move)
                }
                .tint(transform?.kind == .move ? Color.accentColor : Color.gray)
                Button("旋转 R") {
                    viewModel.beginBlockReferenceNumericTransform(.rotate)
                }
                .tint(transform?.kind == .rotate ? Color.accentColor : Color.gray)
                Button("缩放 S") {
                    viewModel.beginBlockReferenceNumericTransform(.scale)
                }
                .tint(transform?.kind == .scale ? Color.accentColor : Color.gray)
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)

            HStack(spacing: 7) {
                Text("坐标")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.55))
                Picker("", selection: Binding(
                    get: { viewModel.blockReferenceEditorState.gizmoCoordinateSpace },
                    set: { viewModel.setBlockReferenceGizmoCoordinateSpace($0) }
                )) {
                    ForEach(BlockReferenceGizmoCoordinateSpace.allCases, id: \.self) { space in
                        Text(space.displayName).tag(space)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(maxWidth: .infinity)
            }
            .controlSize(.mini)

            if isEditingObject, let transform {
                HStack(spacing: 5) {
                    if transform.kind == .scale {
                        Button("统一") {
                            viewModel.setBlockReferenceNumericTransformUniformScale()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        .tint(transform.axis == nil ? Color.accentColor : Color.gray)
                    }
                    ForEach(BlockReferenceAxis.allCases, id: \.self) { axis in
                        Button(axis.displayName) {
                            viewModel.setBlockReferenceNumericTransformAxis(axis)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        .tint(transform.axis == axis ? axisColor(axis) : Color.gray)
                    }
                    TextField(
                        transform.kind == .move ? "距离" : (transform.kind == .rotate ? "角度" : "比例"),
                        text: Binding(
                            get: { viewModel.blockReferenceEditorState.numericTransform?.input ?? "" },
                            set: { viewModel.setBlockReferenceNumericTransformInput($0) }
                        )
                    )
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 10, design: .monospaced))
                    .onSubmit { viewModel.commitBlockReferenceNumericTransform() }
                    Button("应用") { viewModel.commitBlockReferenceNumericTransform() }
                        .disabled((transform.kind != .scale && transform.axis == nil) || transform.value == nil)
                    Button("取消") { viewModel.cancelBlockReferenceNumericTransform() }
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                Text("Blender 轴规则：G/R/S → X 为世界轴；再按一次 X（XX）切到局部轴。Y、Z 同理。")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.62))
            }
        }
    }

    private func axisColor(_ axis: BlockReferenceAxis) -> Color {
        switch axis {
        case .x: return .red
        case .y: return .green
        case .z: return .blue
        }
    }

    private var perspectiveMatchControls: some View {
        let state = viewModel.blockReferenceEditorState.perspectiveMatch
        let assessment = viewModel.blockReferencePerspectiveMatchAssessment
        let planeAnchor = state.resolvedPlaneAnchor(
            canvasSize: viewModel.workspace.document.canvasSize
        )
        let canApply = assessment != nil && planeAnchor != nil
        return VStack(alignment: .leading, spacing: 7) {
            HStack {
                sectionTitle("画面透视匹配")
                Spacer()
                Text(assessment.map { planeAnchor == nil ? "需要工作面中心" : $0.quality.displayName }
                    ?? "需要 X/Y/Z 各两条")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(matchQualityColor(assessment?.quality))
            }

            HStack(spacing: 6) {
                Button(state.isActive ? "退出画线" : (state.hasAnyLines ? "继续画线" : "开始画线")) {
                    if state.isActive {
                        viewModel.stopBlockReferencePerspectiveMatch()
                    } else {
                        viewModel.startBlockReferencePerspectiveMatch()
                    }
                }
                .buttonStyle(.borderedProminent)
                Button("应用到相机") {
                    viewModel.applyBlockReferencePerspectiveMatch()
                }
                .disabled(!canApply)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            HStack(spacing: 6) {
                Button(state.isPickingPlaneAnchor ? "请点击画布…" : "拾取工作面中心") {
                    viewModel.pickBlockReferencePerspectiveMatchPlaneAnchor()
                }
                .disabled(state.lineCount(for: .x) < 2 || state.lineCount(for: .y) < 2)
                Button("恢复自动中心") {
                    viewModel.useAutomaticBlockReferencePerspectiveMatchPlaneAnchor()
                }
                .disabled(state.planeAnchor == nil)
                Spacer()
                Text(state.planeAnchor == nil ? "自动" : "手动")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color.cyan.opacity(0.86))
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)

            Picker("参考方向", selection: Binding(
                get: { state.activeAxis },
                set: { viewModel.setBlockReferencePerspectiveMatchAxis($0) }
            )) {
                ForEach(BlockReferenceAxis.allCases, id: \.self) { axis in
                    Text("\(axis.displayName)  \(state.lineCount(for: axis))/2").tag(axis)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .disabled(!state.isActive)

            HStack(spacing: 6) {
                ForEach(BlockReferenceAxis.allCases, id: \.self) { axis in
                    HStack(spacing: 4) {
                        Circle()
                            .fill(axisColor(axis))
                            .frame(width: 6, height: 6)
                        Text("\(axis.displayName) \(state.lineCount(for: axis))")
                    }
                    .font(.system(size: 9, weight: .semibold).monospacedDigit())
                }
                Spacer()
                Button("撤销一条") { viewModel.undoLastBlockReferencePerspectiveMatchLine() }
                    .disabled(!state.hasAnyLines)
                Button("清当前") {
                    viewModel.clearBlockReferencePerspectiveMatchAxis(state.activeAxis)
                }
                .disabled(state.lineCount(for: state.activeAxis) == 0)
                Button("清空", role: .destructive) {
                    viewModel.clearBlockReferencePerspectiveMatch()
                }
                .disabled(!state.hasAnyLines)
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)

            Text("红 X 与绿 Y 应优先取自同一个目标桌面或地面，交点区域用于自动定位工作面；蓝 Z 使用场景竖直边。也可手动拾取工作面中心。")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.58))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func matchQualityColor(_ quality: BlockReferencePerspectiveMatchQuality?) -> Color {
        switch quality {
        case .stable: return .green
        case .approximate: return .yellow
        case .poor: return .orange
        case nil: return Color.white.opacity(0.42)
        }
    }

    private func cameraControls(_ camera: BlockReferenceCamera) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Divider().overlay(Color.white.opacity(0.08))
            HStack {
                sectionTitle("摄像机")
                Spacer()
                Button("重置") { viewModel.resetBlockReferenceCamera() }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
            }
            parameterSlider(
                title: "水平",
                valueText: "\(Int(camera.yawDegrees.rounded()))°",
                value: Binding(
                    get: { camera.yawDegrees },
                    set: { value in viewModel.setBlockReferenceCameraYaw(value) }
                ),
                range: -180...180
            )
            parameterSlider(
                title: "俯仰",
                valueText: "\(Int(camera.pitchDegrees.rounded()))°",
                value: Binding(
                    get: { camera.pitchDegrees },
                    set: { value in viewModel.setBlockReferenceCameraPitch(value) }
                ),
                range: -80...80
            )
            parameterSlider(
                title: "滚转",
                valueText: "\(Int(camera.rollDegrees.rounded()))°",
                value: Binding(
                    get: { camera.rollDegrees },
                    set: { value in viewModel.setBlockReferenceCameraRoll(value) }
                ),
                range: -180...180
            )
            parameterSlider(
                title: "距离",
                valueText: String(format: "%.0f", camera.distance),
                value: Binding(
                    get: { camera.distance },
                    set: { value in viewModel.setBlockReferenceCameraDistance(value) }
                ),
                range: 100...2_500
            )
            parameterSlider(
                title: "视场",
                valueText: "\(Int(camera.fieldOfViewDegrees.rounded()))°",
                value: Binding(
                    get: { camera.fieldOfViewDegrees },
                    set: { value in viewModel.setBlockReferenceCameraFieldOfView(value) }
                ),
                range: 15...90
            )
            Toggle("正交投影", isOn: Binding(
                get: { camera.isOrthographic },
                set: { value in viewModel.setBlockReferenceOrthographic(value) }
            ))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .font(.system(size: 11, weight: .medium))

            HStack(spacing: 6) {
                Button("查看全部") { viewModel.frameBlockReferenceCamera(selectedOnly: false) }
                Button("查看所选") { viewModel.frameBlockReferenceCamera(selectedOnly: true) }
                    .disabled(viewModel.selectedBlockReferenceObjectIDs.isEmpty)
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)

            Text("中键环绕 · ⇧中键平移 · ⌃中键/滚轮缩放 · Home 全部 · 小键盘 1/3/7 视图")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.42))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func transformDetailControls(
        object: BlockReferenceObject,
        includesGeometry: Bool
    ) -> some View {
        let details: [BlockReferenceTransformDetail] = includesGeometry
            ? [.geometry, .pivot, .organization, .array]
            : [.pivot, .organization, .array]
        let visibleDetail = expandedTransformDetail.flatMap { details.contains($0) ? $0 : nil }
        return VStack(alignment: .leading, spacing: 8) {
            Divider().overlay(Color.white.opacity(0.08))
            HStack(spacing: 5) {
                ForEach(details, id: \.self) { detail in
                    transformDetailButton(
                        detail,
                        title: detail == .geometry && object.moduleKind == .poseableHuman
                            ? "姿势"
                            : detail.rawValue,
                        isSelected: visibleDetail == detail
                    )
                }
            }

            if let visibleDetail {
                Group {
                    switch visibleDetail {
                    case .geometry:
                        transformGeometryControls(object)
                    case .pivot:
                        pivotControls
                    case .organization:
                        organizationControls
                    case .array:
                        arrayControls
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            } else {
                Text("枢轴、组织和阵列按需展开；同一时间只显示一组高级参数。")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.4))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .animation(.easeInOut(duration: 0.16), value: visibleDetail)
    }

    private func transformDetailButton(
        _ detail: BlockReferenceTransformDetail,
        title: String,
        isSelected: Bool
    ) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.16)) {
                expandedTransformDetail = isSelected ? nil : detail
            }
        } label: {
            Label(title, systemImage: detail.symbolName)
                .font(.system(size: 9, weight: .semibold))
                .frame(maxWidth: .infinity, minHeight: 25)
        }
        .buttonStyle(.bordered)
        .controlSize(.mini)
        .tint(isSelected ? Color.accentColor : Color.gray)
    }

    @ViewBuilder
    private func transformGeometryControls(_ object: BlockReferenceObject) -> some View {
        if object.moduleKind == .poseableHuman {
            poseableHumanControls(object)
        } else if object.moduleKind?.isParametric == true {
            parametricModuleControls(object)
        }
    }

    private var pivotControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("变换枢轴")
            Picker("枢轴", selection: Binding(
                get: { viewModel.blockReferenceScene?.pivotMode ?? .selectionCenter },
                set: { viewModel.setBlockReferencePivotMode($0) }
            )) {
                ForEach(BlockReferencePivotMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            HStack(spacing: 6) {
                Button("基准点=所选中心") { viewModel.useSelectionCenterAsBlockReferencePivot() }
                    .disabled(viewModel.selectedBlockReferenceObjectIDs.isEmpty)
                Button("画布拾取基准点") { viewModel.beginPickingBlockReferenceModuleBasePoint() }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private var organizationControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("批量与组织")
            LazyVGrid(columns: blockLibraryColumns, spacing: 6) {
                Button("编组 ⌃G") { viewModel.groupSelectedBlockReferenceObjects() }
                    .disabled(viewModel.selectedBlockReferenceObjectIDs.count < 2)
                Button("解组 ⌃⇧G") { viewModel.ungroupSelectedBlockReferenceObjects() }
                Button("复制 ⇧D") { viewModel.duplicateSelectedBlockReferenceObject() }
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)

            HStack(spacing: 6) {
                Text("镜像")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.55))
                ForEach(BlockReferenceAxis.allCases, id: \.self) { axis in
                    Button(axis.displayName) { viewModel.mirrorSelectedBlockReferenceObjects(axis: axis) }
                        .tint(axisColor(axis))
                }
                Spacer()
                Text("⌃M → 轴")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.38))
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
        }
    }

    private var arrayControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("阵列")
            Stepper("阵列数量 \(arrayCount)", value: $arrayCount, in: 2...32)
                .font(.system(size: 11, weight: .medium))
            HStack(spacing: 7) {
                Text("阵列轴")
                    .foregroundStyle(Color.white.opacity(0.72))
                Picker("阵列轴", selection: $arrayAxis) {
                    ForEach(BlockReferenceAxis.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }
            BlockNumberField(
                label: "间距",
                value: arraySpacing,
                scrubSensitivity: 0.5,
                minimumValue: nil,
                onEditingChanged: viewModel.setBlockReferenceParameterEditing
            ) { arraySpacing = $0 }
            BlockNumberField(
                label: "总角度",
                value: radialDegrees,
                scrubSensitivity: 0.5,
                minimumValue: nil,
                onEditingChanged: viewModel.setBlockReferenceParameterEditing
            ) { radialDegrees = $0 }
            HStack(spacing: 6) {
                Button("线性阵列") {
                    viewModel.createBlockReferenceLinearArray(
                        count: arrayCount,
                        spacing: arraySpacing,
                        axis: arrayAxis
                    )
                }
                Button("环形阵列") {
                    viewModel.createBlockReferenceRadialArray(
                        count: arrayCount,
                        totalDegrees: radialDegrees,
                        axis: arrayAxis
                    )
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
    }

    private func referenceConstructionControls(_ scene: BlockReferenceScene) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider().overlay(Color.white.opacity(0.08))
            sectionTitle("构造辅助")
            HStack(spacing: 6) {
                ForEach(BlockReferenceAxis.allCases, id: \.self) { axis in
                    Button("+\(axis.displayName)线") { viewModel.addBlockReferenceConstructionAxis(axis) }
                        .tint(axisColor(axis))
                }
                Button("清线") { viewModel.clearBlockReferenceConstructionLines() }
                    .disabled(scene.constructionLines.isEmpty)
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)

            HStack(spacing: 6) {
                Button("保存工作面") { viewModel.saveCurrentBlockReferenceWorkingPlane() }
                Button("+网格偏移") { viewModel.offsetBlockReferenceWorkingPlane(scene.snap.gridSpacing) }
                Button("−网格偏移") { viewModel.offsetBlockReferenceWorkingPlane(-scene.snap.gridSpacing) }
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)

            ForEach(scene.savedWorkingPlanes) { saved in
                Button(saved.name) { viewModel.recallBlockReferenceWorkingPlane(saved.id) }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
            }

            Divider().overlay(Color.white.opacity(0.08))
            sectionTitle("剖切观察")
            HStack(spacing: 12) {
                Toggle("启用", isOn: Binding(
                    get: { scene.section.isEnabled },
                    set: { viewModel.setBlockReferenceSectionEnabled($0) }
                ))
                Toggle("反向", isOn: Binding(
                    get: { scene.section.isInverted },
                    set: { viewModel.setBlockReferenceSectionInverted($0) }
                ))
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            .font(.system(size: 10, weight: .medium))
            Text("剖切面取自当前工作面；用“取工作面”后开启即可检查遮挡结构。")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.42))

            if !scene.measurements.isEmpty {
                Divider().overlay(Color.white.opacity(0.08))
                sectionTitle("测量")
                ForEach(scene.measurements) { measurement in
                    let delta = measurement.end - measurement.start
                    Text(String(
                        format: "长 %.1f · ΔX %.1f  ΔY %.1f  ΔZ %.1f",
                        measurement.length, delta.x, delta.y, delta.z
                    ))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.66))
                }
            }
        }
    }

    private func objectStyleControls(_ object: BlockReferenceObject) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider().overlay(Color.white.opacity(0.08))
            sectionTitle("对象显示")
            Picker("色标", selection: Binding(
                get: { object.style.colorTag },
                set: { tag in
                    var style = object.style
                    style.colorTag = tag
                    viewModel.setSelectedBlockReferenceObjectStyle(style)
                }
            )) {
                ForEach(BlockReferenceColorTag.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.menu)
            .controlSize(.small)
            parameterSlider(
                title: "对象透明",
                valueText: "\(Int((object.style.opacity * 100).rounded()))%",
                value: Binding(
                    get: { Double(object.style.opacity) },
                    set: { value in
                        var style = object.style
                        style.opacity = Float(value)
                        viewModel.setSelectedBlockReferenceObjectStyle(style)
                    }
                ),
                range: 0.05...1
            )
            Toggle("参与捕捉", isOn: Binding(
                get: { object.style.participatesInSnapping },
                set: { value in
                    var style = object.style
                    style.participatesInSnapping = value
                    viewModel.setSelectedBlockReferenceObjectStyle(style)
                }
            ))
            Toggle("冻结绘画时保留", isOn: Binding(
                get: { object.style.includedInFrozenReference },
                set: { value in
                    var style = object.style
                    style.includedInFrozenReference = value
                    viewModel.setSelectedBlockReferenceObjectStyle(style)
                }
            ))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .font(.system(size: 10, weight: .medium))
        }
    }

    private func perspectiveLineControls(_ scene: BlockReferenceScene) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Divider().overlay(Color.white.opacity(0.08))
            sectionTitle("体块棱边透视")
            HStack(spacing: 6) {
                Button(scene.display.showsPerspectiveGuides ? "隐藏实时线" : "显示实时线") {
                    viewModel.setBlockReferenceLivePerspectiveLines(
                        !scene.display.showsPerspectiveGuides
                    )
                }
                .disabled(scene.camera.isOrthographic || scene.objects.isEmpty)
                Button("冻结为二维透视") {
                    viewModel.createPerspectiveGuideFromBlockReferenceCamera()
                }
                .disabled(scene.camera.isOrthographic)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            HStack(spacing: 6) {
                Button("二维透视 → 3D 相机") {
                    viewModel.matchBlockReferenceCameraToPerspectiveGuide()
                }
                .disabled(viewModel.perspectiveGuide?.mode != .threePoint)
                Button("清除透视线", role: .destructive) {
                    viewModel.clearBlockReferencePerspectiveGuides()
                }
                .disabled(!scene.display.showsPerspectiveGuides && viewModel.perspectiveGuide == nil)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            Text(scene.camera.isOrthographic
                ? "正交投影没有有限消失点；先切换为透视投影。"
                : "实时线直接延长活动体块的实际棱边，并随相机与体块同步；冻结后才成为可独立编辑的二维辅助。")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.62))
        }
    }

    private func cameraSlotList(_ scene: BlockReferenceScene) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("视角槽")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.92))
                Spacer()
                Text("保存并调用 3D 视角")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.42))
            }
            ForEach(1...5, id: \.self) { index in
                let slot = scene.cameraSlots.first(where: { $0.index == index })
                HStack(spacing: 6) {
                    Text("\(index)")
                        .font(.system(size: 10, weight: .bold).monospacedDigit())
                        .frame(width: 18)
                    Button(slot == nil ? "载入空槽" : "调用 \(slot?.name ?? "")") {
                        viewModel.recallBlockReferenceCameraSlot(index)
                    }
                    .disabled(slot == nil)
                    Button(slot == nil ? "保存" : "覆盖") {
                        viewModel.storeBlockReferenceCameraSlot(index)
                    }
                    .disabled(slot?.isLocked == true)
                    Button {
                        viewModel.setBlockReferenceCameraSlotLocked(index, locked: !(slot?.isLocked ?? false))
                    } label: {
                        Image(systemName: slot?.isLocked == true ? "lock.fill" : "lock.open")
                    }
                    .disabled(slot == nil)
                    Button(role: .destructive) { viewModel.clearBlockReferenceCameraSlot(index) } label: {
                        Image(systemName: "trash")
                    }
                    .disabled(slot == nil || slot?.isLocked == true)
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(Color.white.opacity(0.88))
        .environment(\.colorScheme, .dark)
    }

    private func sceneSnapshotControls(_ scene: BlockReferenceScene) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider().overlay(Color.white.opacity(0.08))
            HStack {
                sectionTitle("场景快照 · 最多 6 个")
                Spacer()
                Button("保存当前") { viewModel.saveBlockReferenceSceneSnapshot() }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.mini)
            if scene.snapshots.isEmpty {
                emptyTabHint("快照保存体块、相机、工作面、测量、辅助线和剖切状态。")
            } else {
                ForEach(scene.snapshots) { snapshot in
                    HStack {
                        Text(snapshot.name)
                            .font(.system(size: 10, weight: .medium))
                        Spacer()
                        Button("恢复") { viewModel.restoreBlockReferenceSceneSnapshot(snapshot.id) }
                        Button(role: .destructive) { viewModel.deleteBlockReferenceSceneSnapshot(snapshot.id) } label: {
                            Image(systemName: "trash")
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                }
            }
            Text("工程保存会同时保存画布、体块场景、视角槽和场景快照。")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.42))
        }
    }

    private func parametricModuleControls(_ object: BlockReferenceObject) -> some View {
        let parameters = object.moduleParameters ?? .default
        return VStack(alignment: .leading, spacing: 5) {
            sectionTitle("模块参数")
            Stepper("数量 \(parameters.count)", value: Binding(
                get: { parameters.count },
                set: { value in
                    var next = parameters
                    next.count = value
                    viewModel.updateSelectedBlockReferenceModule(parameters: next)
                }
            ), in: 1...32)
            .font(.system(size: 10, weight: .medium))
            TripleBlockNumberFields(
                title: "构造",
                labels: ["数量", "进深", "厚度"],
                values: [Double(parameters.count), parameters.secondarySize, parameters.thickness],
                scrubSensitivity: 0.2,
                minimumValue: 1,
                onEditingChanged: viewModel.setBlockReferenceParameterEditing
            ) { axis, value in
                var next = parameters
                if axis == 0 { next.count = Int(value.rounded()) }
                if axis == 1 { next.secondarySize = value }
                if axis == 2 { next.thickness = value }
                viewModel.updateSelectedBlockReferenceModule(parameters: next)
            }
        }
    }

    private func poseableHumanControls(_ object: BlockReferenceObject) -> some View {
        let pose = object.humanPose ?? .standing
        return VStack(alignment: .leading, spacing: 5) {
            sectionTitle("人体姿势 · 刚性体块")
            poseSlider("骨盆水平旋转", value: pose.pelvisYawDegrees, range: -180...180) {
                var next = pose; next.pelvisYawDegrees = $0
                viewModel.updateSelectedBlockReferenceModule(pose: next)
            }
            poseSlider("躯干俯仰", value: pose.torsoPitchDegrees, range: -60...60) {
                var next = pose; next.torsoPitchDegrees = $0
                viewModel.updateSelectedBlockReferenceModule(pose: next)
            }
            poseSlider("躯干扭转", value: pose.torsoYawDegrees, range: -90...90) {
                var next = pose; next.torsoYawDegrees = $0
                viewModel.updateSelectedBlockReferenceModule(pose: next)
            }
            poseSlider("躯干侧倾", value: pose.torsoRollDegrees, range: -60...60) {
                var next = pose; next.torsoRollDegrees = $0
                viewModel.updateSelectedBlockReferenceModule(pose: next)
            }
            poseSlider("头部俯仰", value: pose.headPitchDegrees, range: -60...60) {
                var next = pose; next.headPitchDegrees = $0
                viewModel.updateSelectedBlockReferenceModule(pose: next)
            }
            poseSlider("头部转向", value: pose.headYawDegrees, range: -80...80) {
                var next = pose; next.headYawDegrees = $0
                viewModel.updateSelectedBlockReferenceModule(pose: next)
            }
            poseSlider("头部侧倾", value: pose.headRollDegrees, range: -45...45) {
                var next = pose; next.headRollDegrees = $0
                viewModel.updateSelectedBlockReferenceModule(pose: next)
            }
            poseSlider("左肩外展", value: pose.leftShoulderDegrees, range: -30...170) {
                var next = pose; next.leftShoulderDegrees = $0
                viewModel.updateSelectedBlockReferenceModule(pose: next)
            }
            poseSlider("右肩外展", value: pose.rightShoulderDegrees, range: -30...170) {
                var next = pose; next.rightShoulderDegrees = $0
                viewModel.updateSelectedBlockReferenceModule(pose: next)
            }
            poseSlider("左肩屈伸", value: pose.leftShoulderFlexionDegrees, range: -80...180) {
                var next = pose; next.leftShoulderFlexionDegrees = $0
                viewModel.updateSelectedBlockReferenceModule(pose: next)
            }
            poseSlider("右肩屈伸", value: pose.rightShoulderFlexionDegrees, range: -80...180) {
                var next = pose; next.rightShoulderFlexionDegrees = $0
                viewModel.updateSelectedBlockReferenceModule(pose: next)
            }
            poseSlider("左上臂扭转", value: pose.leftShoulderTwistDegrees, range: -90...90) {
                var next = pose; next.leftShoulderTwistDegrees = $0
                viewModel.updateSelectedBlockReferenceModule(pose: next)
            }
            poseSlider("右上臂扭转", value: pose.rightShoulderTwistDegrees, range: -90...90) {
                var next = pose; next.rightShoulderTwistDegrees = $0
                viewModel.updateSelectedBlockReferenceModule(pose: next)
            }
            poseSlider("左肘", value: pose.leftElbowDegrees, range: 0...150) {
                var next = pose; next.leftElbowDegrees = $0
                viewModel.updateSelectedBlockReferenceModule(pose: next)
            }
            poseSlider("右肘", value: pose.rightElbowDegrees, range: 0...150) {
                var next = pose; next.rightElbowDegrees = $0
                viewModel.updateSelectedBlockReferenceModule(pose: next)
            }
            poseSlider("左髋屈伸", value: pose.leftHipDegrees, range: -120...120) {
                var next = pose; next.leftHipDegrees = $0
                viewModel.updateSelectedBlockReferenceModule(pose: next)
            }
            poseSlider("右髋屈伸", value: pose.rightHipDegrees, range: -120...120) {
                var next = pose; next.rightHipDegrees = $0
                viewModel.updateSelectedBlockReferenceModule(pose: next)
            }
            poseSlider("左髋外展", value: pose.leftHipAbductionDegrees, range: -45...60) {
                var next = pose; next.leftHipAbductionDegrees = $0
                viewModel.updateSelectedBlockReferenceModule(pose: next)
            }
            poseSlider("右髋外展", value: pose.rightHipAbductionDegrees, range: -45...60) {
                var next = pose; next.rightHipAbductionDegrees = $0
                viewModel.updateSelectedBlockReferenceModule(pose: next)
            }
            poseSlider("左大腿扭转", value: pose.leftHipTwistDegrees, range: -60...60) {
                var next = pose; next.leftHipTwistDegrees = $0
                viewModel.updateSelectedBlockReferenceModule(pose: next)
            }
            poseSlider("右大腿扭转", value: pose.rightHipTwistDegrees, range: -60...60) {
                var next = pose; next.rightHipTwistDegrees = $0
                viewModel.updateSelectedBlockReferenceModule(pose: next)
            }
            poseSlider("左膝", value: pose.leftKneeDegrees, range: 0...150) {
                var next = pose; next.leftKneeDegrees = $0
                viewModel.updateSelectedBlockReferenceModule(pose: next)
            }
            poseSlider("右膝", value: pose.rightKneeDegrees, range: 0...150) {
                var next = pose; next.rightKneeDegrees = $0
                viewModel.updateSelectedBlockReferenceModule(pose: next)
            }
        }
    }

    private func poseSlider(
        _ title: String,
        value: Double,
        range: ClosedRange<Double>,
        onChange: @escaping (Double) -> Void
    ) -> some View {
        parameterSlider(
            title: title,
            valueText: "\(Int(value.rounded()))°",
            value: Binding(get: { value }, set: { next in onChange(next) }),
            range: range
        )
    }

    private func emptyTabHint(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(Color.white.opacity(0.42))
            .frame(maxWidth: .infinity, minHeight: 50, alignment: .leading)
    }

    private func modeButton(
        _ mode: BlockReferenceEditorMode,
        image: String,
        horizontalLayout: Bool = false
    ) -> some View {
        let isSelected = viewModel.blockReferenceEditorState.mode == mode
        return Button {
            viewModel.setBlockReferenceEditorMode(mode)
        } label: {
            Group {
                if horizontalLayout {
                    HStack(spacing: 5) {
                        Image(systemName: image)
                            .font(.system(size: 11, weight: .semibold))
                        Text(mode.displayName)
                            .font(.system(size: 10, weight: .semibold))
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, minHeight: 30)
                } else {
                    VStack(spacing: 3) {
                        Image(systemName: image)
                            .font(.system(size: 11, weight: .semibold))
                        Text(mode.displayName)
                            .font(.system(size: 10, weight: .semibold))
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, minHeight: 36)
                }
            }
            .foregroundStyle(isSelected ? Color.white : Color.white.opacity(0.72))
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(isSelected ? Color.accentColor.opacity(0.76) : Color.white.opacity(0.07))
            )
        }
        .buttonStyle(.plain)
    }

    private func moduleButton(_ kind: BlockReferenceModuleKind) -> some View {
        Button {
            viewModel.addBlockReferenceModule(kind)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: kind.symbolName)
                    .font(.system(size: 11, weight: .semibold))
                Text(kind.displayName)
                    .font(.system(size: 10, weight: .semibold))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: 30)
            .foregroundStyle(Color.white.opacity(0.78))
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(Color.white.opacity(0.07))
            )
        }
        .buttonStyle(.plain)
        .help(moduleHelp(kind))
    }

    private func customModuleButton(_ asset: BlockReferenceModuleAsset) -> some View {
        Button {
            viewModel.instantiateBlockReferenceModule(assetID: asset.id)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: asset.symbolName)
                    .font(.system(size: 11, weight: .semibold))
                VStack(alignment: .leading, spacing: 1) {
                    Text(asset.name)
                        .font(.system(size: 10, weight: .semibold))
                        .lineLimit(1)
                    Text("\(asset.templateObjects.count) 个体块")
                        .font(.system(size: 9, weight: .medium).monospacedDigit())
                        .foregroundStyle(Color.white.opacity(0.4))
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: 34)
            .foregroundStyle(Color.white.opacity(0.78))
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(Color.white.opacity(0.07))
            )
        }
        .buttonStyle(.plain)
        .help("在活动工作面原点载入“\(asset.name)”")
        .contextMenu {
            Button("载入") {
                viewModel.instantiateBlockReferenceModule(assetID: asset.id)
            }
            Button("载入并编辑部件") {
                viewModel.instantiateBlockReferenceModule(assetID: asset.id, forEditing: true)
            }
        }
    }

    private func moduleHelp(_ kind: BlockReferenceModuleKind) -> String {
        if kind == .poseableHuman {
            return "添加可摆姿人体，可调整主要关节、移动和旋转"
        }
        if kind.isParametric {
            return "添加\(kind.displayName)，可调整尺寸和构造参数"
        }
        return "添加固定比例的\(kind.displayName)，可移动和旋转"
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Color.white.opacity(0.68))
    }

    private func parameterSlider(
        title: String,
        valueText: String,
        value: Binding<Double>,
        range: ClosedRange<Double>
    ) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.58))
                .frame(width: 44, alignment: .leading)
            Slider(
                value: value,
                in: range,
                onEditingChanged: { isEditing in
                    viewModel.setBlockReferenceParameterEditing(isEditing)
                }
            )
            Text(valueText)
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(Color.white.opacity(0.88))
                .frame(width: 48, alignment: .trailing)
        }
    }
}

private struct TripleBlockNumberFields: View {
    let title: String
    let labels: [String]
    let values: [Double]
    let scrubSensitivity: Double
    let minimumValue: Double?
    let onEditingChanged: (Bool) -> Void
    let onCommit: (Int, Double) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.55))
            HStack(spacing: 5) {
                ForEach(0..<min(labels.count, values.count), id: \.self) { index in
                    BlockNumberField(
                        label: labels[index],
                        value: values[index],
                        scrubSensitivity: scrubSensitivity,
                        minimumValue: minimumValue,
                        onEditingChanged: onEditingChanged
                    ) { value in
                        onCommit(index, value)
                    }
                    .frame(minWidth: 0, maxWidth: .infinity)
                }
            }
            .frame(minWidth: 0, maxWidth: .infinity)
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
    }
}

private struct BlockNumberField: View {
    let label: String
    let value: Double
    let scrubSensitivity: Double
    let minimumValue: Double?
    let onEditingChanged: (Bool) -> Void
    let onCommit: (Double) -> Void

    @State private var text = ""
    @State private var isScrubbing = false

    var body: some View {
        HStack(spacing: 3) {
            Text(label)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Color.white.opacity(0.45))
            BlockScrubbableNumberTextField(
                text: $text,
                value: value,
                scrubSensitivity: scrubSensitivity,
                minimumValue: minimumValue,
                onSubmit: performCommit,
                onScrubValue: { scrubbedValue in
                    text = String(format: "%.1f", scrubbedValue)
                    onCommit(scrubbedValue)
                },
                onScrubStateChanged: { scrubbing in
                    isScrubbing = scrubbing
                    onEditingChanged(scrubbing)
                }
            )
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 22)
        }
        .frame(minWidth: 0, maxWidth: .infinity)
        .onAppear { syncText() }
        .onChange(of: value) { _, _ in
            if !isScrubbing { syncText() }
        }
    }

    private func performCommit() {
        let normalized = text.replacingOccurrences(of: ",", with: ".")
        guard let parsed = Double(normalized), parsed.isFinite else {
            syncText()
            return
        }
        onCommit(parsed)
        text = String(format: "%.1f", parsed)
    }

    private func syncText() {
        text = String(format: "%.1f", value)
    }
}

private struct BlockScrubbableNumberTextField: NSViewRepresentable {
    @Binding var text: String
    let value: Double
    let scrubSensitivity: Double
    let minimumValue: Double?
    let onSubmit: () -> Void
    let onScrubValue: (Double) -> Void
    let onScrubStateChanged: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = BlockScrubbableNSTextField()
        field.isBordered = true
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.focusRingType = .default
        field.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        field.toolTip = "水平拖动调整；单击输入精确数值；按住 Shift 精细调整"
        field.delegate = context.coordinator
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let pan = NSPanGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handlePan(_:))
        )
        field.addGestureRecognizer(pan)
        context.coordinator.field = field
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        guard field.stringValue != text,
              !context.coordinator.isScrubbing else { return }
        field.stringValue = text
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: BlockScrubbableNumberTextField
        weak var field: NSTextField?
        var isScrubbing = false
        private var scrubStartValue: Double?

        init(parent: BlockScrubbableNumberTextField) {
            self.parent = parent
        }

        func controlTextDidChange(_ notification: Notification) {
            guard !isScrubbing,
                  let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard !isScrubbing else { return }
            parent.onSubmit()
        }

        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy commandSelector: Selector
        ) -> Bool {
            guard commandSelector == #selector(NSResponder.insertNewline(_:)) else { return false }
            parent.onSubmit()
            control.window?.makeFirstResponder(nil)
            return true
        }

        @objc func handlePan(_ recognizer: NSPanGestureRecognizer) {
            guard let field else { return }
            switch recognizer.state {
            case .began:
                isScrubbing = true
                scrubStartValue = parent.value
                parent.onScrubStateChanged(true)
                field.window?.makeFirstResponder(nil)
                NSCursor.resizeLeftRight.set()

            case .changed:
                guard let scrubStartValue else { return }
                let precisionScale = NSEvent.modifierFlags.contains(.shift) ? 0.1 : 1
                let scrubbedValue = blockReferenceScrubbedParameterValue(
                    startValue: scrubStartValue,
                    horizontalTranslation: recognizer.translation(in: field).x,
                    sensitivity: parent.scrubSensitivity,
                    precisionScale: precisionScale,
                    minimumValue: parent.minimumValue
                )
                field.stringValue = String(format: "%.1f", scrubbedValue)
                parent.text = field.stringValue
                parent.onScrubValue(scrubbedValue)

            case .ended, .cancelled, .failed:
                guard isScrubbing else { return }
                isScrubbing = false
                scrubStartValue = nil
                parent.onScrubStateChanged(false)
                NSCursor.arrow.set()

            default:
                break
            }
        }
    }
}

private final class BlockScrubbableNSTextField: NSTextField {
    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }
}
