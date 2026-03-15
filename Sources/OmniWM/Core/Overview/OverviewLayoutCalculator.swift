import AppKit
import Foundation

typealias OverviewWorkspaceLayoutItem = (
    id: WorkspaceDescriptor.ID,
    name: String,
    isActive: Bool
)

typealias OverviewWindowLayoutData = (
    entry: WindowModel.Entry,
    title: String,
    appName: String,
    appIcon: NSImage?,
    frame: CGRect
)

enum OverviewLayoutMetrics {
    static let searchBarHeight: CGFloat = 44
    static let searchBarPadding: CGFloat = 20
    static let workspaceLabelHeight: CGFloat = 32
    static let workspaceSectionPadding: CGFloat = 16
    static let windowSpacing: CGFloat = 16
    static let windowPadding: CGFloat = 24
    static let minThumbnailWidth: CGFloat = 200
    static let maxThumbnailWidth: CGFloat = 400
    static let thumbnailAspectRatio: CGFloat = 16.0 / 10.0
    static let closeButtonSize: CGFloat = 20
    static let closeButtonPadding: CGFloat = 6
    static let contentTopPadding: CGFloat = 20
    static let contentBottomPadding: CGFloat = 40
}

@MainActor
struct OverviewLayoutCalculator {
    struct BuildContext {
        let screenFrame: CGRect
        let metricsScale: CGFloat
        let availableWidth: CGFloat
        let searchBarFrame: CGRect
        let scaledWindowPadding: CGFloat
        let scaledWorkspaceLabelHeight: CGFloat
        let scaledWorkspaceSectionPadding: CGFloat
        let scaledWindowSpacing: CGFloat
        let thumbnailWidth: CGFloat
        let thumbnailHeight: CGFloat
        let initialContentY: CGFloat
        let contentTopPadding: CGFloat
        let contentBottomPadding: CGFloat
    }

    struct NiriWorkspaceProjection {
        let section: OverviewWorkspaceSection
        let columns: [OverviewNiriColumn]
        let columnDropZones: [OverviewColumnDropZone]
    }

    static func clampedScale(_ scale: CGFloat) -> CGFloat {
        max(0.5, min(1.5, scale))
    }

    static func viewportFrame(for monitorFrame: CGRect) -> CGRect {
        CGRect(origin: .zero, size: monitorFrame.size)
    }

    static func localizedFrame(_ frame: CGRect, to monitorFrame: CGRect) -> CGRect {
        frame.offsetBy(dx: -monitorFrame.minX, dy: -monitorFrame.minY)
    }

    static func calculateLayout(
        workspaces: [OverviewWorkspaceLayoutItem],
        windows: [WindowHandle: OverviewWindowLayoutData],
        screenFrame: CGRect,
        searchQuery: String,
        scale: CGFloat
    ) -> OverviewLayout {
        calculateLayout(
            workspaces: workspaces,
            windows: windows,
            niriSnapshotsByWorkspace: [:],
            screenFrame: screenFrame,
            searchQuery: searchQuery,
            scale: scale
        )
    }

