/**
 * Nova — VRM avatar frontend (three.js + @pixiv/three-vrm)
 *
 * Responsibilities:
 *  - Render a VRM avatar (CC0 sample model; MIT runtime — fully open source)
 *  - Maintain the 5-state machine driven by WebSocket messages from the Python server
 *  - Capture Space keydown/keyup and send ptt_start/ptt_stop to the server
 *  - Drive the 'aa' mouth expression from amplitude messages for lip-sync
 *  - Update sentence bubble, transcript flash, and background colour per state
 */

import './style.css'
import * as THREE from 'three'
import { GLTFLoader } from 'three/addons/loaders/GLTFLoader.js'
import { VRMLoaderPlugin, VRMUtils } from '@pixiv/three-vrm'

// ── Constants ─────────────────────────────────────────────────────────────
const WS_URL       = 'ws://localhost:8765'
const MODEL_PATH   = '/avatar/VIPEHero_2707.vrm'
const RECONNECT_MS = 2000

const STATE_LABELS = {
  idle:        'Hold SPACE to talk!',
  listening:   '🎤 Listening…',
  thinking:    '💭 Hmm…',
  speaking:    '',          // sentence bubble takes over
  didnt_catch: "I didn't hear you — try again?",
}

// ── DOM refs ──────────────────────────────────────────────────────────────
const canvasEl   = document.getElementById('canvas')
const bubbleEl   = document.getElementById('sentence-bubble')
const labelEl    = document.getElementById('state-label')
const transcriptEl = document.getElementById('transcript')

// ── App state ─────────────────────────────────────────────────────────────
let renderer  = null
let scene     = null
let camera    = null
let vrm       = null       // loaded three-vrm instance
let clock     = null
let ws        = null
let state     = 'idle'
let amplitude = 0          // smoothed lip-sync value
let targetAmp = 0
let stageReservePx = 0     // px reserved on the right for the transcript panel
let pttActive = false      // true while Space is held
let fadeTimer = null       // for bubble fade-out

// Target pose (radians) the tick loop eases the head/spine towards —
// applyState just sets targets, so transitions are always smooth.
const pose = { headPitch: 0, headRoll: 0, headYaw: 0, spinePitch: 0 }

// ── three.js setup ────────────────────────────────────────────────────────
function initThree() {
  renderer = new THREE.WebGLRenderer({
    canvas: canvasEl,
    alpha: true,           // transparent — CSS gradient shows through
    antialias: true,
  })
  renderer.setPixelRatio(window.devicePixelRatio)
  renderer.setSize(window.innerWidth, window.innerHeight)

  scene = new THREE.Scene()

  // Upper-body portrait framing (VRM models stand at the origin, ~1.5 m tall)
  camera = new THREE.PerspectiveCamera(
    28, window.innerWidth / window.innerHeight, 0.1, 20)
  camera.position.set(0.0, 1.32, 1.35)
  camera.lookAt(0.0, 1.28, 0.0)

  const key = new THREE.DirectionalLight(0xffffff, Math.PI * 0.9)
  key.position.set(0.6, 1.8, 1.2)
  scene.add(key)
  scene.add(new THREE.AmbientLight(0xfff2e8, Math.PI * 0.35))

  clock = new THREE.Clock()
  renderer.setAnimationLoop(onTick)
  window.addEventListener('resize', applyStageLayout)
}

function fitViewport() {
  // The avatar stage shrinks to the left when the transcript panel is docked
  // beside it, so the model stays fully visible instead of being covered.
  const w = Math.max(1, window.innerWidth - stageReservePx)
  camera.aspect = w / window.innerHeight
  camera.updateProjectionMatrix()
  renderer.setSize(w, window.innerHeight)
}

// ── Blink scheduler ───────────────────────────────────────────────────────
let nextBlinkAt = 2.0
let blinkPhase  = -1        // <0: not blinking; 0..1: closing→opening

