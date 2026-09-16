<script setup lang="ts">
import { computed, onBeforeUnmount, onMounted, ref } from 'vue'
import type { UnlistenFn } from '@tauri-apps/api/event'
import { backend } from './lib/backend'
import { active, appError, duration, statusLabel } from './lib/policy'
import { formatBytes } from './lib/traffic'
import type { Profile, ProfileUpdate, Snapshot } from './lib/types'
import IconSprite from './components/IconSprite.vue'
import Icon from './components/Icon.vue'
import Modal from './components/Modal.vue'
import CredentialsDialog from './components/CredentialsDialog.vue'
import ProfileSettings from './components/ProfileSettings.vue'

const state = ref<Snapshot>({ profiles: [], sessions: [], helper: { status: 'loading', message: 'Checking VPN helper…' }, logs: [] })
const selectedId = ref(''), screen = ref<'overview' | 'activity' | 'setup'>('overview')
const modal = ref<'credentials' | 'settings' | 'delete' | null>(null), modalId = ref('')
const error = ref(''), modalError = ref(''), busy = ref(false), loaded = ref(false)
const connectingId = ref<string | null>(null)
const clock = ref(Date.now() / 1000), toast = ref('')
const selected = computed(() => state.value.profiles.find(p => p.id === selectedId.value))
const modalProfile = computed(() => state.value.profiles.find(p => p.id === modalId.value))
const session = computed(() => state.value.sessions.find(s => s.profileId === selectedId.value))
const connectedCount = computed(() => state.value.sessions.filter(s => s.status === 'connected').length)
const activeCount = computed(() => state.value.sessions.filter(s => active(s.status)).length)
const isActive = computed(() => active(session.value?.status))
const isConnecting = computed(() => connectingId.value === selectedId.value || session.value?.status === 'connecting')
const connectionButtonDisabled = computed(() => busy.value || isConnecting.value || session.value?.status === 'disconnecting')
const connectionButtonLabel = computed(() => isConnecting.value ? 'Connecting…' : session.value?.status === 'disconnecting' ? 'Disconnecting…' : isActive.value ? 'Disconnect' : 'Connect to VPN')
const trafficIn = computed(() => formatBytes(isActive.value ? session.value?.bytesIn ?? 0 : 0))
const trafficOut = computed(() => formatBytes(isActive.value ? session.value?.bytesOut ?? 0 : 0))
const trafficLabel = computed(() => `Received ${trafficIn.value.value}${trafficIn.value.unit || ' B'} / Sent ${trafficOut.value.value}${trafficOut.value.unit || ' B'}`)
let timer: ReturnType<typeof setInterval> | undefined, toastTimer: ReturnType<typeof setTimeout> | undefined
let disposed = false
const unlisten: UnlistenFn[] = []
function accept(snapshot: Snapshot) { state.value = snapshot; if (!snapshot.profiles.some(p => p.id === selectedId.value)) selectedId.value = snapshot.profiles[0]?.id ?? ''; loaded.value = true }
function notify(message: string) { toast.value = message; clearTimeout(toastTimer); toastTimer = setTimeout(() => toast.value = '', 4500) }
function openModal(kind: typeof modal.value, p: Profile) { modalError.value = ''; modalId.value = p.id; modal.value = kind }
function closeModal() { if (!busy.value) { modal.value = null; modalId.value = ''; modalError.value = '' } }
async function refresh() { accept(await backend.snapshot()) }
async function perform(action: () => Promise<void>, inModal = false): Promise<boolean> {
  if (busy.value) return false
  busy.value = true; error.value = ''; modalError.value = ''
  try { await action(); return true } catch (e) { (inModal ? modalError : error).value = appError(e).message; return false } finally { busy.value = false }
}
async function importProfile() { await perform(async () => { const id = await backend.import(); if (id) { await refresh(); selectedId.value = id; screen.value = 'overview'; notify('Profile imported. Ready when you are.'); } }) }
async function startConnection(id: string, password: string | null, remember: boolean) {
  connectingId.value = id
  try { await backend.connect(id, password, remember); await refresh() }
  finally { connectingId.value = null }
}
async function connect(p: Profile) {
  if (busy.value) return
  error.value = ''
  if (state.value.helper.status !== 'enabled') { screen.value = 'setup'; return }
  if (p.authKind !== 'certificate' && !p.remembered) { openModal('credentials', p); return }
  busy.value = true
  try { await startConnection(p.id, null, false) }
  catch (e) { const failure = appError(e); if (['credentials_required','keychain'].includes(failure.code)) openModal('credentials', p); else error.value = failure.message }
  finally { busy.value = false }
}
async function submitCredentials(password: string, remember: boolean) {
  const id = modalId.value
  const ok = await perform(() => startConnection(id, password, remember), true)
  password = ''
  if (ok) closeModal()
}
async function toggle() { const p = selected.value; if (!p || connectionButtonDisabled.value) return; if (isActive.value) await perform(async () => { await backend.disconnect(p.id); await refresh() }); else await connect(p) }
async function saveProfile(update: ProfileUpdate) { const id = modalId.value; if (await perform(async () => { await backend.update(id, update); await refresh() }, true)) { closeModal(); notify('Profile settings saved.'); } }
async function forget() { const id = modalId.value; await perform(async () => { await backend.forget(id); await refresh(); notify('Saved password removed from Keychain.') }, true) }
async function deleteProfile() { const id = modalId.value; if (await perform(async () => { await backend.delete(id); await refresh() }, true)) closeModal() }
async function helperAction(operation: string) { await perform(async () => { state.value.helper = await backend.helper(operation); if (operation !== 'settings') await refresh() }) }
async function disconnectAll() { await perform(async () => { await backend.disconnectAll(); await refresh() }) }
function profileStatus(id: string) { return state.value.sessions.find(s => s.profileId === id)?.status }