    static func calculateLayout(
        workspaces: [OverviewWorkspaceLayoutItem],
        windows: [WindowHandle: OverviewWindowLayoutData],
        niriSnapshotsByWorkspace: [WorkspaceDescriptor.ID: NiriOverviewWorkspaceSnapshot],
        screenFrame: CGRect,
        searchQuery: String,
        scale: CGFloat
    ) -> OverviewLayout {
        let context = buildContext(screenFrame: screenFrame, scale: scale)
        var layout = OverviewLayout()
        layout.scale = scale
        layout.searchBarFrame = context.searchBarFrame

        var windowsByWorkspace: [WorkspaceDescriptor.ID: [(WindowHandle, OverviewWindowLayoutData)]] = [:]
        windowsByWorkspace.reserveCapacity(workspaces.count)

        var windowsByToken: [WindowToken: (WindowHandle, OverviewWindowLayoutData)] = [:]
        windowsByToken.reserveCapacity(windows.count)

        for (handle, windowData) in windows {
            windowsByWorkspace[windowData.entry.workspaceId, default: []].append((handle, windowData))
            windowsByToken[windowData.entry.token] = (handle, windowData)
        }

        var sections: [OverviewWorkspaceSection] = []
        sections.reserveCapacity(workspaces.count)

        var niriColumnsByWorkspace: [WorkspaceDescriptor.ID: [OverviewNiriColumn]] = [:]
        var niriColumnDropZonesByWorkspace: [WorkspaceDescriptor.ID: [OverviewColumnDropZone]] = [:]
        var currentY = context.initialContentY

        for workspace in workspaces {
            guard let workspaceWindows = windowsByWorkspace[workspace.id], !workspaceWindows.isEmpty else {
                continue
            }

            if let snapshot = niriSnapshotsByWorkspace[workspace.id],
               let projection = buildNiriWorkspaceProjection(
                   workspace: workspace,
                   snapshot: snapshot,
                   windowsByToken: windowsByToken,
                   searchQuery: searchQuery,
                   currentY: &currentY,
                   context: context
               )
            {
                sections.append(projection.section)
                if !projection.columns.isEmpty {
                    niriColumnsByWorkspace[workspace.id] = projection.columns
                }
                if !projection.columnDropZones.isEmpty {
                    niriColumnDropZonesByWorkspace[workspace.id] = projection.columnDropZones
                }
                continue
            }

            if let section = buildGenericWorkspaceSection(
                workspace: workspace,
                windows: workspaceWindows,
                searchQuery: searchQuery,
                currentY: &currentY,
                context: context
            ) {
                sections.append(section)
            }
        }

        layout.workspaceSections = sections
        layout.niriColumnsByWorkspace = niriColumnsByWorkspace
        layout.niriColumnDropZonesByWorkspace = niriColumnDropZonesByWorkspace
        layout.totalContentHeight = totalContentHeight(currentY: currentY, context: context)
        return layout
    }

    private static func calculateOptimalColumns(
        windowCount: Int,
        availableWidth: CGFloat,
        thumbnailWidth: CGFloat
    ) -> Int {
        let maxColumns = Int((availableWidth + OverviewLayoutMetrics.windowSpacing) / (thumbnailWidth + OverviewLayoutMetrics.windowSpacing))
        let idealColumns = min(windowCount, max(1, maxColumns))

        if windowCount <= 3 {
            return min(windowCount, idealColumns)
        }

        if windowCount <= 6 {
            return min(3, idealColumns)
        }

        return min(4, idealColumns)
    }

    private static func buildContext(screenFrame: CGRect, scale: CGFloat) -> BuildContext {
        let metricsScale = clampedScale(scale)
        let scaledSearchBarHeight = OverviewLayoutMetrics.searchBarHeight * metricsScale
        let scaledSearchBarPadding = OverviewLayoutMetrics.searchBarPadding * metricsScale
        let searchBarY = screenFrame.maxY - scaledSearchBarHeight - scaledSearchBarPadding
        let searchBarFrame = CGRect(
            x: screenFrame.minX + screenFrame.width * 0.25,
            y: searchBarY,
            width: screenFrame.width * 0.5,
            height: scaledSearchBarHeight
        )

        let scaledWindowPadding = OverviewLayoutMetrics.windowPadding * metricsScale
        let availableWidth = screenFrame.width - (scaledWindowPadding * 2)
        let thumbnailWidth = min(
            OverviewLayoutMetrics.maxThumbnailWidth * metricsScale,
            max(OverviewLayoutMetrics.minThumbnailWidth * metricsScale, availableWidth / 4)
        )

        return BuildContext(
            screenFrame: screenFrame,
            metricsScale: metricsScale,
            availableWidth: availableWidth,
            searchBarFrame: searchBarFrame,
            scaledWindowPadding: scaledWindowPadding,
            scaledWorkspaceLabelHeight: OverviewLayoutMetrics.workspaceLabelHeight * metricsScale,
            scaledWorkspaceSectionPadding: OverviewLayoutMetrics.workspaceSectionPadding * metricsScale,
            scaledWindowSpacing: OverviewLayoutMetrics.windowSpacing * metricsScale,
            thumbnailWidth: thumbnailWidth,
            thumbnailHeight: thumbnailWidth / OverviewLayoutMetrics.thumbnailAspectRatio,
            initialContentY: searchBarY - OverviewLayoutMetrics.contentTopPadding * metricsScale,
            contentTopPadding: OverviewLayoutMetrics.contentTopPadding * metricsScale,
            contentBottomPadding: OverviewLayoutMetrics.contentBottomPadding * metricsScale
        )
    }