function updateBlink(t, delta) {
  if (!vrm?.expressionManager) return
  if (blinkPhase < 0 && t >= nextBlinkAt) blinkPhase = 0
  if (blinkPhase >= 0) {
    blinkPhase += delta / 0.18   // full blink ≈ 180 ms
    const v = blinkPhase < 0.5 ? blinkPhase * 2 : Math.max(0, 2 - blinkPhase * 2)
    vrm.expressionManager.setValue('blink', Math.min(1, v))
    if (blinkPhase >= 1) {
      blinkPhase = -1
      nextBlinkAt = t + 2 + Math.random() * 4
    }
  }
}

// Per-frame update: lip-sync, pose easing, blink, VRM internals
function onTick() {
  const delta = clock.getDelta()
  const t = clock.elapsedTime

  // Smooth amplitude towards target
  amplitude += (targetAmp - amplitude) * 0.35
  targetAmp *= 0.88            // decay when no new messages arrive

  if (vrm) {
    // Lip-sync: VRM's standard 'aa' viseme expression
    vrm.expressionManager?.setValue(
      'aa', state === 'speaking' ? Math.min(1, amplitude * 1.4) : 0)

    updateBlink(t, delta)

    // Ease head/spine towards the state's target pose + gentle idle sway
    const head  = vrm.humanoid?.getNormalizedBoneNode('head')
    const spine = vrm.humanoid?.getNormalizedBoneNode('spine')
    const sway = Math.sin(t * 0.6) * 0.015          // breathing sway
    if (head) {
      head.rotation.x += (pose.headPitch - head.rotation.x) * 0.08
      head.rotation.y += (pose.headYaw + sway - head.rotation.y) * 0.08
      head.rotation.z += (pose.headRoll - head.rotation.z) * 0.08
    }
    if (spine) {
      spine.rotation.x += (pose.spinePitch + Math.sin(t * 0.9) * 0.008
                           - spine.rotation.x) * 0.06
    }

    vrm.update(delta)
  }

  renderer.render(scene, camera)
}

// ── VRM model loading ─────────────────────────────────────────────────────
async function loadModel() {
  const loader = new GLTFLoader()
  loader.register((parser) => new VRMLoaderPlugin(parser))

  let gltf
  try {
    gltf = await loader.loadAsync(MODEL_PATH)
  } catch (err) {
    console.error('[avatar] load failed:', err)
    showError(
      'Avatar model not found.<br>' +
      'Expected a VRM file at <b>ui/public' + MODEL_PATH + '</b> — see ui/README.md.'
    )
    return
  }

  vrm = gltf.userData.vrm
  // Perf helpers recommended by three-vrm
  VRMUtils.removeUnnecessaryVertices(gltf.scene)
  VRMUtils.combineSkeletons(gltf.scene)
  // VRM 0.x models face +Z; rotate to face the camera
  VRMUtils.rotateVRM0(vrm)

  scene.add(vrm.scene)

  // Relax the default T-pose: lower both arms to the sides
  for (const side of ['left', 'right']) {
    const upperArm = vrm.humanoid?.getNormalizedBoneNode(`${side}UpperArm`)
    if (upperArm) upperArm.rotation.z = side === 'left' ? 1.15 : -1.15
  }

  applyState('idle')
}

// ── State machine ─────────────────────────────────────────────────────────
// Sets pose targets (eased per frame in onTick) and VRM expressions per state.
let didntCatchTimer = null

function setExpression(name, value) {
  try { vrm?.expressionManager?.setValue(name, value) } catch { /* absent */ }
}

function resetExpressions() {
  for (const n of ['happy', 'sad', 'surprised', 'relaxed']) setExpression(n, 0)
}

