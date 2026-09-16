<script setup lang="ts">
import { nextTick, onBeforeUnmount, onMounted, ref } from 'vue'
import Icon from './Icon.vue'
defineProps<{ title: string; busy?: boolean }>()
const emit = defineEmits<{ close: [] }>()
const panel = ref<HTMLElement>()
let previous: HTMLElement | null = null
function trap(event: KeyboardEvent) {
  if (event.key !== 'Tab') return
  const items = panel.value?.querySelectorAll<HTMLElement>('button:not(:disabled),input:not(:disabled),select:not(:disabled),textarea:not(:disabled),[tabindex="0"]')
  if (!items?.length) return
  const first = items[0], last = items[items.length - 1]
  if (event.shiftKey && document.activeElement === first) { event.preventDefault(); last?.focus() }
  else if (!event.shiftKey && document.activeElement === last) { event.preventDefault(); first?.focus() }
}
onMounted(async () => { previous = document.activeElement as HTMLElement; await nextTick(); (panel.value?.querySelector<HTMLElement>('[autofocus],input,textarea') ?? panel.value)?.focus() })
onBeforeUnmount(() => previous?.focus())
</script>
<template>
  <div class="modal-backdrop" @keydown.esc="!busy && emit('close')" @keydown="trap" @click.self="!busy && emit('close')">
    <section ref="panel" class="dialog-surface" role="dialog" aria-modal="true" :aria-label="title" tabindex="-1">
      <div class="dialog-content"><div class="dialog-title"><h2>{{ title }}</h2><button class="icon-button" aria-label="Close dialog" :disabled="busy" @click="emit('close')"><Icon name="close" /></button></div><slot /></div>
    </section>
  </div>
</template>