    private static func buildGenericWorkspaceSection(
        workspace: OverviewWorkspaceLayoutItem,
        windows: [(WindowHandle, OverviewWindowLayoutData)],
        searchQuery: String,
        currentY: inout CGFloat,
        context: BuildContext
    ) -> OverviewWorkspaceSection? {
        guard !windows.isEmpty else { return nil }

        let sortedWindows = windows.sorted { lhs, rhs in
            lhs.1.title < rhs.1.title
        }

        let columns = calculateOptimalColumns(
            windowCount: sortedWindows.count,
            availableWidth: context.availableWidth,
            thumbnailWidth: context.thumbnailWidth
        )

        let totalGridWidth = CGFloat(columns) * context.thumbnailWidth +
            CGFloat(columns - 1) * OverviewLayoutMetrics.windowSpacing
        let gridStartX = context.screenFrame.minX + (context.screenFrame.width - totalGridWidth) / 2

        currentY -= context.scaledWorkspaceLabelHeight

        let labelFrame = CGRect(
            x: context.screenFrame.minX + context.scaledWindowPadding,
            y: currentY,
            width: context.availableWidth,
            height: context.scaledWorkspaceLabelHeight
        )

        currentY -= context.scaledWorkspaceSectionPadding

        var windowItems: [OverviewWindowItem] = []
        windowItems.reserveCapacity(sortedWindows.count)

        for (windowIndex, (handle, windowData)) in sortedWindows.enumerated() {
            let column = windowIndex % columns
            let row = windowIndex / columns

            let windowX = gridStartX + CGFloat(column) * (context.thumbnailWidth + context.scaledWindowSpacing)
            let windowY = currentY - CGFloat(row + 1) * (context.thumbnailHeight + context.scaledWindowSpacing)
            let overviewFrame = CGRect(
                x: windowX,
                y: windowY,
                width: context.thumbnailWidth,
                height: context.thumbnailHeight
            )

            windowItems.append(
                makeWindowItem(
                    handle: handle,
                    workspaceId: workspace.id,
                    windowData: windowData,
                    overviewFrame: overviewFrame,
                    searchQuery: searchQuery
                )
            )
        }

        let rows = (sortedWindows.count + columns - 1) / columns
        let gridHeight = CGFloat(rows) * context.thumbnailHeight +
            CGFloat(rows - 1) * context.scaledWindowSpacing
        let gridFrame = CGRect(
            x: gridStartX,
            y: currentY - gridHeight,
            width: totalGridWidth,
            height: gridHeight
        )

        let section = makeWorkspaceSection(
            workspace: workspace,
            windows: windowItems,
            labelFrame: labelFrame,
            gridFrame: gridFrame,
            currentY: currentY,
            context: context
        )

        currentY = section.sectionFrame.minY - context.scaledWorkspaceSectionPadding
        return section
    }

