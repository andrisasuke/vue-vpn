import { invoke } from '@tauri-apps/api/core'
import { listen, type UnlistenFn } from '@tauri-apps/api/event'
import { open } from '@tauri-apps/plugin-dialog'
import type { AppError, HelperStatus, ProfileUpdate, Snapshot } from './types'

export const backend = {
  snapshot: () => invoke<Snapshot>('snapshot'),
  async import(): Promise<string | null> {
    const path = await open({ multiple: false, directory: false, title: 'Import an OpenVPN profile', filters: [{ name: 'OpenVPN profile', extensions: ['ovpn'] }] })
    return typeof path === 'string' ? invoke<string>('import_profile', { path }) : null
  },
  update: (id: string, update: ProfileUpdate) => invoke<void>('update_profile', { id, update }),
  delete: (id: string) => invoke<void>('delete_profile', { id }),
  connect: (id: string, password: string | null, remember: boolean) => invoke<void>('connect_profile', { id, password, remember }),
  disconnect: (id: string) => invoke<void>('disconnect_profile', { id }),
  disconnectAll: () => invoke<void>('disconnect_all'),
  forget: (id: string) => invoke<void>('forget_password', { id }),
  helper: (operation: string) => invoke<HelperStatus>('helper_action', { operation }),
  onSnapshot: (fn: (value: Snapshot) => void): Promise<UnlistenFn> => listen<Snapshot>('vpn-snapshot', e => fn(e.payload)),
  onCredentials: (fn: (id: string) => void): Promise<UnlistenFn> => listen<string>('vpn-credentials', e => fn(e.payload)),
  onError: (fn: (error: AppError) => void): Promise<UnlistenFn> => listen<AppError>('vpn-error', e => fn(e.payload)),
}
