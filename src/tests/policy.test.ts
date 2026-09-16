import { describe, expect, it } from 'vitest'
import { active, appError, domain, duration, ipv4, prefix, route } from '../lib/policy'

describe('IPv4 route editing', () => {
  it('normalizes both CIDR prefixes and subnet masks', () => {
    expect(route('10.42.17.255', '/16')).toEqual({ address: '10.42.0.0', prefix: 16 })
    expect(route('192.168.1.99', '255.255.255.0')).toEqual({ address: '192.168.1.0', prefix: 24 })
    expect(route('255.255.255.255', '32')).toEqual({ address: '255.255.255.255', prefix: 32 })
  })
  it('rejects malformed addresses, non-contiguous masks, and default routes', () => {
    for (const value of ['10.1.2', '256.1.1.1', '01.2.3.4', '::1', '1.2.3.-1']) expect(() => ipv4(value)).toThrow()
    for (const mask of ['33','255.0.255.0','255.255.1.0']) expect(() => prefix(mask)).toThrow()
    expect(() => route('0.0.0.0', '0')).toThrow('All IPv4')
  })
})
describe('DNS and session presentation', () => {
  it('normalizes DNS suffixes and rejects invalid labels', () => {
    expect(domain(' DEV.Example.COM. ')).toBe('dev.example.com')
    for (const invalid of ['', 'bad..test', '-dev.test', 'dev-.test', '10.1.2.3', '*.test']) expect(() => domain(invalid)).toThrow()
  })
  it('keeps failed sessions inactive and durations accurate', () => {
    expect(active('connected')).toBe(true)
    expect(active('reconnecting')).toBe(true)
    expect(active('error')).toBe(false)
    expect(duration(100, 3765)).toBe('01:01:05')
    expect(duration(null, 3765)).toBe('—')
    expect(appError({ code: 'auth', message: 'Rejected' })).toEqual({ code: 'auth', message: 'Rejected' })
  })
})