    private static func buildNiriWorkspaceProjection(
        workspace: OverviewWorkspaceLayoutItem,
        snapshot: NiriOverviewWorkspaceSnapshot,
        windowsByToken: [WindowToken: (WindowHandle, OverviewWindowLayoutData)],
        searchQuery: String,
        currentY: inout CGFloat,
        context: BuildContext
    ) -> NiriWorkspaceProjection? {
        guard !snapshot.columns.isEmpty else { return nil }

        currentY -= context.scaledWorkspaceLabelHeight

        let labelFrame = CGRect(
            x: context.screenFrame.minX + context.scaledWindowPadding,
            y: currentY,
            width: context.availableWidth,
            height: context.scaledWorkspaceLabelHeight
        )

        currentY -= context.scaledWorkspaceSectionPadding

        let columnCount = snapshot.columns.count
        let totalWeight = snapshot.columns.reduce(CGFloat(0)) { partial, column in
            partial + max(column.widthWeight, 0.001)
        }
        let preferredWidths = snapshot.columns.map { column in
            preferredNiriColumnWidth(
                for: column,
                totalWeight: totalWeight,
                columnCount: columnCount,
                context: context
            )
        }
        let totalSpacing = context.scaledWindowSpacing * CGFloat(max(0, columnCount - 1))
        let maxColumnSpan = max(0, context.availableWidth - totalSpacing)
        let preferredWidthTotal = preferredWidths.reduce(CGFloat(0), +)
        let widthScale = preferredWidthTotal > 0 ? min(1, maxColumnSpan / preferredWidthTotal) : 1
        let columnWidths = preferredWidths.map { $0 * widthScale }
        let totalGridWidth = columnWidths.reduce(CGFloat(0), +) + totalSpacing
        let gridStartX = context.screenFrame.minX + (context.screenFrame.width - totalGridWidth) / 2

        let maxTileCount = max(1, snapshot.columns.map { max(1, $0.tiles.count) }.max() ?? 1)
        let representativeColumnWidth = columnWidths.isEmpty
            ? context.thumbnailWidth
            : max(context.thumbnailWidth * 0.5, columnWidths.reduce(CGFloat(0), +) / CGFloat(columnCount))
        let baseTileHeight = min(
            context.thumbnailHeight,
            max(30 * context.metricsScale, representativeColumnWidth / OverviewLayoutMetrics.thumbnailAspectRatio)
        )
        let innerSpacing = max(6 * context.metricsScale, context.scaledWindowSpacing * 0.375)
        let gridHeight = CGFloat(maxTileCount) * baseTileHeight +
            CGFloat(max(0, maxTileCount - 1)) * innerSpacing
        let gridFrame = CGRect(
            x: gridStartX,
            y: currentY - gridHeight,
            width: totalGridWidth,
            height: gridHeight
        )

        var windowItems: [OverviewWindowItem] = []
        windowItems.reserveCapacity(snapshot.columns.reduce(0) { $0 + $1.tiles.count })

        var projectedColumns: [OverviewNiriColumn] = []
        projectedColumns.reserveCapacity(snapshot.columns.count)

        var currentX = gridStartX
        for (columnIndex, columnSnapshot) in snapshot.columns.enumerated() {
            let columnWidth = columnWidths.indices.contains(columnIndex) ? columnWidths[columnIndex] : 0
            let columnFrame = CGRect(
                x: currentX,
                y: gridFrame.minY,
                width: columnWidth,
                height: gridHeight
            )

            let mappedWindows = columnSnapshot.tiles.compactMap { windowsByToken[$0.token] }
            let tileCount = max(1, mappedWindows.count)
            let tileSpacing = innerSpacing * CGFloat(max(0, tileCount - 1))
            let tileHeight = mappedWindows.isEmpty
                ? 0
                : max(30 * context.metricsScale, (gridHeight - tileSpacing) / CGFloat(tileCount))

            var handles: [WindowHandle] = []
            handles.reserveCapacity(mappedWindows.count)

            for (tileIndex, (handle, windowData)) in mappedWindows.enumerated() {
                let tileY = columnFrame.maxY - CGFloat(tileIndex + 1) * tileHeight -
                    CGFloat(tileIndex) * innerSpacing
                let tileFrame = CGRect(
                    x: columnFrame.minX,
                    y: tileY,
                    width: columnFrame.width,
                    height: tileHeight
                )

                windowItems.append(
                    makeWindowItem(
                        handle: handle,
                        workspaceId: workspace.id,
                        windowData: windowData,
                        overviewFrame: tileFrame,
                        searchQuery: searchQuery
                    )
                )
                handles.append(handle)
            }

            projectedColumns.append(
                OverviewNiriColumn(
                    workspaceId: workspace.id,
                    columnIndex: columnSnapshot.index,
                    frame: columnFrame,
                    windowHandles: handles
                )
            )

            currentX += columnWidth + context.scaledWindowSpacing
        }

        let section = makeWorkspaceSection(
            workspace: workspace,
            windows: windowItems,
            labelFrame: labelFrame,
            gridFrame: gridFrame,
            currentY: currentY,
            context: context
        )

        currentY = section.sectionFrame.minY - context.scaledWorkspaceSectionPadding

        return NiriWorkspaceProjection(
            section: section,
            columns: projectedColumns,
            columnDropZones: buildNiriColumnDropZones(
                workspaceId: workspace.id,
                gridFrame: gridFrame,
                columns: projectedColumns,
                context: context
            )
        )
    }

    private static func preferredNiriColumnWidth(
        for column: NiriOverviewColumnSnapshot,
        totalWeight: CGFloat,
        columnCount: Int,
        context: BuildContext
    ) -> CGFloat {
        if let preferredWidth = column.preferredWidth, preferredWidth > 0 {
            return preferredWidth
        }

        let normalizedWeight = max(column.widthWeight, 0.001) / max(totalWeight, 0.001)
        return context.thumbnailWidth * CGFloat(columnCount) * normalizedWeight
    }

