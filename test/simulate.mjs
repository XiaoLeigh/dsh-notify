/**
 * Offline simulation: feeds synthetic session events into the plugin and prints
 * the toasts it would raise. Run with:
 *   DSH_NOTIFY_DRY_RUN=1 node test/simulate.mjs
 */
import { apply } from '../lib/index.js'

let handler = null
const ctx = {
  on(type, fn) {
    if (type === 'session/event') handler = fn
    return () => { handler = null }
  },
}

apply(ctx, { title: 'DSH' })

if (typeof handler !== 'function') {
  console.error('FAIL: plugin did not register a session/event listener')
  process.exit(1)
}

const now = Date.now
let clock = 1_700_000_000_000
Date.now = () => clock

const root = { header: { id: 'root-1' } }
const sub = { header: { id: 'sub-1', origin: 'subagent', parentSession: 'root-1' } }

const send = (session, type, data) => handler(session, { type, data })
const advance = (ms) => { clock += ms }

console.log('--- expect: notify (approval)')
send(root, 'approval/asked', { id: 'a1', toolName: 'pwsh', reason: 'sandbox escalation' })

console.log('--- expect: notify (question)')
send(root, 'tool/call', { callId: 'c1', name: 'ask_user_question' })

console.log('--- expect: notify (long completed turn)')
send(root, 'turn/start', { turn: 1 })
advance(95_000)
send(root, 'turn/end', { turn: 1, reason: { kind: 'completed' } })

console.log('--- expect: silent (short completed turn)')
send(root, 'turn/start', { turn: 2 })
advance(3_000)
send(root, 'turn/end', { turn: 2, reason: { kind: 'completed' } })

console.log('--- expect: notify (failed turn)')
send(root, 'turn/start', { turn: 3 })
advance(4_000)
send(root, 'turn/end', { turn: 3, reason: { kind: 'error', error: { message: 'LLM 503 upstream unavailable', code: 'UPSTREAM' } } })

console.log('--- expect: notify (truncated)')
send(root, 'turn/start', { turn: 4 })
advance(30_000)
send(root, 'turn/end', { turn: 4, reason: { kind: 'max-tokens' } })

console.log('--- expect: notify (blocked)')
send(root, 'turn/start', { turn: 5 })
send(root, 'turn/end', { turn: 5, reason: { kind: 'blocked' } })

console.log('--- expect: silent (aborted by the human)')
send(root, 'turn/start', { turn: 6 })
advance(60_000)
send(root, 'turn/end', { turn: 6, reason: { kind: 'aborted', reason: 'user' } })

console.log('--- expect: silent (subagent session)')
send(sub, 'turn/start', { turn: 1 })
advance(120_000)
send(sub, 'turn/end', { turn: 1, reason: { kind: 'completed' } })
send(sub, 'approval/asked', { id: 'a2', toolName: 'pwsh' })

console.log('--- expect: no crash (malformed input)')
send(root, 'turn/end', undefined)
send(root, 'turn/end', { reason: null })
send({}, 'turn/end', { reason: { kind: 'completed' } })
send(null, 'turn/end', {})
handler(undefined, undefined)

Date.now = now
console.log('--- simulation finished without throwing')