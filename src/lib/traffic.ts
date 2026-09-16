export interface ByteAmount { value: string; unit: string }

// Decimal units: 1 KB = 1,000 bytes. Keep the unit separate for typography.
export function formatBytes(bytes: number): ByteAmount {
  if (!Number.isFinite(bytes) || bytes <= 0) return { value: '0', unit: '' }
  const units = ['B', 'KB', 'MB', 'GB', 'TB', 'PB', 'EB'] as const
  let amount = Math.floor(bytes), index = 0
  while (amount >= 1000 && index < units.length - 1) { amount /= 1000; index++ }
  amount = Math.round(amount * 10) / 10
  if (amount >= 1000 && index < units.length - 1) { amount /= 1000; index++ }
  return { value: String(amount), unit: units[index]! }
}
