import Foundation

/// Immutable menu state. Byte counters deliberately do not participate in menu
/// equality, so one-second traffic updates never replace an open menu.
struct MenuPresentation: Equatable, Sendable {
    enum Indicator: Sendable { case disconnected, connecting, connected }
    enum Action: Equatable, Sendable { case open, profile(String), disconnectAll, quit }
    struct Item: Equatable, Sendable {
        var title: String
        var action: Action
        var enabled: Bool
    }
    var indicator: Indicator
    var items: [Item]
    var tooltip: String {
        switch indicator {
        case .disconnected: "VueVPN — Disconnected"
        case .connecting: "VueVPN — Connecting"
        case .connected: "VueVPN — Connected"
        }
    }

    init(snapshot: Snapshot, busy: Bool = false, quitting: Bool = false,
         connectingID: String? = nil, disconnectingID: String? = nil) {
        let anyActive = snapshot.sessions.contains(where: \.active)
        let pending = connectingID != nil || disconnectingID != nil
        indicator = snapshot.sessions.contains { $0.status == .connected } ? .connected :
            anyActive || pending ? .connecting : .disconnected
        items = [Item(title: "Open VueVPN", action: .open, enabled: true)]
        for profile in snapshot.profiles {
            let session = snapshot.sessions.first { $0.profileId == profile.id }
            let status = session?.status
            let connecting = connectingID == profile.id || status == .connecting
            let disconnecting = disconnectingID == profile.id || status == .disconnecting
            let retry = session?.disconnectStalled == true && disconnectingID != profile.id
            let suffix = connecting ? "Connecting…" : retry ? "Retry disconnect" : disconnecting ? "Disconnecting…" :
                status?.active == true ? "Disconnect" : "Connect"
            items.append(Item(title: "\(profile.name)  ·  \(suffix)", action: .profile(profile.id),
                              enabled: !busy && !quitting && !connecting && (!disconnecting || retry)))
        }
        items.append(Item(title: "Disconnect All", action: .disconnectAll, enabled: anyActive && !busy && !quitting))
        items.append(Item(title: "Quit VueVPN", action: .quit, enabled: !busy && !quitting))
    }
}

/// Same double-V, dimensions, supersampling and Float arithmetic as the existing
/// menu icon. Straight RGBA bytes; AppKit must not reinterpret them as premultiplied.
enum StatusIcon {
    static let width = 44, height = 36
    static func rgba(_ indicator: MenuPresentation.Indicator) -> [UInt8] {
        let color: [UInt8]
        switch indicator {
        case .connected: color = [48, 143, 77]
        case .connecting: color = [176, 140, 61]
        case .disconnected: color = [139, 145, 135]
        }
        let segments: [(Float, Float, Float, Float)] = [
            (6, 10, 20, 32), (20, 32, 34, 10), (14, 10, 20, 20), (20, 20, 26, 10),
        ]
        let scale = Float(28)/Float(height)
        var pixels = [UInt8](repeating: 0, count: width*height*4)
        for y in 0..<height {
            for x in 0..<width {
                var coverage = 0
                for sy in 0..<4 {
                    for sx in 0..<4 {
                        let px = 20+(Float(x)+(Float(sx)+0.5)/4-Float(width)/2)*scale
                        let py = 21+(Float(y)+(Float(sy)+0.5)/4-Float(height)/2)*scale
                        if segments.contains(where: { ax, ay, bx, by in
                            let dx = bx-ax, dy = by-ay
                            let t = min(1, max(0, ((px-ax)*dx+(py-ay)*dy)/(dx*dx+dy*dy)))
                            let ex = px-ax-t*dx, ey = py-ay-t*dy
                            return ex*ex+ey*ey <= 4
                        }) { coverage += 1 }
                    }
                }
                if coverage > 0 {
                    let i = (y*width+x)*4
                    pixels[i] = color[0]; pixels[i+1] = color[1]; pixels[i+2] = color[2]
                    pixels[i+3] = UInt8((coverage*255+8)/16)
                }
            }
        }
        return pixels
    }
}
