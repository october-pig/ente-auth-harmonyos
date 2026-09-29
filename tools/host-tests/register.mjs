/** register.mjs — installs the ArkTS resolution hook for the host harness. */
import { register } from 'node:module';

register('./hooks.mjs', import.meta.url);