function applyState(newState) {
  state = newState

  // Background tint via body class
  document.body.className = newState === 'idle' || newState === 'speaking' ? '' : newState

  // State label
  labelEl.textContent = STATE_LABELS[newState] ?? ''

  if (!vrm) return
  if (didntCatchTimer) { clearTimeout(didntCatchTimer); didntCatchTimer = null }
  resetExpressions()

  switch (newState) {
    case 'idle':
      Object.assign(pose, { headPitch: 0, headRoll: 0, headYaw: 0, spinePitch: 0 })
      setExpression('relaxed', 0.25)
      break
    case 'listening':
      // Lean in attentively
      Object.assign(pose, { headPitch: 0.10, headRoll: 0, headYaw: 0, spinePitch: 0.05 })
      setExpression('happy', 0.3)
      break
    case 'thinking':
      // Look up, pondering
      Object.assign(pose, { headPitch: -0.12, headRoll: 0.05, headYaw: 0.08, spinePitch: 0 })
      break
    case 'speaking':
      // Neutral pose; amplitude loop drives the mouth
      Object.assign(pose, { headPitch: 0, headRoll: 0, headYaw: 0, spinePitch: 0 })
      setExpression('happy', 0.4)
      break
    case 'didnt_catch':
      // Friendly head tilt, then back to neutral
      Object.assign(pose, { headPitch: 0.05, headRoll: 0.25, headYaw: 0, spinePitch: 0 })
      setExpression('surprised', 0.5)
      didntCatchTimer = setTimeout(() => {
        Object.assign(pose, { headPitch: 0, headRoll: 0, headYaw: 0, spinePitch: 0 })
        resetExpressions()
      }, 2500)
      break
  }
}

// ── Text UI helpers ───────────────────────────────────────────────────────
function showSentence(text) {
  if (fadeTimer) clearTimeout(fadeTimer)
  bubbleEl.classList.remove('fade')
  bubbleEl.textContent = text
  // Fade out after 6 s of silence
  fadeTimer = setTimeout(() => bubbleEl.classList.add('fade'), 6000)
}

let transcriptTimer = null
function showTranscript(text) {
  transcriptEl.textContent = `You: ${text}`
  transcriptEl.classList.add('visible')
  if (transcriptTimer) clearTimeout(transcriptTimer)
  transcriptTimer = setTimeout(() => transcriptEl.classList.remove('visible'), 4000)
}

function showError(html) {
  document.body.innerHTML =
    `<div style="display:flex;align-items:center;justify-content:center;height:100vh;
      font-family:system-ui;text-align:center;color:#5a3a2a;padding:40px">
      <div>${html}</div>
    </div>`
}

// ── Setup overlay (first-run downloads / Ollama guidance) ─────────────────
const SETUP_MESSAGES = {
  starting: {
    title: 'Waking Nova up…',
    body: 'Just a moment!',
    spinner: true,
  },
  ollama_missing: {
    title: 'Nova needs Ollama to think',
    body: 'Please install and open <b>Ollama</b> from '
      + '<span style="white-space:nowrap">ollama.com</span>, then run '
      + '<code>ollama pull llama3.2:3b</code> once. '
      + 'Nova keeps checking and will start by itself.',
    spinner: true,
  },
  downloading_models: {
    title: 'Getting Nova’s voice ready…',
    body: 'The first run downloads about 600 MB of voice models. '
      + 'This only happens once.',
    spinner: true,
  },
  loading_models: {
    title: 'Waking Nova up…',
    body: 'Loading the voice models — just a moment.',
    spinner: true,
  },
  warming_up: {
    title: 'Almost there…',
    body: 'Warming up so replies come fast.',
    spinner: true,
  },
}

let setupOverlayEl = null