    private static func buildNiriColumnDropZones(
        workspaceId: WorkspaceDescriptor.ID,
        gridFrame: CGRect,
        columns: [OverviewNiriColumn],
        context: BuildContext
    ) -> [OverviewColumnDropZone] {
        guard !columns.isEmpty else { return [] }

        let edgeZoneWidth = max(12 * context.metricsScale, min(30 * context.metricsScale, context.scaledWindowSpacing))
        var zones: [OverviewColumnDropZone] = []
        zones.reserveCapacity(columns.count + 1)

        zones.append(
            OverviewColumnDropZone(
                workspaceId: workspaceId,
                insertIndex: 0,
                frame: CGRect(
                    x: gridFrame.minX - edgeZoneWidth,
                    y: gridFrame.minY,
                    width: edgeZoneWidth,
                    height: gridFrame.height
                )
            )
        )

        if columns.count > 1 {
            for index in 0 ..< (columns.count - 1) {
                let left = columns[index].frame.maxX
                let right = columns[index + 1].frame.minX
                zones.append(
                    OverviewColumnDropZone(
                        workspaceId: workspaceId,
                        insertIndex: index + 1,
                        frame: CGRect(
                            x: left,
                            y: gridFrame.minY,
                            width: max(0, right - left),
                            height: gridFrame.height
                        )
                    )
                )
            }
        }

        zones.append(
            OverviewColumnDropZone(
                workspaceId: workspaceId,
                insertIndex: columns.count,
                frame: CGRect(
                    x: gridFrame.maxX,
                    y: gridFrame.minY,
                    width: edgeZoneWidth,
                    height: gridFrame.height
                )
            )
        )

        return zones
    }

    private static func makeWorkspaceSection(
        workspace: OverviewWorkspaceLayoutItem,
        windows: [OverviewWindowItem],
        labelFrame: CGRect,
        gridFrame: CGRect,
        currentY: CGFloat,
        context: BuildContext
    ) -> OverviewWorkspaceSection {
        let sectionBottom = gridFrame.minY
        let sectionFrame = CGRect(
            x: context.screenFrame.minX,
            y: sectionBottom,
            width: context.screenFrame.width,
            height: currentY + context.scaledWorkspaceLabelHeight - sectionBottom
        )

        return OverviewWorkspaceSection(
            workspaceId: workspace.id,
            name: workspace.name,
            windows: windows,
            sectionFrame: sectionFrame,
            labelFrame: labelFrame,
            gridFrame: gridFrame,
            isActive: workspace.isActive
        )
    }

    private static func makeWindowItem(
        handle: WindowHandle,
        workspaceId: WorkspaceDescriptor.ID,
        windowData: OverviewWindowLayoutData,
        overviewFrame: CGRect,
        searchQuery: String
    ) -> OverviewWindowItem {
        let matchesSearch = searchQuery.isEmpty ||
            windowData.title.localizedCaseInsensitiveContains(searchQuery) ||
            windowData.appName.localizedCaseInsensitiveContains(searchQuery)

        return OverviewWindowItem(
            handle: handle,
            windowId: windowData.entry.windowId,
            workspaceId: workspaceId,
            thumbnail: nil,
            title: windowData.title,
            appName: windowData.appName,
            appIcon: windowData.appIcon,
            originalFrame: windowData.frame,
            overviewFrame: overviewFrame,
            isHovered: false,
            isSelected: false,
            matchesSearch: matchesSearch,
            closeButtonHovered: false
        )
    }

    private static func totalContentHeight(currentY: CGFloat, context: BuildContext) -> CGFloat {
        let contentTop = context.searchBarFrame.minY - context.contentTopPadding
        let contentBottom = currentY + context.scaledWorkspaceSectionPadding - context.contentBottomPadding
        return contentTop - contentBottom
    }

    static func updateSearchFilter(layout: inout OverviewLayout, searchQuery: String) {
        for sectionIndex in layout.workspaceSections.indices {
            for windowIndex in layout.workspaceSections[sectionIndex].windows.indices {
                let window = layout.workspaceSections[sectionIndex].windows[windowIndex]
                let matches = searchQuery.isEmpty ||
                    window.title.localizedCaseInsensitiveContains(searchQuery) ||
                    window.appName.localizedCaseInsensitiveContains(searchQuery)
                layout.workspaceSections[sectionIndex].windows[windowIndex].matchesSearch = matches
            }
        }
    }

    static func scrollOffsetBounds(layout: OverviewLayout, screenFrame: CGRect) -> ClosedRange<CGFloat> {
        let metricsScale = clampedScale(layout.scale)
        let contentTop = layout.searchBarFrame.minY - OverviewLayoutMetrics.contentTopPadding * metricsScale
        let contentBottom = contentTop - layout.totalContentHeight
        let minOffset = min(0, contentBottom - screenFrame.minY)
        return minOffset ... 0
    }

