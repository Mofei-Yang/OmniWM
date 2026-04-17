import Foundation

struct WorkspaceDescriptor: Identifiable, Hashable {
    typealias ID = UUID
    let id: ID
    var name: String
    var assignedMonitorPoint: CGPoint?

    init(name: String, assignedMonitorPoint: CGPoint? = nil) {
        id = UUID()
        self.name = name
        self.assignedMonitorPoint = assignedMonitorPoint
    }
}

struct WorkspaceMonitorProjection {
    var projectedMonitorId: Monitor.ID?
    var homeMonitorId: Monitor.ID?
    var effectiveMonitorId: Monitor.ID?
}
