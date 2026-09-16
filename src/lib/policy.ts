import type { Route, SessionStatus } from './types'

export function ipv4(value: string): number {
  if (!/^(0|[1-9]\d{0,2})(\.(0|[1-9]\d{0,2})){3}$/.test(value)) throw new Error('Enter a valid IPv4 address.')
  const parts = value.split('.').map(Number)
  if (parts.some(p => p > 255)) throw new Error('IPv4 values must be between 0 and 255.')
  return parts.reduce((total, part) => (total * 256 + part) >>> 0, 0)
}
export function prefix(value: string): number {
  const text = value.trim().replace(/^\//, '')
  if (/^\d{1,2}$/.test(text) && Number(text) <= 32) return Number(text)
  const mask = ipv4(text)
  let ones = 0
  for (let bit = 31; bit >= 0 && ((mask >>> bit) & 1); bit--) ones++
  const expected = ones === 0 ? 0 : (0xffffffff << (32 - ones)) >>> 0
  if (mask !== expected) throw new Error('Subnet mask must be contiguous, for example 255.255.255.0.')
  return ones
}
export function route(address: string, subnet: string): Route {
  const length = prefix(subnet)
  if (length === 0) throw new Error('Choose All IPv4 traffic to route everything through the VPN.')
  const network = (ipv4(address.trim()) & (0xffffffff << (32 - length))) >>> 0
  return { address: [24,16,8,0].map(shift => (network >>> shift) & 255).join('.'), prefix: length }
}
export function domain(value: string): string {
  const d = value.trim().replace(/\.$/, '').toLowerCase()
  if (d.length > 253 || !d.split('.').every(label => /^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/.test(label)) || /^\d+\.\d+\.\d+\.\d+$/.test(d)) throw new Error('Enter a domain such as dev.example.com.')
  return d
}
export const active = (status?: SessionStatus): boolean => !!status && ['connecting','connected','reconnecting','disconnecting'].includes(status)
export const statusLabel = (status?: SessionStatus): string => ({ disconnected: 'Ready to connect', awaiting_credentials: 'PIN required', connecting: 'Connecting…', connected: 'Connected', reconnecting: 'Reconnecting…', disconnecting: 'Disconnecting…', error: 'Connection failed' })[status ?? 'disconnected']
export function duration(since: number | null | undefined, now: number): string {
  if (!since) return '—'
  const seconds = Math.max(0, Math.floor(now - since))
  return [Math.floor(seconds / 3600), Math.floor(seconds / 60) % 60, seconds % 60].map(n => String(n).padStart(2, '0')).join(':')
}
export function appError(error: unknown): { code: string; message: string } {
  if (error && typeof error === 'object' && 'message' in error) return { code: 'code' in error ? String(error.code) : 'error', message: String(error.message) }
  return { code: 'error', message: typeof error === 'string' ? error : 'The operation could not be completed.' }
}