function showSetupOverlay(phase, detail) {
  const info = SETUP_MESSAGES[phase] || {
    title: 'Setting up…', body: detail || '', spinner: true,
  }
  if (!setupOverlayEl) {
    setupOverlayEl = document.createElement('div')
    setupOverlayEl.id = 'setup-overlay'
    setupOverlayEl.style.cssText =
      'position:fixed;inset:0;z-index:1000;display:flex;align-items:center;'
      + 'justify-content:center;background:rgba(255,250,244,0.96);'
      + 'font-family:system-ui;color:#5a3a2a;text-align:center;padding:40px'
    document.body.appendChild(setupOverlayEl)
  }
  setupOverlayEl.innerHTML =
    `<div style="max-width:420px">
      ${info.spinner ? '<div class="setup-spinner" style="margin:0 auto 24px;width:44px;height:44px;border:4px solid #f0d9c8;border-top-color:#d98a5f;border-radius:50%;animation:setup-spin 1s linear infinite"></div>' : ''}
      <h2 style="margin:0 0 12px;font-size:1.4rem">${info.title}</h2>
      <p style="margin:0;line-height:1.5">${info.body}</p>
      ${detail && phase === 'ollama_missing' ? `<p style="margin-top:16px;font-size:0.85rem;opacity:0.7">${detail}</p>` : ''}
    </div>`
  if (!document.getElementById('setup-spin-style')) {
    const style = document.createElement('style')
    style.id = 'setup-spin-style'
    style.textContent = '@keyframes setup-spin{to{transform:rotate(360deg)}}'
    document.head.appendChild(style)
  }
}

function hideSetupOverlay() {
  if (setupOverlayEl) {
    setupOverlayEl.remove()
    setupOverlayEl = null
  }
}

// ── WebSocket ─────────────────────────────────────────────────────────────
function connectWS() {
  labelEl.textContent = 'Connecting to Nova…'
  ws = new WebSocket(WS_URL)

  ws.onopen = () => {
    console.log('[ws] connected')
    labelEl.textContent = 'Connected! Loading avatar…'
    // Tell the server which avatar is on screen so it can load the matching
    // appearance description ("what colour is your hair?"). The key is the VRM
    // basename, derived from the static MODEL_PATH — no model load needed.
    const avatarKey = MODEL_PATH.split('/').pop().replace(/\.vrm$/i, '')
    wsSend({ type: 'avatar_loaded', key: avatarKey })
  }

  ws.onmessage = (e) => {
    const msg = JSON.parse(e.data)
    switch (msg.type) {
      case 'init':
        setActiveLevel(msg.level)
        break
      case 'profiles':
        renderProfileSelector(msg.list, msg.active)
        break
      case 'profile_error':
        showToast(msg.message)
        break
      case 'memory_loaded':
        // Profile loaded — update active highlight (slug not sent, use active from profiles)
        break
      case 'onboarding_start':
        applyState('idle')
        labelEl.textContent = '👋 Getting to know you…'
        break
      case 'state':
        applyState(msg.state)
        break
      case 'sentence':
        showSentence(msg.text)
        break
      case 'transcript':
        showTranscript(msg.text)
        break
      case 'amplitude':
        targetAmp = msg.value
        break
      case 'setup_status':
        if (msg.phase === 'ready') {
          hideSetupOverlay()
        } else {
          showSetupOverlay(msg.phase, msg.detail)
        }
        break
      case 'settings':
        renderVoiceSelector(msg.voices, msg.voice)
        if (msg.level) setActiveLevel(msg.level)
        break
      case 'voice_status':
        updateVoiceStatus(msg.state, msg.voice)
        break
      case 'conversation_reset':
        resetConversation()
        break
      case 'conversation_turn':
        addConversationTurn(msg.id, msg.you, msg.nova)
        break
      case 'conversation_correction':
        addConversationCorrection(msg.id, msg.kind, msg.wrong, msg.right)
        break
    }
  }

  ws.onclose = () => {
    console.log('[ws] disconnected — retrying in', RECONNECT_MS, 'ms')
    labelEl.textContent = 'Reconnecting…'
    setTimeout(connectWS, RECONNECT_MS)
  }

  ws.onerror = () => ws.close()
}

function wsSend(data) {
  if (ws && ws.readyState === WebSocket.OPEN) {
    ws.send(JSON.stringify(data))
  }
}

// ── Keyboard PTT ──────────────────────────────────────────────────────────
// True hold-to-talk via keydown/keyup — works natively in the browser,
// no Accessibility permission needed.
// While a modal dialog is open, Space belongs to it — typing into the
// name field, or activating the focused button — not to push-to-talk.
// Without this guard, Space is preventDefault-ed away from the input (so
// multi-word names can't be typed) and fires a spurious ptt_start/stop_speak.
function pttBlocked() {
  return !modalOverlayEl.hidden
}

