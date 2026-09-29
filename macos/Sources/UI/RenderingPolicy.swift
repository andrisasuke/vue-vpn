import AppKit

struct RenderingEnvironment:Equatable {
    var windowVisible = false
    var occluded = true
    var minimized = false
    var applicationHidden = false
    var displayAsleep = false
    var coveredByModal = false
    var panelVisible = false
    var overview = false
    var activeConnection = false
    var reduceMotion = false
    var lowPowerMode = false
    var rendersWorkspace:Bool { windowVisible && !occluded && !minimized && !applicationHidden && !displayAsleep && !coveredByModal }
    // Low Power Mode deliberately retains normal animation, per user preference.
    var animates:Bool { rendersWorkspace && overview && panelVisible && activeConnection && !reduceMotion }
}

extension WorkspacePresentation {
    /// Byte counters, clock and offscreen activity logs cannot change geometry.
    var structure:WorkspacePresentation {
        var value = self
        for index in value.snapshot.sessions.indices {
            value.snapshot.sessions[index].bytesIn = 0;value.snapshot.sessions[index].bytesOut = 0
            value.snapshot.sessions[index].connectedAt = nil
        }
        if screen != .activity { value.snapshot.logs = [] }
        return value
    }
}
