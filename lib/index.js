/**
 * dsh-notify — host-side DeepSeek Harness plugin that raises a Windows toast
 * when a session needs the human or has finished a turn.
 *
 * It is deliberately defensive: every path is wrapped so a notification
 * failure can never fail the host boot or a session turn.
 */
import { spawn } from 'node:child_process'
import { fileURLToPath } from 'node:url'
import { dirname, join } from 'node:path'
import { createRequire } from 'node:module'
import { tmpdir } from 'node:os'
import { appendFileSync, statSync } from 'node:fs'

export const name = 'dsh-notify'

const SCRIPT = join(dirname(fileURLToPath(import.meta.url)), 'win-notify.ps1')
const POWERSHELL = 'C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe'
const LOG = join(tmpdir(), 'dsh-notify.log')

/**
 * Pick the notification sound, in order:
 *   1. `DSH_NOTIFY_SOUND` - an explicit path you provide.
 *   2. `assets/codex-notification.wav` - optional local drop-in (that file is
 *      OpenAI's, so it is git-ignored and never redistributed).
 *   3. `assets/chime.wav` - the bundled two-note chime that ships with this
 *      package (synthesised for this project, MIT-clean).
 *   4. `../dsh-task-completion-toast/assets/codex-notification.wav` - if that
 *      other plugin happens to sit in the same profile.
 * Returns '' when nothing matches; the script then uses the system sound.
 */
function notificationSound() {
  const pkg = dirname(dirname(fileURLToPath(import.meta.url)))
  const candidates = [
    process.env.DSH_NOTIFY_SOUND ?? '',
    join(pkg, 'assets', 'codex-notification.wav'),
    join(pkg, 'assets', 'chime.wav'),
    join(dirname(pkg), 'dsh-task-completion-toast', 'assets', 'codex-notification.wav'),
  ]
  for (const candidate of candidates) {
    if (!candidate) continue
    try {
      if (statSync(candidate).size > 0) return candidate
    } catch {
      // try the next location
    }
  }
  return ''
}

/** undefined: not probed yet; null: unavailable; object: usable. */
let electronModule
let transportLogged = false

/** Tiny bounded breadcrumb trail for troubleshooting; never throws. */
function note(line) {
  try {
    if (statSync(LOG).size > 64 * 1024) return
  } catch {
    // log does not exist yet
  }
  try {
    appendFileSync(LOG, `${new Date().toISOString()} ${line}\n`)
  } catch {
    // logging is best effort only
  }
}

const DEFAULTS = {
  /** Completed turns shorter than this stay silent. 0 notifies every turn. */
  minSeconds: 20,
  /** default | chime | none */
  sound: 'default',
  /** Ask the human (approval prompts, ask_user_question). */
  notifyApproval: true,
  notifyQuestion: true,
  /** Turn outcomes. */
  notifyCompleted: true,
  notifyFailure: true,
  notifyTruncated: true,
  notifyBlocked: true,
  notifyAborted: false,
  /** Title shown on the toast. */
  title: 'DSH',
}

function finite(value, fallback) {
  const n = Number(value)
  return Number.isFinite(n) && n >= 0 ? n : fallback
}

function duration(ms) {
  if (ms === undefined || ms === null || !Number.isFinite(ms)) return undefined
  const total = Math.max(0, Math.round(ms / 1000))
  if (total < 60) return `${total}s`
  const minutes = Math.floor(total / 60)
  if (minutes < 60) return `${minutes}m${String(total % 60).padStart(2, '0')}s`
  return `${Math.floor(minutes / 60)}h${String(minutes % 60).padStart(2, '0')}m`
}

function oneLine(value, limit = 180) {
  const text = String(value ?? '').replace(/\s+/g, ' ').trim()
  return text.length > limit ? `${text.slice(0, limit - 1)}…` : text
}

/**
 * Electron's own Notification, when the host really is an Electron main
 * process. This is the only transport that shows up branded as DeepSeek
 * Harness; the PowerShell fallback cannot (an unpackaged process may not
 * create a WinRT toast notifier, so it uses a tray balloon instead).
 */
function electronNotify() {
  if (electronModule !== undefined) return electronModule
  electronModule = null
  try {
    const mod = createRequire(import.meta.url)('electron')
    const N = mod?.Notification
    if (typeof N === 'function' && (typeof N.isSupported !== 'function' || N.isSupported())) {
      electronModule = mod
    }
  } catch {
    // Not an Electron main process, or no such builtin here.
  }
  return electronModule
}

function showElectron(mod, title, body, sound) {
  const notification = new mod.Notification({ title, body, silent: sound === 'none' })
  notification.on('click', () => {
    try {
      const win = mod.BrowserWindow?.getAllWindows?.()[0]
      if (!win) return
      if (win.isMinimized()) win.restore()
      win.show()
      win.focus()
    } catch {
      // Clicking is a convenience; never let it throw.
    }
  })
  notification.show()
}

