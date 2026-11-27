import { fileURLToPath } from 'node:url';
import { defineConfig } from 'vitest/config';

export default defineConfig({
  resolve: { alias: { 'react-native': fileURLToPath(new URL('./src/__tests__/fakeReactNative.ts', import.meta.url)) } },
  test: { include: ['src/__tests__/**/*.test.ts'] },
});
