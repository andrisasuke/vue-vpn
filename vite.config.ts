import { defineConfig } from 'vitest/config';
import vue from '@vitejs/plugin-vue';
export default defineConfig({
  plugins: [vue()], clearScreen: false,
  server: { host: '127.0.0.1', port: 1420, strictPort: true },
  test: { environment: 'happy-dom', include: ['src/**/*.test.ts'], restoreMocks: true },
});