/** Fire-and-forget notification; never throws, never blocks the caller. */
function toast(title, body, sound) {
  if (process.env.DSH_NOTIFY_DRY_RUN === '1') {
    process.stdout.write(`[dsh-notify] ${title} | ${body} (${sound})\n`)
    return
  }

  const mod = electronNotify()
  if (mod) {
    try {
      showElectron(mod, title, body, sound)
      logTransport('electron')
      return
    } catch (error) {
      note(`electron show failed: ${error?.message ?? error}`)
    }
  }

  try {
    // Do NOT use `detached: true` here: on Windows the child is created but
    // killed within ~60ms, so the notification never appears. Without it the
    // child lives ~300ms, shows the toast and exits, which is what we want.
    const child = spawn(
      POWERSHELL,
      ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', SCRIPT,
        '-Title', title, '-Body', body, '-Sound', sound,
        '-IconPath', process.execPath, '-Wav', notificationSound()],
      { stdio: 'ignore', windowsHide: true },
    )
    logTransport('powershell')
    child.on('error', (error) => note(`spawn failed: ${error?.message ?? error}`))
    child.on('exit', (code) => {
      if (code) note(`powershell exit ${code}`)
    })
    child.unref()
  } catch (error) {
    note(`spawn threw: ${error?.message ?? error}`)
  }
}

/** Record which transport won, once per process. */
function logTransport(chosen) {
  if (transportLogged) return
  transportLogged = true
  note(`transport=${chosen} (electron=${process.versions.electron ?? 'none'}, type=${process.type ?? 'node'})`)
}

export function apply(ctx, config) {
  const cfg = { ...DEFAULTS, ...(config && typeof config === 'object' ? config : {}) }
  cfg.minSeconds = finite(cfg.minSeconds, DEFAULTS.minSeconds)
  const sound = ['default', 'chime', 'none'].includes(cfg.sound) ? cfg.sound : 'default'
  const title = oneLine(cfg.title, 40) || DEFAULTS.title

  /** sessionId -> epoch ms of its open turn */
  const openTurns = new Map()

  const emit = (body, kind = 'default') => {
    note(`notify ${oneLine(body, 60)}`)
    toast(title, oneLine(body), kind === 'ask' ? 'chime' : sound)
  }

  const handle = (session, event) => {
    const header = session?.header
    if (!header || typeof header !== 'object') return
    // Subagent sessions chatter; only the human-facing root session notifies.
    if (header.origin === 'subagent' || header.parentSession !== undefined) return
    const sessionId = header.id ?? session?.id ?? 'session'
    const data = event?.data
    if (!data || typeof data !== 'object') return

    switch (event.type) {
      case 'turn/start':
        openTurns.set(sessionId, Date.now())
        return
      case 'approval/asked': {
        if (!cfg.notifyApproval) return
        const tool = oneLine(data.toolName, 40) || 'a tool'
        const reason = oneLine(data.reason, 120)
        emit(`需要你批准：${tool}${reason ? ` · ${reason}` : ''}`, 'ask')
        return
      }
      case 'tool/call': {
        if (!cfg.notifyQuestion) return
        if (data.name !== 'ask_user_question') return
        emit('需要你回答一个问题', 'ask')
        return
      }
      case 'turn/end': {
        const startedAt = openTurns.get(sessionId)
        openTurns.delete(sessionId)
        const elapsedMs = startedAt === undefined ? undefined : Date.now() - startedAt
        const spent = duration(elapsedMs)
        const kind = typeof data.reason?.kind === 'string' ? data.reason.kind : 'completed'

        switch (kind) {
          case 'completed':
            if (!cfg.notifyCompleted) return
            if (elapsedMs !== undefined && elapsedMs < cfg.minSeconds * 1000) return
            emit(`任务完成${spent ? ` · 用时 ${spent}` : ''}`)
            return
          case 'max-tokens':
            if (!cfg.notifyTruncated) return
            emit(`输出达到上限被截断${spent ? ` · 用时 ${spent}` : ''}`, 'ask')
            return
          case 'blocked':
            if (!cfg.notifyBlocked) return
            emit('这一轮被拒绝了（blocked），没有继续执行', 'ask')
            return
          case 'aborted':
            if (!cfg.notifyAborted) return
            emit('这一轮被中止了')
            return
          case 'error':
          default: {
            if (!cfg.notifyFailure) return
            const message = oneLine(data.reason?.error?.message, 120)
            emit(`任务失败${message ? `：${message}` : ''}`, 'ask')
            return
          }
        }
      }
      default:
        return
    }
  }

  try {
    // Host-side session event stream: (session, event) like the other plugins read it.
    const dispose = ctx.on('session/event', (session, event) => {
      try {
        handle(session, event)
      } catch {
        // Never let notification bookkeeping disturb the event stream.
      }
    })
    if (typeof ctx.effect === 'function' && typeof dispose === 'function') {
      ctx.effect(() => dispose, 'dsh-notify: session event listener')
    }
    note(`loaded (minSeconds=${cfg.minSeconds}, electron=${process.versions.electron ?? 'none'}, type=${process.type ?? 'node'})`)
  } catch (error) {
    note(`registration failed: ${error?.message ?? error}`)
    // Registration failure disables notifications, not the harness.
  }
}