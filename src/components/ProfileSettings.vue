<script setup lang="ts">
import { reactive, ref } from 'vue'
import type { Profile, ProfileUpdate } from '../lib/types'
import { appError, route } from '../lib/policy'
import Modal from './Modal.vue'
import Icon from './Icon.vue'
const props = defineProps<{ profile: Profile; busy: boolean; error: string; connected: boolean }>()
const emit = defineEmits<{ close: []; save: [update: ProfileUpdate]; forget: [] }>()
const draft = reactive<ProfileUpdate>({ name: props.profile.name, username: props.profile.username, routingMode: props.profile.routingMode, routes: props.profile.routes.map(r => ({ ...r })), dns: { servers: [...props.profile.dns.servers], domains: [...props.profile.dns.domains] }, allowLegacyCipher: props.profile.allowLegacyCipher })
const address = ref(''), subnet = ref('24'), validation = ref('')
function addRoute() { try { const r = route(address.value, subnet.value); if (!draft.routes.some(item => item.address === r.address && item.prefix === r.prefix)) draft.routes.push(r); address.value = ''; validation.value = '' } catch (e) { validation.value = appError(e).message } }
function save() {
  try {
    if (address.value.trim()) { validation.value = 'Add the pending route or clear its address before saving.'; return }
    // Internal DNS is temporarily hidden. Keep saved settings when editing
    // visible fields so a profile edit cannot silently change its networking.
    emit('save', { ...draft, name: draft.name.trim(), routes: draft.routes.map(r => ({ ...r })), dns: { servers: [...draft.dns.servers], domains: [...draft.dns.domains] } })
  } catch (e) { validation.value = appError(e).message }
}
</script>
<template>
  <Modal title="Profile settings" :busy="busy" @close="emit('close')">
    <p class="dialog-subtitle">Your network, your routing rules.</p>
    <form @submit.prevent="save">
      <label class="field"><span>Profile name</span><input v-model="draft.name" required maxlength="80" :disabled="busy" /></label>
      <label v-if="profile.authKind !== 'certificate'" class="field"><span>Username</span><input v-model="draft.username" :required="profile.authKind === 'username_password'" maxlength="256" :disabled="busy" /></label>
      <div class="settings-section"><h3>IPv4 routing</h3><div class="route-modes">
        <button type="button" class="mode" role="radio" :aria-checked="draft.routingMode === 'all'" @click="draft.routingMode = 'all'"><i class="radio-mark" /><span><strong>All IPv4 traffic</strong><small>Route outgoing IPv4 via this VPN.</small></span></button>
        <button type="button" class="mode" role="radio" :aria-checked="draft.routingMode === 'selected'" @click="draft.routingMode = 'selected'"><i class="radio-mark" /><span><strong>Selected networks</strong><small>Only the subnets you choose.</small></span></button>
      </div></div>
      <div v-if="draft.routingMode === 'selected'" class="settings-section">
        <div class="route-list scroll-list"><div v-for="(r, i) in draft.routes" :key="`${r.address}/${r.prefix}`" class="route-item"><code>{{ r.address }}/{{ r.prefix }}</code><button type="button" class="icon-button" :aria-label="`Remove ${r.address}/${r.prefix}`" @click="draft.routes.splice(i, 1)"><Icon name="trash" /></button></div></div>
        <p v-if="!draft.routes.length" class="body-caption">No IPv4 networks selected yet.</p>
        <div class="route-fields"><label class="field"><span>IPv4 address</span><input v-model="address" placeholder="10.0.0.0" @keydown.enter.prevent="addRoute" /></label><label class="field"><span>Prefix or subnet mask</span><input v-model="subnet" placeholder="24 / 255.255.255.0" @keydown.enter.prevent="addRoute" /></label><button type="button" class="button secondary" aria-label="Add route" @click="addRoute"><Icon name="plus" /></button></div>
      </div>
      <label class="inline-check"><input v-model="draft.allowLegacyCipher" type="checkbox" />Allow AES-CBC compatibility for this profile</label>
      <div v-if="profile.remembered" class="credential-actions"><span>PIN/password saved in Keychain</span><button type="button" class="text-button" :disabled="busy" @click="emit('forget')">Forget password</button></div>
      <p v-if="connected" class="helper-message">Saving network changes reconnects this profile. Other profiles stay connected.</p>
      <p v-if="validation || error" class="form-error" role="alert">{{ validation || error }}</p>
      <div class="dialog-actions"><button type="button" class="button secondary" :disabled="busy" @click="emit('close')">Cancel</button><button class="button primary" :disabled="busy || !draft.name.trim()">{{ busy ? 'Saving…' : 'Save changes' }}</button></div>
    </form>
  </Modal>
</template>