window.addEventListener('keydown', (e) => {
  if (e.code !== 'Space' || e.repeat) return
  if (pttBlocked()) return
  e.preventDefault()
  if (state === 'idle' && !pttActive) {
    pttActive = true
    wsSend({ type: 'ptt_start' })
  } else if (state === 'speaking' || state === 'thinking') {
    // Barge-in: pressing Space while the avatar is speaking or thinking
    // interrupts and hands control back to the child immediately.
    wsSend({ type: 'stop_speak' })
  }
})

window.addEventListener('keyup', (e) => {
  if (e.code !== 'Space') return
  if (pttBlocked()) return
  e.preventDefault()
  if (pttActive) {
    pttActive = false
    wsSend({ type: 'ptt_stop' })
  }
})

// ── Settings panel (gear → Kid / Voice / Level) ───────────────────
const gearEl        = document.getElementById('settings-gear')
const panelEl       = document.getElementById('settings-panel')
const closeEl       = document.getElementById('settings-close')

function toggleSettings(open) {
  panelEl.hidden = open === undefined ? !panelEl.hidden : !open
  gearEl.classList.toggle('active', !panelEl.hidden)
  if (!panelEl.hidden) toggleTranscript(false)   // one panel at a time
}
gearEl.addEventListener('click', () => toggleSettings())
closeEl.addEventListener('click', () => toggleSettings(false))
window.addEventListener('keydown', (e) => {
  if (e.code === 'Escape' && !panelEl.hidden) toggleSettings(false)
})

// ── Transcript panel (conversation review) ────────────────────────
const transcriptBtnEl   = document.getElementById('transcript-btn')
const transcriptPanelEl = document.getElementById('transcript-panel')
const transcriptCloseEl = document.getElementById('transcript-close')
const transcriptListEl  = document.getElementById('transcript-list')
const conversation = new Map()   // id → { el, youEl }

// Below this width there isn't room to sit the avatar and the transcript
// side by side (it would leave the avatar too cramped), so the panel falls
// back to overlaying the avatar.
const SIDE_BY_SIDE_MIN = 860
// Gap left of the panel and between it and the window edge. The panel's own
// width comes from CSS at measure time — hardcoding it here would silently
// misalign the stage the moment #transcript-panel's width changes.
const PANEL_GAP = 16

// Right strip the docked panel occupies: its rendered width plus a gap each
// side. Measured rather than assumed; falls back to the CSS width if the panel
// is hidden (getBoundingClientRect is 0 on a display:none element).
function panelReserve() {
  const w = transcriptPanelEl.getBoundingClientRect().width || 340
  return w + PANEL_GAP * 2
}

// Reserve space on the right for the transcript panel and reflow the avatar
// stage into the remaining width, so the two sit side by side rather than
// the panel covering the avatar.
function applyStageLayout() {
  const dock = !transcriptPanelEl.hidden && window.innerWidth >= SIDE_BY_SIDE_MIN
  stageReservePx = dock ? panelReserve() : 0
  const root = document.documentElement.style
  root.setProperty('--stage-reserve', stageReservePx + 'px')
  root.setProperty('--stage-w', (window.innerWidth - stageReservePx) + 'px')
  document.body.classList.toggle('transcript-docked', dock)
  if (renderer) fitViewport()
}

function toggleTranscript(open) {
  transcriptPanelEl.hidden = open === undefined ? !transcriptPanelEl.hidden : !open
  transcriptBtnEl.classList.toggle('active', !transcriptPanelEl.hidden)
  if (!transcriptPanelEl.hidden) toggleSettings(false)
  applyStageLayout()
}
transcriptBtnEl.addEventListener('click', () => toggleTranscript())
transcriptCloseEl.addEventListener('click', () => toggleTranscript(false))
window.addEventListener('keydown', (e) => {
  if (e.code === 'Escape' && !transcriptPanelEl.hidden) toggleTranscript(false)
})