    static func clampedScrollOffset(
        _ scrollOffset: CGFloat,
        layout: OverviewLayout,
        screenFrame: CGRect
    ) -> CGFloat {
        scrollOffset.clamped(to: scrollOffsetBounds(layout: layout, screenFrame: screenFrame))
    }

    static func findNextWindow(
        in layout: OverviewLayout,
        from currentHandle: WindowHandle?,
        direction: Direction
    ) -> WindowHandle? {
        let visibleWindows = layout.allWindows.filter(\.matchesSearch)
        guard !visibleWindows.isEmpty else { return nil }

        guard let currentHandle else {
            return visibleWindows.first?.handle
        }

        guard let currentIndex = visibleWindows.firstIndex(where: { $0.handle == currentHandle }) else {
            return visibleWindows.first?.handle
        }

        let currentWindow = visibleWindows[currentIndex]

        switch direction {
        case .left:
            let leftWindows = visibleWindows.filter {
                $0.overviewFrame.midX < currentWindow.overviewFrame.midX &&
                abs($0.overviewFrame.midY - currentWindow.overviewFrame.midY) < currentWindow.overviewFrame.height
            }.sorted { $0.overviewFrame.midX > $1.overviewFrame.midX }
            return leftWindows.first?.handle ?? findWrappedPrevious(in: visibleWindows, from: currentIndex)

        case .right:
            let rightWindows = visibleWindows.filter {
                $0.overviewFrame.midX > currentWindow.overviewFrame.midX &&
                abs($0.overviewFrame.midY - currentWindow.overviewFrame.midY) < currentWindow.overviewFrame.height
            }.sorted { $0.overviewFrame.midX < $1.overviewFrame.midX }
            return rightWindows.first?.handle ?? findWrappedNext(in: visibleWindows, from: currentIndex)

        case .up:
            let upWindows = visibleWindows.filter {
                $0.overviewFrame.midY > currentWindow.overviewFrame.midY
            }.sorted { lhs, rhs in
                let lhsYDiff = lhs.overviewFrame.midY - currentWindow.overviewFrame.midY
                let rhsYDiff = rhs.overviewFrame.midY - currentWindow.overviewFrame.midY
                let lhsXDiff = abs(lhs.overviewFrame.midX - currentWindow.overviewFrame.midX)
                let rhsXDiff = abs(rhs.overviewFrame.midX - currentWindow.overviewFrame.midX)
                if lhsYDiff < 100 && rhsYDiff < 100 {
                    return lhsXDiff < rhsXDiff
                }
                return lhsYDiff < rhsYDiff
            }
            if let closest = upWindows.first(where: {
                abs($0.overviewFrame.midX - currentWindow.overviewFrame.midX) < currentWindow.overviewFrame.width
            }) {
                return closest.handle
            }
            return upWindows.first?.handle

        case .down:
            let downWindows = visibleWindows.filter {
                $0.overviewFrame.midY < currentWindow.overviewFrame.midY
            }.sorted { lhs, rhs in
                let lhsYDiff = currentWindow.overviewFrame.midY - lhs.overviewFrame.midY
                let rhsYDiff = currentWindow.overviewFrame.midY - rhs.overviewFrame.midY
                let lhsXDiff = abs(lhs.overviewFrame.midX - currentWindow.overviewFrame.midX)
                let rhsXDiff = abs(rhs.overviewFrame.midX - currentWindow.overviewFrame.midX)
                if lhsYDiff < 100 && rhsYDiff < 100 {
                    return lhsXDiff < rhsXDiff
                }
                return lhsYDiff < rhsYDiff
            }
            if let closest = downWindows.first(where: {
                abs($0.overviewFrame.midX - currentWindow.overviewFrame.midX) < currentWindow.overviewFrame.width
            }) {
                return closest.handle
            }
            return downWindows.first?.handle
        }
    }

    private static func findWrappedNext(in windows: [OverviewWindowItem], from index: Int) -> WindowHandle? {
        let nextIndex = (index + 1) % windows.count
        return windows[nextIndex].handle
    }

    private static func findWrappedPrevious(in windows: [OverviewWindowItem], from index: Int) -> WindowHandle? {
        let prevIndex = (index - 1 + windows.count) % windows.count
        return windows[prevIndex].handle
    }
}
