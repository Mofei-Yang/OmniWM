import Foundation
import OmniWMIPC

@MainActor
final class WorkspaceStore {
    var monitors: [Monitor]
    var monitorsById: [Monitor.ID: Monitor] = [:]
    var monitorsByName: [String: [Monitor]] = [:]
    var workspacesById: [WorkspaceDescriptor.ID: WorkspaceDescriptor] = [:]
    var workspaceIdByName: [String: WorkspaceDescriptor.ID] = [:]
    var disconnectedVisibleWorkspaceCache: [MonitorRestoreKey: WorkspaceDescriptor.ID] = [:]

    var cachedSortedWorkspaces: [WorkspaceDescriptor]?
    var cachedWorkspaceIdsByMonitor: [Monitor.ID: [WorkspaceDescriptor.ID]]?
    var cachedVisibleWorkspaceIds: Set<WorkspaceDescriptor.ID>?
    var cachedVisibleWorkspaceMap: [Monitor.ID: WorkspaceDescriptor.ID]?
    var cachedMonitorIdByVisibleWorkspace: [WorkspaceDescriptor.ID: Monitor.ID]?
    var cachedWorkspaceMonitorProjection: [WorkspaceDescriptor.ID: WorkspaceMonitorProjection]?

    init(monitors: [Monitor]) {
        self.monitors = monitors
    }

    func rebuildMonitorIndexes() {
        monitorsById = Dictionary(uniqueKeysWithValues: monitors.map { ($0.id, $0) })
        var byName: [String: [Monitor]] = [:]
        for monitor in monitors {
            byName[monitor.name, default: []].append(monitor)
        }
        for key in byName.keys {
            byName[key] = Monitor.sortedByPosition(byName[key] ?? [])
        }
        monitorsByName = byName
        invalidateProjectionCaches()
    }

    func invalidateProjectionCaches() {
        cachedWorkspaceMonitorProjection = nil
        cachedWorkspaceIdsByMonitor = nil
        cachedVisibleWorkspaceIds = nil
        cachedVisibleWorkspaceMap = nil
        cachedMonitorIdByVisibleWorkspace = nil
    }

    func sortedWorkspaces() -> [WorkspaceDescriptor] {
        if let cached = cachedSortedWorkspaces {
            return cached
        }
        let sorted = workspacesById.values.sorted { WorkspaceIDPolicy.sortsBefore($0.name, $1.name) }
        cachedSortedWorkspaces = sorted
        return sorted
    }
}
