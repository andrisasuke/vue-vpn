import { mount } from '@vue/test-utils'
import { describe, expect, it } from 'vitest'
import CredentialsDialog from '../components/CredentialsDialog.vue'
import type { Profile } from '../lib/types'

export const profile: Profile = { id: 'p1', name: 'Development', authKind: 'pin', username: 'test', routingMode: 'selected', routes: [], dns: { servers: [], domains: [] }, protocol: 'udp', server: 'vpn.example.test', allowPasswordSave: true, allowLegacyCipher: false, warnings: [], remembered: false }
describe('PIN entry', () => {
  it('sends the remember preference explicitly and clears the input after submit', async () => {
    const wrapper = mount(CredentialsDialog, { props: { profile, busy: false, error: '' } })
    expect((wrapper.find('input[type="checkbox"]').element as HTMLInputElement).checked).toBe(false)
    await wrapper.find('input[type="password"]').setValue('synthetic-test-pin')
    await wrapper.find('input[type="checkbox"]').setValue(true)
    await wrapper.find('form').trigger('submit')
    expect(wrapper.emitted('connect')).toEqual([['synthetic-test-pin', true]])
    expect((wrapper.find('input[type="password"]').element as HTMLInputElement).value).toBe('')
    wrapper.unmount()
  })
  it('does not offer persistence when the profile forbids it', () => {
    const wrapper = mount(CredentialsDialog, { props: { profile: { ...profile, allowPasswordSave: false }, busy: false, error: '' } })
    expect(wrapper.find('input[type="checkbox"]').exists()).toBe(false)
    wrapper.unmount()
  })
})
