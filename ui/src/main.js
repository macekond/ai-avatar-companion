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
  window.addEventListener('resize', fitViewport)
}

function fitViewport() {
  camera.aspect = window.innerWidth / window.innerHeight
  camera.updateProjectionMatrix()
  renderer.setSize(window.innerWidth, window.innerHeight)
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
window.addEventListener('keydown', (e) => {
  if (e.code !== 'Space' || e.repeat) return
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
  e.preventDefault()
  if (pttActive) {
    pttActive = false
    wsSend({ type: 'ptt_stop' })
  }
})

// ── Level selector ────────────────────────────────────────────────
const levelBtns = document.querySelectorAll('.level-btn')

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

// ── Profile selector ──────────────────────────────────────────────
const profileSelectorEl = document.getElementById('profile-selector')

function renderProfileSelector(profiles, activeSlug) {
  profileSelectorEl.innerHTML = ''

  profiles.forEach(slug => {
    const btn = document.createElement('button')
    btn.className = 'level-btn' + (slug === activeSlug ? ' active' : '')
    // Display name: capitalize slug (underscores → spaces)
    btn.textContent = slug.replace(/_/g, ' ').replace(/\b\w/g, c => c.toUpperCase())
    btn.dataset.slug = slug
    btn.addEventListener('click', () => {
      wsSend({ type: 'switch_profile', slug })
    })
    profileSelectorEl.appendChild(btn)
  })

  // '+' button to add a new child (triggers onboarding for a fresh slug)
  const addBtn = document.createElement('button')
  addBtn.className = 'level-btn'
  addBtn.textContent = '+'
  addBtn.title = 'Add a new child'
  addBtn.addEventListener('click', () => {
    const rawName = prompt('Enter the new child\'s name:')
    if (!rawName) return
    // Build a slug client-side (server will create the profile)
    const slug = rawName.toLowerCase().trim().replace(/\s+/g, '_').replace(/[^a-z0-9_]/g, '')
    if (slug) wsSend({ type: 'switch_profile', slug })
  })
  profileSelectorEl.appendChild(addBtn)
}

function setActiveProfile(slug) {
  profileSelectorEl.querySelectorAll('.level-btn[data-slug]').forEach(btn => {
    btn.classList.toggle('active', btn.dataset.slug === slug)
  })
}

// ── Bootstrap ────────────────────────────────────────────────
initThree()
connectWS()
loadModel()   // async; non-blocking