// Clear the panel back to its empty state. Sent by the server before it
// replays a profile's saved history (on connect or profile switch), so a
// reconnect rebuilds the list from disk instead of stacking on top of it.
function resetConversation() {
  conversation.clear()
  transcriptListEl.innerHTML =
    '<p class="transcript-empty">Your chat with Nova will appear here.</p>'
}

function addConversationTurn(id, you, nova) {
  const empty = transcriptListEl.querySelector('.transcript-empty')
  if (empty) empty.remove()

  const turn = document.createElement('div')
  turn.className = 'turn'

  const youEl = document.createElement('div')
  youEl.className = 'turn-you'
  youEl.append(tag('You'), textNode(you))

  const novaEl = document.createElement('div')
  novaEl.className = 'turn-nova'
  novaEl.append(tag('Nova'), textNode(nova))

  turn.append(youEl, novaEl)
  transcriptListEl.appendChild(turn)
  transcriptListEl.scrollTop = transcriptListEl.scrollHeight

  conversation.set(id, { el: turn, youEl })
}

function addConversationCorrection(id, kind, wrong, right) {
  const entry = conversation.get(id)
  if (!entry) return
  // Emphasise the fix inline on the child's line: strike the wrong word,
  // show the right one, and add a small note underneath.
  const note = document.createElement('div')
  note.className = 'turn-correction'
  note.append(
    span('correction-wrong', wrong),
    span('correction-arrow', ' → '),
    span('correction-right', right),
    kind ? span('correction-kind', ` (${kind.replace(/_/g, ' ')})`) : document.createComment(''),
  )
  entry.el.insertBefore(note, entry.el.querySelector('.turn-nova'))
  entry.el.classList.add('has-correction')
}

// small DOM helpers
function tag(label) {
  const s = document.createElement('span')
  s.className = 'turn-tag'
  s.textContent = label
  return s
}
function textNode(t) { return document.createTextNode(t) }
function span(cls, text) {
  const s = document.createElement('span')
  s.className = cls
  s.textContent = text
  return s
}

// ── Level selector ────────────────────────────────────────────────
const levelBtns = document.querySelectorAll('#level-selector .chip')

function setActiveLevel(level) {
  levelBtns.forEach(btn => {
    btn.classList.toggle('active', btn.dataset.level === level)
  })
}

levelBtns.forEach(btn => {
  btn.addEventListener('click', () => {
    const level = btn.dataset.level
    setActiveLevel(level)
    wsSend({ type: 'set_level', level })
  })
})

// ── Voice selector ────────────────────────────────────────────────
const voiceSelectorEl = document.getElementById('voice-selector')
let activeVoice = null
const voiceLabels = new Map()   // id → display label (for the toast)

function renderVoiceSelector(voices, current) {
  activeVoice = current
  voiceSelectorEl.innerHTML = ''
  voiceLabels.clear()
  ;(voices || []).forEach(v => {
    voiceLabels.set(v.id, v.label)
    const btn = document.createElement('button')
    btn.className = 'chip voice-chip' + (v.id === current ? ' active' : '')
    btn.textContent = v.label
    btn.dataset.voice = v.id
    btn.addEventListener('click', () => {
      if (v.id === activeVoice) return
      wsSend({ type: 'set_voice', voice: v.id })
    })
    voiceSelectorEl.appendChild(btn)
  })
}