onMounted(async () => {
  timer = setInterval(() => clock.value = Date.now() / 1000, 1000)
  const register = async (subscription: Promise<UnlistenFn>) => { const fn = await subscription; if (disposed) fn(); else unlisten.push(fn) }
  try {
    await Promise.all([
      register(backend.onSnapshot(accept)),
      register(backend.onCredentials(id => { const p = state.value.profiles.find(p => p.id === id); if (p) { selectedId.value = id; screen.value = 'overview'; openModal('credentials', p) } })),
      register(backend.onError(e => error.value = e.message)),
    ])
    await refresh()
  } catch (e) { loaded.value = true; error.value = appError(e).message }
})
onBeforeUnmount(() => { disposed = true; unlisten.forEach(fn => fn()); clearInterval(timer); clearTimeout(toastTimer) })
</script>

<template>
  <IconSprite />
  <div class="app">
    <aside class="sidebar" aria-label="VPN profiles">
      <div class="brand"><Icon name="brand" class="brand-mark" /><div class="brand-word">VueVPN</div></div>
      <div class="nav-label">WORKSPACE</div>
      <nav class="nav-group">
        <button class="nav-btn" :class="{ active: screen === 'overview' }" @click="screen = 'overview'"><Icon name="grid" />Overview<span class="count">{{ state.profiles.length }}</span></button>
        <button class="nav-btn" :class="{ active: screen === 'activity' }" @click="screen = 'activity'"><Icon name="activity" />Activity</button>
        <button class="nav-btn" :class="{ active: screen === 'setup' }" @click="screen = 'setup'"><Icon name="laptop" />App settings</button>
      </nav>
      <div class="profile-section"><div class="section-label"><span>YOUR PROFILES</span><button class="tiny-btn" aria-label="Import profile" :disabled="busy" @click="importProfile"><Icon name="plus" /></button></div>
        <div class="profiles"><button v-for="p in state.profiles" :key="p.id" class="profile" :class="{ selected: selectedId === p.id, 'profile-connected': profileStatus(p.id) === 'connected' }" :aria-pressed="selectedId === p.id" @click="selectedId = p.id; screen = 'overview'"><span class="profile-avatar"><Icon name="server" /></span><span class="profile-text"><strong>{{ p.name }}</strong><small>{{ statusLabel(profileStatus(p.id)) }}</small></span><i class="profile-indicator" :class="{ online: profileStatus(p.id) === 'connected' }" /></button></div>
        <p v-if="!state.profiles.length" class="sidebar-empty">Your imported networks will appear here.</p>
        <button class="import-btn" :disabled="busy" @click="importProfile"><Icon name="upload" /><span>Import .ovpn profile</span></button>
      </div>
    </aside>
    <main class="main">
      <header class="topbar" data-tauri-drag-region><span class="breadcrumb">Workspace<Icon name="chevron" /><strong>{{ screen === 'overview' ? 'Overview' : screen === 'activity' ? 'Activity' : 'App settings' }}</strong></span><span class="state-pill" :class="{ 'status-online': connectedCount }"><i class="tiny-dot" />{{ connectedCount ? `${connectedCount} connected` : 'No active connection' }}</span></header>
      <div class="content">
        <div v-if="error" class="error-banner" role="alert"><div class="flex-between"><span>{{ error }}</span><button class="icon-button" aria-label="Dismiss error" @click="error = ''"><Icon name="close" /></button></div></div>
        <div v-if="!loaded" class="loading">Loading your workspace…</div>
        <template v-else-if="screen === 'overview'">
          <div v-if="state.helper.status !== 'enabled'" class="helper-banner"><Icon name="info" /><span>{{ state.helper.message }}</span><button class="text-button" @click="screen = 'setup'">View details<Icon name="arrow" /></button></div>
          <template v-if="selected">
            <div class="page-heading"><div><div class="eyebrow">YOUR NETWORK</div><h1>{{ selected.name }}</h1><div class="profile-meta"><Icon name="server" /><span>{{ selected.server }}</span><span class="tag">{{ selected.protocol.toUpperCase() }}</span></div></div><div class="heading-actions"><button class="text-button" :disabled="busy" @click="openModal('settings', selected)"><Icon name="edit" />Edit profile</button><button class="icon-button delete-button" aria-label="Delete profile" :disabled="busy" @click="openModal('delete', selected)"><Icon name="trash" /></button></div></div>
            <section class="connection" :class="{ connected: session?.status === 'connected', connecting: isConnecting || (isActive && session?.status !== 'connected') }" aria-label="VPN connection status">
              <div class="connection-body"><div class="connection-copy"><div class="status-badge" role="status"><span class="status-dot" />{{ statusLabel(isConnecting ? 'connecting' : session?.status) }}</div>
                <h2 v-if="session?.status === 'connected'">Your workspace.<br />Within reach.</h2><h2 v-else-if="isActive || isConnecting">Bringing your<br />network closer.</h2><h2 v-else>Your workspace.<br />One connection away.</h2>
                <p>{{ session?.status === 'connected' ? 'Connected securely to your private network.' : selected.authKind === 'pin' ? 'A familiar network, wherever you are. Connect with your profile PIN.' : 'Connect securely with your OpenVPN profile.' }}</p>
                <div class="connect-actions"><button class="button primary" :disabled="connectionButtonDisabled" :aria-busy="isConnecting || session?.status === 'disconnecting'" @click="toggle"><Icon name="power" />{{ connectionButtonLabel }}</button></div>
              </div>
              <div class="network-art">
                <div class="network-visual" aria-hidden="true">
                  <svg class="network-canvas" viewBox="0 0 335 254" preserveAspectRatio="xMidYMid meet">
                    <circle class="network-ring outer" cx="167" cy="127" r="110" /><circle class="network-ring" cx="167" cy="127" r="80" /><circle class="network-ring" cx="167" cy="127" r="51" />
                    <path class="network-path" d="M32 55 167 127M303 55 167 127M32 199 167 127M303 199 167 127" />
                    <circle class="network-node" cx="32" cy="55" r="11" /><circle class="network-node" cx="303" cy="55" r="11" /><circle class="network-node" cx="32" cy="199" r="11" /><circle class="network-node" cx="303" cy="199" r="11" />
                  </svg>
                  <div class="network-mark"><Icon name="brand" /></div>
                </div>
                <div class="network-traffic" role="group" :aria-label="trafficLabel" :title="trafficLabel">
                  <div class="traffic-amounts" aria-hidden="true"><span class="traffic-amount"><strong>{{ trafficIn.value }}</strong><small v-if="trafficIn.unit">{{ trafficIn.unit }}</small></span><span class="traffic-divider">/</span><span class="traffic-amount"><strong>{{ trafficOut.value }}</strong><small v-if="trafficOut.unit">{{ trafficOut.unit }}</small></span></div>
                  <div class="traffic-label" aria-hidden="true"><span>IN</span><span class="traffic-label-divider">/</span><span>OUT</span></div>
                </div>
              </div>
              </div>
              <div class="connection-stats"><div class="stat"><div class="stat-label"><Icon name="globe" />VPN address</div><div class="stat-value mono">{{ session?.address || 'Not assigned' }}</div></div><div class="stat"><div class="stat-label"><Icon name="clock" />Session duration</div><div class="stat-value mono">{{ duration(session?.connectedAt, clock) }}</div></div><div class="stat"><div class="stat-label"><Icon name="shield" />Connection protocol</div><div class="stat-value">OpenVPN<span class="soft-dot" />{{ selected.protocol.toUpperCase() }}</div></div></div>
            </section>
            <p v-if="session?.error" class="session-error" role="alert">{{ session.error }}</p>
            <p v-if="session?.status === 'reconnecting'" class="body-caption">Retry {{ session.attempts }} of 5. Waiting pauses when the network is unavailable.</p>
            <section class="routing"><div class="section-heading"><div><h2><Icon name="route" />Traffic routing</h2><p>Choose which IPv4 traffic uses this connection.</p></div><button class="text-button" @click="openModal('settings', selected)">Manage routes<Icon name="arrow" /></button></div>
              <div class="route-modes"><button class="mode" :aria-checked="selected.routingMode === 'all'" role="radio" @click="openModal('settings', selected)"><i class="radio-mark" /><span><strong>All IPv4 traffic<span class="default-tag">DEFAULT</span></strong><small>Outgoing IPv4 traffic uses the VPN.</small></span></button><button class="mode" :aria-checked="selected.routingMode === 'selected'" role="radio" @click="openModal('settings', selected)"><i class="radio-mark" /><span><strong>Selected networks</strong><small>Only specific IP addresses and subnets.</small></span></button></div>
              <div class="route-detail"><template v-if="selected.routingMode === 'selected'"><div class="table-heading"><strong>VPN routes <span>{{ selected.routes.length }}</span></strong><span class="body-caption">IPv4</span></div><table v-if="selected.routes.length" class="routes-table"><thead><tr><th>Network address</th><th>Subnet</th><th>Destination</th></tr></thead><tbody><tr v-for="r in selected.routes" :key="`${r.address}/${r.prefix}`"><td>{{ r.address }}</td><td>/{{ r.prefix }}</td><td><span class="route-type">Via VPN</span></td></tr></tbody></table><p v-else class="empty-routes">Add the networks you want to reach through this VPN.</p></template><div v-else class="full-tunnel"><span><Icon name="globe" /></span><div><h3>Your IPv4 traffic, through one connection.</h3><p>Only one profile can use this mode at a time. Other profiles can connect with specific routes.</p><code>0.0.0.0/0 → VPN</code></div></div></div>
              <p class="route-note"><Icon name="info" />{{ selected.routingMode === 'selected' ? 'Other IPv4 traffic uses your regular network.' : 'VPN transport traffic keeps using your physical network.' }} IPv6 is unchanged.</p>
            </section>
            <p v-for="warning in selected.warnings" :key="warning" class="warning-text">{{ warning }}</p>
          </template>
          <section v-else class="welcome"><div class="welcome-icon"><Icon name="brand" /></div><div class="eyebrow">A LITTLE CLOSER TO YOUR NETWORK</div><h1>Your workspace.<br />Wherever you are.</h1><p>Import your OpenVPN profile, choose your routes,<br />and connect to the networks that matter.</p><button class="button primary" :disabled="busy" @click="importProfile"><Icon name="upload" />Import .ovpn profile</button><small>Your profiles stay on this Mac.</small></section>
        </template>
        <template v-else-if="screen === 'activity'"><div class="page-heading"><div><div class="eyebrow">CONNECTION HISTORY</div><h1>Activity</h1><p class="body-caption">Session events from this app launch.</p></div><button class="button secondary" :disabled="busy || !activeCount" @click="disconnectAll">Disconnect all</button></div><div v-if="state.logs.length" class="activity-list"><div v-for="(entry, index) in [...state.logs].reverse()" :key="index" class="activity-entry"><span class="activity-icon"><Icon name="activity" /></span><div><strong>{{ state.profiles.find(p => p.id === entry.profileId)?.name || 'VueVPN' }}</strong><p>{{ entry.message }}</p><time>{{ new Date(entry.timestamp * 1000).toLocaleTimeString() }}</time></div></div></div><p v-else class="empty-routes">No activity yet. Your connection events will appear here.</p></template>
        <template v-else><div class="page-heading"><div><div class="eyebrow">MADE FOR YOUR MAC</div><h1>App settings</h1><p class="body-caption">Set up once, connect from anywhere in your menu bar.</p></div></div>
          <section class="setup-card"><span class="setup-icon"><Icon name="shield" /></span><h2>VPN helper</h2><p>{{ state.helper.message }}</p><span class="tag">{{ state.helper.status.replaceAll('_', ' ') }}</span><div class="buttons-row"><button v-if="['not_registered', 'not_found'].includes(state.helper.status)" class="button primary" :disabled="busy" @click="helperAction('register')">Enable VPN helper</button><button v-if="state.helper.status === 'unavailable'" class="button primary" :disabled="busy" @click="helperAction('retry_update')">Repair VPN helper</button><button v-if="state.helper.status === 'update_failed'" class="button primary" :disabled="busy" @click="helperAction('retry_update')">Retry helper update</button><button v-if="state.helper.status === 'update_pending'" class="button primary" :disabled="busy" @click="disconnectAll">Disconnect all and update</button><button class="button secondary" :disabled="busy || state.helper.status === 'updating'" @click="helperAction('settings')">Open macOS settings</button><button class="text-button" :disabled="busy" @click="helperAction('status')">Refresh status</button></div><p class="body-caption">Use the packaged VueVPN.app from /Applications. Helper updates install automatically when no VPN connections are active. If macOS requests approval, allow it in system settings.</p></section>
          <section class="settings-info"><h3>Always within reach</h3><p>Closing this window keeps VueVPN in your menu bar. Its icon turns green when a profile is connected. Choose a profile there to connect or disconnect.</p><h3>Your credentials stay yours</h3><p>Remembered PINs are saved in macOS Keychain after successful authentication. You can remove them in each profile’s settings.</p><h3>IPv4 only</h3><p>This version manages IPv4 traffic. IPv6 keeps using your existing network. There is no automatic connection at startup or kill switch.</p></section>
          <div class="settings-section"><button class="text-button delete-button" :disabled="busy || state.helper.status !== 'enabled'" @click="helperAction('unregister')">Disable helper and disconnect all</button></div>
        </template>
      </div>
      <footer class="footer"><div class="footer-left"><i />Private by design<span>·</span>IPv4</div><button @click="screen = 'activity'"><Icon name="terminal" />Connection activity</button></footer>
    </main>
  </div>
  <CredentialsDialog v-if="modal === 'credentials' && modalProfile" :key="modalProfile.id" :profile="modalProfile" :busy="busy" :error="modalError" @close="closeModal" @connect="submitCredentials" />
  <ProfileSettings v-if="modal === 'settings' && modalProfile" :key="modalProfile.id" :profile="modalProfile" :busy="busy" :error="modalError" :connected="active(profileStatus(modalProfile.id))" @close="closeModal" @save="saveProfile" @forget="forget" />
  <Modal v-if="modal === 'delete' && modalProfile" title="Remove this profile?" :busy="busy" @close="closeModal"><p class="dialog-subtitle">{{ modalProfile.name }} will be disconnected and removed from this Mac, together with its saved password. Your original .ovpn file is kept.</p><p v-if="modalError" class="form-error" role="alert">{{ modalError }}</p><div class="dialog-actions"><button class="button secondary" :disabled="busy" @click="closeModal">Cancel</button><button class="button danger" :disabled="busy" @click="deleteProfile">{{ busy ? 'Removing…' : 'Remove profile' }}</button></div></Modal>
  <div class="toast" :class="{ visible: toast }" role="status">{{ toast }}</div>
</template>
