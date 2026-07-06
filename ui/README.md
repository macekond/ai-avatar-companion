# Nova UI

Vite vanilla-JS frontend. Renders the avatar with [three.js](https://threejs.org)
and [@pixiv/three-vrm](https://github.com/pixiv/three-vrm) (both MIT), connects
to the Python sidecar at `ws://localhost:8765`.

```bash
npm install
npm run dev      # http://localhost:5173
npm run build    # → dist/
```

## Avatar model

`public/avatar/AvatarSample_A.vrm` is pixiv's official VRoid sample model,
released under **CC0** — it may be used, altered, and redistributed freely,
including in this repository. Source: [madjin/vrm-samples](https://github.com/madjin/vrm-samples)
(mirror of the VRoid Studio sample avatars).

To use a different avatar, drop any `.vrm` file in `public/avatar/` and update
`MODEL_PATH` in `src/main.js`. The state machine uses standard VRM humanoid
bones (`head`, `spine`, arms) and expression presets (`aa`, `blink`, `happy`,
`sad`, `surprised`, `relaxed`), which every conforming VRM model provides.

## History

Earlier phases used Live2D (pixi-live2d-display + Cubism Core + the Hiyori
sample model). Those were replaced with the VRM stack because the Cubism Core
runtime and Live2D sample models are proprietary and cannot be committed to
an open-source repository. See the design doc for the "custom Nova model"
plan — a bespoke VRM made in VRoid Studio (free) that we would own outright.
