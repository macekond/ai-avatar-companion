/**
 * Nova Phase 3 — Live2D avatar frontend
 *
 * Responsibilities:
 *  - Render the Live2D avatar via pixi-live2d-display
 *  - Maintain the 5-state machine driven by WebSocket messages from the Python server
 *  - Capture Space keydown/keyup and send ptt_start/ptt_stop to the server
 *  - Drive ParamMouthOpenY from amplitude messages for lip-sync
 *  - Update sentence bubble, transcript flash, and background colour per state
 */

import './style.css'
import * as PIXI from 'pixi.js'
// Import from the cubism4 subpath — this auto-registers the Cubism 4 plugin
// and tells pixi-live2d-display to use live2dcubismcore.min.js (not live2d.min.js).
import { Live2DModel, MotionPriority } from 'pixi-live2d-display/cubism4'

// Register PIXI's ticker with Live2D so animations run
Live2DModel.registerTicker(PIXI.Ticker)

// ── Constants ─────────────────────────────────────────────────────────────
const WS_URL       = 'ws://localhost:8765'
const MODEL_PATH   = '/avatar/Hiyori/Hiyori.model3.json'
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
let pixiApp   = null
let model     = null
let ws        = null
let state     = 'idle'
let amplitude = 0          // smoothed lip-sync value
let targetAmp = 0
let pttActive = false      // true while Space is held
let fadeTimer = null       // for bubble fade-out

// ── PIXI setup ────────────────────────────────────────────────────────────
function initPixi() {
  pixiApp = new PIXI.Application({
    view: canvasEl,
    width: window.innerWidth,
    height: window.innerHeight,
    backgroundAlpha: 0,    // transparent — CSS gradient shows through
    antialias: true,
    resizeTo: window,
  })

  // Low-priority ticker: runs after Live2D internal update each frame
  pixiApp.ticker.add(onTick, undefined, PIXI.UPDATE_PRIORITY.LOW)
}

// Per-frame update: lip-sync + amplitude decay
function onTick() {
  // Smooth amplitude towards target
  amplitude += (targetAmp - amplitude) * 0.35
  targetAmp *= 0.88            // decay when no new messages arrive

  if (model && state === 'speaking') {
    try {
      model.internalModel.coreModel.setParameterValueById('ParamMouthOpenY', amplitude)
    } catch { /* model may not expose this param */ }
  }
}

// ── Live2D model loading ──────────────────────────────────────────────────
async function loadModel() {
  try {
    model = await Live2DModel.from(MODEL_PATH, { autoInteract: false })
  } catch (err) {
    showError(
      'Avatar model not found.<br>' +
      'Follow <b>ui/README.md</b> to download the Hiyori model, then refresh.'
    )
    return
  }

  pixiApp.stage.addChild(model)
  fitModel()

  // Resize handler
  window.addEventListener('resize', fitModel)

  // Start idle motion
  applyState('idle')
}

function fitModel() {
  if (!model) return
  const w = pixiApp.view.width
  const h = pixiApp.view.height
  const scale = Math.min(w * 0.85 / model.width, h * 0.92 / model.height)
  model.scale.set(scale)
  model.x = (w - model.width  * scale) / 2
  model.y = (h - model.height * scale) / 2 - h * 0.02
}

// ── State machine ─────────────────────────────────────────────────────────
function applyState(newState) {
  state = newState

  // Background tint via body class
  document.body.className = newState === 'idle' || newState === 'speaking' ? '' : newState

  // State label
  labelEl.textContent = STATE_LABELS[newState] ?? ''

  if (!model) return

  try {
    switch (newState) {
      case 'idle':
        model.motion('Idle', 0, MotionPriority.IDLE)
        break
      case 'listening':
        // Lean-in effect: tilt body parameters slightly
        model.motion('Idle', 0, MotionPriority.IDLE)
        model.internalModel.coreModel.setParameterValueById('ParamAngleX', -5)
        model.internalModel.coreModel.setParameterValueById('ParamBodyAngleX', -3)
        break
      case 'thinking':
        model.motion('Idle', 0, MotionPriority.IDLE)
        model.internalModel.coreModel.setParameterValueById('ParamAngleY', 10)
        break
      case 'speaking':
        // Amplitude loop handles mouth; reset any tilt
        model.motion('TapBody', 0, MotionPriority.NORMAL)
        model.internalModel.coreModel.setParameterValueById('ParamAngleX', 0)
        model.internalModel.coreModel.setParameterValueById('ParamAngleY', 0)
        model.internalModel.coreModel.setParameterValueById('ParamBodyAngleX', 0)
        break
      case 'didnt_catch':
        model.motion('Idle', 0, MotionPriority.IDLE)
        // Friendly head tilt
        model.internalModel.coreModel.setParameterValueById('ParamAngleZ', 15)
        setTimeout(() => {
          if (model) {
            try { model.internalModel.coreModel.setParameterValueById('ParamAngleZ', 0) } catch {}
          }
        }, 2500)
        break
    }
  } catch { /* param/motion not available in this model — silently skip */ }
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
initPixi()
connectWS()
loadModel()   // async; non-blocking
