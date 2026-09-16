import { describe, expect, it } from 'vitest'
import { formatBytes } from '../lib/traffic'

describe('per-session byte presentation', () => {
  it.each([
    [0, '0', ''], [100, '100', 'B'], [999, '999', 'B'],
    [1000, '1', 'KB'], [100_000, '100', 'KB'],
    [1_500_000, '1.5', 'MB'], [10_000_000, '10', 'MB'],
    [5_000_000_000, '5', 'GB'], [1_500_000_000_000, '1.5', 'TB'],
    [999_950, '1', 'MB'],
  ])('formats %s bytes without unnecessary trailing decimals', (bytes, value, unit) => {
    expect(formatBytes(bytes)).toEqual({ value, unit })
  })
  it('keeps missing or invalid counters at zero', () => {
    for (const bytes of [NaN, Infinity, -1]) expect(formatBytes(bytes)).toEqual({ value: '0', unit: '' })
  })
})