function updateVoiceStatus(state, voice) {
  const chips = voiceSelectorEl.querySelectorAll('.voice-chip')
  const busy = state === 'loading' || state === 'downloading'
  chips.forEach(c => {
    const isTarget = c.dataset.voice === voice
    c.classList.toggle('loading', busy && isTarget)
    c.classList.toggle('downloading', state === 'downloading' && isTarget)
  })

  const name = (voiceLabels.get(voice) || 'voice').split(' —')[0]
  if (state === 'downloading') {
    showToast(`⬇ Downloading ${name}'s voice… (one-time, ~60 MB)`, { spinner: true, persist: true })
  } else if (state === 'loading') {
    showToast(`Switching to ${name}…`, { spinner: true, persist: true })
  } else if (state === 'ready') {
    activeVoice = voice
    chips.forEach(c => c.classList.toggle('active', c.dataset.voice === voice))
    showToast(`✓ ${name}'s voice ready`, { duration: 1800 })
  } else if (state === 'error') {
    showToast(`Couldn't load ${name}'s voice — kept the previous one`, { duration: 3000 })
  }
}

// ── Toast (bottom-center transient banner) ────────────────────────
let toastEl = null
let toastTimer = null

function showToast(text, { spinner = false, persist = false, duration = 2500 } = {}) {
  if (!toastEl) {
    toastEl = document.createElement('div')
    toastEl.id = 'toast'
    document.body.appendChild(toastEl)
  }
  if (toastTimer) { clearTimeout(toastTimer); toastTimer = null }
  toastEl.innerHTML = ''
  if (spinner) {
    const sp = document.createElement('span')
    sp.className = 'toast-spinner'
    toastEl.appendChild(sp)
  }
  toastEl.appendChild(document.createTextNode(text))
  toastEl.classList.add('visible')
  if (!persist) toastTimer = setTimeout(hideToast, duration)
}

function hideToast() {
  if (toastEl) toastEl.classList.remove('visible')
}

// ── Modal dialog (prompt / confirm) ───────────────────────────────
// window.prompt()/confirm() are no-ops in the Tauri webview, so profile
// add/remove use this in-app dialog instead.
const modalOverlayEl = document.getElementById('modal-overlay')
const modalMessageEl = document.getElementById('modal-message')
const modalInputEl   = document.getElementById('modal-input')
const modalCancelEl  = document.getElementById('modal-cancel')
const modalConfirmEl = document.getElementById('modal-confirm')
let modalResolve = null
let modalHasInput = false
let modalReturnFocus = null

// Tab order inside the dialog: the input (when shown) then the two buttons.
function modalFocusables() {
  return [modalInputEl, modalCancelEl, modalConfirmEl].filter(el => !el.hidden)
}

function closeModal(result) {
  if (!modalResolve) return
  const resolve = modalResolve
  modalResolve = null
  modalOverlayEl.hidden = true
  // Hand focus back to whatever opened the dialog (the '+' or '✕' chip), so
  // keyboard users don't get dumped at the top of the document.
  const returnTo = modalReturnFocus
  modalReturnFocus = null
  if (returnTo && returnTo.isConnected) returnTo.focus()
  resolve(result)
}

// Returns a Promise: a trimmed string (or null if cancelled) when `input`,
// otherwise a boolean confirm result.
function openModal({ message, input = false, placeholder = '',
                    confirmLabel = 'OK', danger = false } = {}) {
  // A dialog already open resolves as cancelled before opening the new one.
  if (modalResolve) closeModal(modalHasInput ? null : false)
  const opener = document.activeElement
  return new Promise(resolve => {
    modalResolve = resolve
    modalReturnFocus = opener instanceof HTMLElement ? opener : null
    modalHasInput = input
    modalMessageEl.textContent = message
    modalInputEl.hidden = !input
    modalInputEl.value = ''
    modalInputEl.placeholder = placeholder
    modalConfirmEl.textContent = confirmLabel
    modalConfirmEl.classList.toggle('danger', danger)
    modalOverlayEl.hidden = false
    setTimeout(() => (input ? modalInputEl : modalConfirmEl).focus(), 0)
  })
}

