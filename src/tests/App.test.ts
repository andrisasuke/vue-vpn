import { flushPromises, mount } from '@vue/test-utils'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import type { Profile, Session, Snapshot } from '../lib/types'

const mocks = vi.hoisted(() => ({ snapshot: vi.fn(), connect: vi.fn(), disconnect: vi.fn(), import: vi.fn(), update: vi.fn(), delete: vi.fn(), forget: vi.fn(), helper: vi.fn(), disconnectAll: vi.fn(), onSnapshot: vi.fn(), onCredentials: vi.fn(), onError: vi.fn() }))
vi.mock('../lib/backend', () => ({ backend: mocks }))
import App from '../App.vue'
const p: Profile = { id: 'p1', name: 'Development', authKind: 'pin', username: 'test', routingMode: 'selected', routes: [{ address: '10.0.0.0', prefix: 8 }], dns: { servers: [], domains: [] }, protocol: 'udp', server: 'vpn.example.test', allowPasswordSave: true, allowLegacyCipher: false, warnings: [], remembered: false }
let value: Snapshot
function connection(status: Session['status']): Session {
  return { profileId: p.id, sessionId: 's1', status, address: '', interface: '', connectedAt: null, attempts: 0, bytesIn: 0, bytesOut: 0, error: null, errorCode: null, effectiveRoutes: [], effectiveDns: { servers: [], domains: [] } }
}
async function publishConnection(status: Session['status']) {
  value.sessions = [connection(status)]
  mocks.onSnapshot.mock.calls[0]![0](structuredClone(value))
  await flushPromises()
}
beforeEach(() => {
  vi.clearAllMocks()
  value = { profiles: [structuredClone(p)], sessions: [], helper: { status: 'enabled', message: 'Ready' }, logs: [] }
  mocks.snapshot.mockImplementation(async () => structuredClone(value))
  for (const fn of [mocks.onSnapshot,mocks.onCredentials,mocks.onError]) fn.mockResolvedValue(() => {})
  mocks.connect.mockResolvedValue(undefined)
})
afterEach(() => vi.restoreAllMocks())
describe('desktop connection flow with a mocked native backend', () => {
  it('updates in/out totals from snapshots for the selected profile and clears them when disconnected', async () => {
    const second = { ...structuredClone(p), id: 'p2', name: 'Second VPN' }
    value.profiles.push(second)
    const wrapper = mount(App); await flushPromises()
    const totals = () => wrapper.find('.traffic-amounts').text()
    expect(totals()).toBe('0/0')
    expect(wrapper.text()).not.toContain('YOUR PRIVATE CONNECTION')
    expect(wrapper.find('.network-traffic').attributes('aria-label')).toBe('Received 0 B / Sent 0 B')

    value.sessions = [
      { ...connection('connected'), bytesIn: 100, bytesOut: 100_000 },
      { ...connection('connected'), profileId: second.id, sessionId: 's2', bytesIn: 5_000_000_000, bytesOut: 2000 },
    ]
    const publish = async () => { mocks.onSnapshot.mock.calls[0]![0](structuredClone(value)); await flushPromises() }
    await publish()
    expect(totals()).toBe('100B/100KB')
    expect(wrapper.findAll('.traffic-amount strong').map(n => n.text())).toEqual(['100', '100'])
    expect(wrapper.findAll('.traffic-amount small').map(n => n.text())).toEqual(['B', 'KB'])

    value.sessions[0]!.bytesIn = 1_500_000
    value.sessions[0]!.bytesOut = 10_000_000
    await publish()
    expect(totals()).toBe('1.5MB/10MB')
    await wrapper.findAll('.profiles .profile')[1]!.trigger('click')
    expect(totals()).toBe('5GB/2KB')
    await wrapper.findAll('.profiles .profile')[0]!.trigger('click')
    expect(totals()).toBe('1.5MB/10MB')
    value.sessions[0]!.status = 'reconnecting'
    await publish()
    expect(totals()).toBe('1.5MB/10MB')
    value.sessions[0]!.status = 'disconnected'
    await publish()
    expect(totals()).toBe('0/0')
    value.sessions[0] = { ...connection('connecting'), sessionId: 'new-session' }
    await publish()
    expect(totals()).toBe('0/0')
    expect(mocks.connect).not.toHaveBeenCalled()
    wrapper.unmount()
  })
  it.each(['remembered', 'certificate', 'pin'] as const)('keeps Connect disabled during the request and native handshake with %s authentication', async (auth) => {
    value.profiles[0]!.remembered = auth === 'remembered'
    if (auth === 'certificate') value.profiles[0]!.authKind = 'certificate'
    let finish!: () => void
    mocks.connect.mockImplementationOnce(() => new Promise<void>(resolve => { finish = resolve }))
    const wrapper = mount(App); await flushPromises()
    const button = wrapper.find<HTMLButtonElement>('.connect-actions button')
    await button.trigger('click')
    if (auth === 'pin') {
      expect(button.text()).toBe('Connect to VPN')
      await wrapper.find('input[type="password"]').setValue('test-pin')
      await wrapper.find('form').trigger('submit')
    }
    expect(button.text()).toBe('Connecting…')
    expect(button.element.disabled).toBe(true)
    expect(button.attributes('aria-busy')).toBe('true')
    expect(wrapper.find('.status-badge').text()).toBe('Connecting…')
    await button.trigger('click')
    expect(mocks.connect).toHaveBeenCalledOnce()
    expect(mocks.disconnect).not.toHaveBeenCalled()

    value.sessions = [connection('connecting')]
    finish(); await flushPromises()
    expect(wrapper.find('[role="dialog"]').exists()).toBe(false)
    expect(button.text()).toBe('Connecting…')
    expect(button.element.disabled).toBe(true)
    await button.trigger('click')
    expect(mocks.disconnect).not.toHaveBeenCalled()

    await publishConnection('connected')
    expect(button.text()).toBe('Disconnect')
    expect(button.element.disabled).toBe(false)
    expect(button.attributes('aria-busy')).toBe('false')
    mocks.disconnect.mockImplementationOnce(async () => { value.sessions = [connection('disconnecting')] })
    await button.trigger('click'); await flushPromises()
    expect(mocks.disconnect).toHaveBeenCalledWith(p.id)
    expect(button.text()).toBe('Disconnecting…')
    expect(button.element.disabled).toBe(true)
    await publishConnection('disconnected')
    expect(button.text()).toBe('Connect to VPN')
    expect(button.element.disabled).toBe(false)
    wrapper.unmount()
  })
  it('reenables Connect after a failed handshake and allows canceling automatic reconnect', async () => {
    value.sessions = [connection('connecting')]
    const wrapper = mount(App); await flushPromises()
    const button = wrapper.find<HTMLButtonElement>('.connect-actions button')
    expect(button.text()).toBe('Connecting…')
    expect(button.element.disabled).toBe(true)
    await publishConnection('error')
    expect(button.text()).toBe('Connect to VPN')
    expect(button.element.disabled).toBe(false)
    await publishConnection('reconnecting')
    expect(button.text()).toBe('Disconnect')
    expect(button.element.disabled).toBe(false)
    wrapper.unmount()
  })
  it('clears the pending Connect state when the native request is rejected', async () => {
    value.profiles[0]!.remembered = true
    mocks.connect.mockRejectedValueOnce({ code: 'helper_unavailable', message: 'Helper unavailable' })
    const wrapper = mount(App); await flushPromises()
    const button = wrapper.find<HTMLButtonElement>('.connect-actions button')
    await button.trigger('click'); await flushPromises()
    expect(button.text()).toBe('Connect to VPN')
    expect(button.element.disabled).toBe(false)
    expect(wrapper.find('.error-banner').text()).toContain('Helper unavailable')
    wrapper.unmount()
  })
  it.each([
    { status: 'updating', message: 'Updating the VPN helper…', button: null },
    { status: 'recovering', message: 'Reconnecting to the VPN helper…', button: null },
    { status: 'unavailable', message: 'Helper connection failed.', button: 'Repair VPN helper' },
    { status: 'update_pending', message: 'An update is ready after disconnecting.', button: 'Disconnect all and update' },
    { status: 'update_failed', message: 'Could not update the helper.', button: 'Retry helper update' },
  ])('presents helper $status without offering registration', async ({ status, message, button }) => {
    value.helper = { status, message }
    const wrapper = mount(App); await flushPromises()
    expect(wrapper.find('.helper-banner').text()).toContain(message)
    await wrapper.find('.helper-banner button').trigger('click')
    const card = wrapper.find('.setup-card')
    expect(card.text()).toContain(message)
    expect(card.text()).not.toContain('Enable VPN helper')
    if (button) {
      mocks.helper.mockResolvedValue(value.helper)
      await card.findAll('button').find(b => b.text() === button)!.trigger('click'); await flushPromises()
      if (status === 'update_failed' || status === 'unavailable') expect(mocks.helper).toHaveBeenCalledWith('retry_update')
      else expect(mocks.disconnectAll).toHaveBeenCalledOnce()
    }
    expect(mocks.connect).not.toHaveBeenCalled()
    wrapper.unmount()
  })
  it.each([
    { servers: [], domains: [] },
    { servers: ['10.0.0.53'], domains: ['dev.example.test'] },
  ])('preserves hidden DNS settings when editing a profile: $servers', async (dns) => {
    value.profiles[0]!.dns = structuredClone(dns)
    value.sessions = [{ profileId: p.id, sessionId: 's1', status: 'connected', address: '10.8.0.2', interface: 'utun9', connectedAt: 1, attempts: 0, bytesIn: 0, bytesOut: 0, error: null, errorCode: null, effectiveRoutes: p.routes, effectiveDns: { servers: ['10.0.0.54'], domains: ['pushed.example.test'] } }]
    const wrapper = mount(App); await flushPromises()
    expect(wrapper.text()).not.toContain('Internal DNS')
    expect(wrapper.text()).not.toContain('pushed.example.test')
    await wrapper.find('.heading-actions .text-button').trigger('click')
    const dialog = wrapper.find('[role="dialog"]')
    expect(dialog.text()).not.toContain('Internal DNS')
    expect(dialog.find('textarea').exists()).toBe(false)
    await dialog.find('input[maxlength="80"]').setValue('Renamed profile')
    await dialog.find('form').trigger('submit'); await flushPromises()
    expect(mocks.update).toHaveBeenCalledWith(p.id, expect.objectContaining({ name: 'Renamed profile', dns }))
    wrapper.unmount()
  })
  it('does not connect on launch, asks for a PIN, and never simulates a connected session', async () => {
    const wrapper = mount(App); await flushPromises()
    expect(mocks.connect).not.toHaveBeenCalled()
    await wrapper.find('.connect-actions button').trigger('click')
    expect(wrapper.find('[role="dialog"]').exists()).toBe(true)
    await wrapper.find('input[type="password"]').setValue('test-pin')
    await wrapper.find('form').trigger('submit'); await flushPromises()
    expect(mocks.connect).toHaveBeenCalledWith('p1', 'test-pin', false)
    expect(wrapper.find('.connection').classes()).not.toContain('connected')
    wrapper.unmount()
  })
  it('uses a remembered credential without sending a password from the webview', async () => {
    value.profiles[0]!.remembered = true
    const wrapper = mount(App); await flushPromises()
    await wrapper.find('.connect-actions button').trigger('click'); await flushPromises()
    expect(mocks.connect).toHaveBeenCalledWith('p1', null, false)
    expect(wrapper.find('[role="dialog"]').exists()).toBe(false)
    wrapper.unmount()
  })
  it('asks again when the saved credential cannot be accessed', async () => {
    value.profiles[0]!.remembered = true
    mocks.connect.mockRejectedValue({ code: 'keychain', message: 'Locked' })
    const wrapper = mount(App); await flushPromises()
    await wrapper.find('.connect-actions button').trigger('click'); await flushPromises()
    expect(wrapper.find('input[type="password"]').exists()).toBe(true)
    wrapper.unmount()
  })
  it('routes connect actions to setup when the helper is missing', async () => {
    value.helper.status = 'not_registered'
    const wrapper = mount(App); await flushPromises()
    await wrapper.find('.connect-actions button').trigger('click')
    expect(wrapper.find('.setup-card').exists()).toBe(true)
    expect(mocks.connect).not.toHaveBeenCalled()
    wrapper.unmount()
  })
})
