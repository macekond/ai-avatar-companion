# Nova UI

Vite vanilla-JS frontend. Renders the avatar with [three.js](https://threejs.org)
and [@pixiv/three-vrm](https://github.com/pixiv/three-vrm) (both MIT), connects
to the Python sidecar at `ws://localhost:8765`.

```bash
npm install
npm run dev      # http://localhost:5173
npm run build    # → dist/
```

## Avatar models

**Default: `public/avatar/VIPEHero_2707.vrm`** — "VIPE Hero #2707" from the
VIPE Heroes Genesis collection, via
[Open Source Avatars](https://www.opensourceavatars.com/en/finder?avatar=vipe-hero-2707).
License: **CC-BY** — free to use, modify, and redistribute **with
attribution**. Attribution: *VIPE Heroes Genesis by VIPE
([vipe.io](https://vipe.io)), via opensourceavatars.com (ToxSam).*

Alternative: `public/avatar/AvatarSample_A.vrm` — pixiv's official VRoid
sample model, **CC0** (no attribution needed). Source:
[madjin/vrm-samples](https://github.com/madjin/vrm-samples).

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