function confirmModal() {
  closeModal(modalHasInput ? modalInputEl.value.trim() || null : true)
}
modalConfirmEl.addEventListener('click', confirmModal)
modalCancelEl.addEventListener('click', () => closeModal(modalHasInput ? null : false))
modalOverlayEl.addEventListener('click', (e) => {
  if (e.target === modalOverlayEl) closeModal(modalHasInput ? null : false)
})
modalInputEl.addEventListener('keydown', (e) => {
  // NumpadEnter is a distinct code from Enter — both submit the name.
  if (e.code === 'Enter' || e.code === 'NumpadEnter') {
    e.preventDefault()
    confirmModal()
  }
})
window.addEventListener('keydown', (e) => {
  if (modalOverlayEl.hidden) return
  if (e.code === 'Escape') {
    e.stopPropagation()
    closeModal(modalHasInput ? null : false)
    return
  }
  // aria-modal="true" promises focus stays in the dialog — implement it, or
  // Tab walks off into the page behind the overlay.
  if (e.code === 'Tab') {
    const items = modalFocusables()
    if (!items.length) return
    const first = items[0]
    const last = items[items.length - 1]
    const onFirst = document.activeElement === first
    const onLast = document.activeElement === last
    if (e.shiftKey && (onFirst || !items.includes(document.activeElement))) {
      e.preventDefault()
      last.focus()
    } else if (!e.shiftKey && (onLast || !items.includes(document.activeElement))) {
      e.preventDefault()
      first.focus()
    }
  }
}, true)

// ── Profile selector ──────────────────────────────────────────────
const profileSelectorEl = document.getElementById('profile-selector')

function displayName(slug) {
  // Capitalize slug (underscores → spaces): mia_rose → Mia Rose
  return slug.replace(/_/g, ' ').replace(/\b\w/g, c => c.toUpperCase())
}

function renderProfileSelector(profiles, activeSlug) {
  profileSelectorEl.innerHTML = ''
  // Only offer removal when more than one child exists — the app always needs
  // an active profile to fall back to.
  const canRemove = profiles.length > 1

  profiles.forEach(slug => {
    const item = document.createElement('span')
    item.className = 'profile-item'

    const btn = document.createElement('button')
    btn.className = 'chip' + (slug === activeSlug ? ' active' : '')
    btn.textContent = displayName(slug)
    btn.dataset.slug = slug
    btn.addEventListener('click', () => {
      if (slug !== activeSlug) wsSend({ type: 'switch_profile', slug })
    })
    item.appendChild(btn)

    if (canRemove) {
      const removeBtn = document.createElement('button')
      removeBtn.className = 'profile-remove'
      removeBtn.textContent = '✕'
      removeBtn.setAttribute('aria-label', `Remove ${displayName(slug)}`)
      removeBtn.title = `Remove ${displayName(slug)}`
      removeBtn.addEventListener('click', async (e) => {
        e.stopPropagation()
        const ok = await openModal({
          message: `Remove ${displayName(slug)}? This permanently deletes their saved progress.`,
          confirmLabel: 'Remove',
          danger: true,
        })
        if (ok) wsSend({ type: 'delete_profile', slug })
      })
      item.appendChild(removeBtn)
    }

    profileSelectorEl.appendChild(item)
  })

  // '+' button to add a new child (triggers onboarding for a fresh slug)
  const addBtn = document.createElement('button')
  addBtn.className = 'chip'
  addBtn.textContent = '+'
  addBtn.title = 'Add a new child'
  addBtn.addEventListener('click', async () => {
    const rawName = await openModal({
      message: "What's the new child's name?",
      input: true,
      placeholder: 'Name',
      confirmLabel: 'Add',
    })
    if (!rawName) return
    // Send the raw name — the server runs it through name_to_slug (the single
    // source of truth for slugs), so we don't duplicate that logic here.
    wsSend({ type: 'switch_profile', slug: rawName })
  })
  profileSelectorEl.appendChild(addBtn)
}

function setActiveProfile(slug) {
  profileSelectorEl.querySelectorAll('.chip[data-slug]').forEach(btn => {
    btn.classList.toggle('active', btn.dataset.slug === slug)
  })
}

// ── Bootstrap ────────────────────────────────────────────────
initThree()
connectWS()
loadModel()   // async; non-blocking
