export type RoutingMode = 'all' | 'selected'
export type AuthKind = 'pin' | 'username_password' | 'certificate'
export type SessionStatus = 'disconnected' | 'awaiting_credentials' | 'connecting' | 'connected' | 'reconnecting' | 'disconnecting' | 'error'
export interface Route { address: string; prefix: number }
export interface DnsSettings { servers: string[]; domains: string[] }
export interface Profile {
  id: string; name: string; authKind: AuthKind; username: string
  routingMode: RoutingMode; routes: Route[]; dns: DnsSettings
  protocol: string; server: string; allowPasswordSave: boolean
  allowLegacyCipher: boolean; warnings: string[]; remembered: boolean
}
export type ProfileUpdate = Pick<Profile, 'name' | 'username' | 'routingMode' | 'routes' | 'dns' | 'allowLegacyCipher'>
export interface Session {
  profileId: string; sessionId: string; status: SessionStatus; address: string; interface: string
  connectedAt: number | null; attempts: number; error: string | null; errorCode: string | null
  bytesIn: number; bytesOut: number
  effectiveRoutes: Route[]; effectiveDns: DnsSettings
}
export interface HelperStatus { status: string; message: string }
export interface LogEntry { timestamp: number; profileId: string | null; message: string }
export interface Snapshot { profiles: Profile[]; sessions: Session[]; helper: HelperStatus; logs: LogEntry[] }
export interface AppError { code: string; message: string }
