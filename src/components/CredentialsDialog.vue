<script setup lang="ts">
import { ref } from 'vue'
import type { Profile } from '../lib/types'
import Modal from './Modal.vue'
import Icon from './Icon.vue'
const props = defineProps<{ profile: Profile; busy: boolean; error: string }>()
const emit = defineEmits<{ close: []; connect: [password: string, remember: boolean] }>()
const password = ref(''), remember = ref(false), visible = ref(false)
function submit() { if (!password.value || props.busy) return; const secret = password.value; password.value = ''; emit('connect', secret, remember.value) }
</script>
<template>
  <Modal :title="profile.authKind === 'pin' ? 'Enter your profile PIN' : 'Connect to your network'" :busy="busy" @close="emit('close')">
    <p class="dialog-subtitle">{{ profile.name }} <span v-if="profile.username">· {{ profile.username }}</span></p>
    <form @submit.prevent="submit">
      <label class="field"><span>{{ profile.authKind === 'pin' ? 'Profile PIN / password' : 'Password' }}</span><div class="password-wrap"><Icon name="lock" /><input v-model="password" :type="visible ? 'text' : 'password'" autocomplete="off" :disabled="busy" required autofocus maxlength="4096" /><button type="button" class="icon-button" :aria-label="visible ? 'Hide password' : 'Show password'" @click="visible = !visible"><Icon name="eye" /></button></div></label>
      <label v-if="profile.allowPasswordSave" class="remember-option"><input v-model="remember" type="checkbox" :disabled="busy" /><span><strong>Remember on this Mac</strong><small>Saved in macOS Keychain after a successful connection.</small></span></label>
      <p v-else class="body-caption">This profile does not allow passwords to be saved.</p>
      <p v-if="error" class="form-error" role="alert">{{ error }}</p>
      <div class="dialog-actions"><button type="button" class="button secondary" :disabled="busy" @click="emit('close')">Cancel</button><button class="button primary" :disabled="busy || !password"><Icon name="power" />{{ busy ? 'Connecting…' : 'Connect' }}</button></div>
    </form>
  </Modal>
</template>
