# Host enhancements: correctness, frame rate, image quality, HD textures

These are changes to the **host runtime only** (`src/host`): the Win32 shims and the Direct3D 7 → Metal
backend. The recompiled game code is unchanged. Everything is **off by default**, so a fresh build looks and
runs exactly as before. The menu frame is byte-identical to the build before these changes.

## How to switch things on

**In the game's own menu:** Options → **Video Options** now has a second column with **HD Textures**,
**Sharp Textures** (anisotropic 16x), **Smooth Mipmaps** (trilinear), **Resolution** (1x/2x/3x/4x/Auto),
**Anti-aliasing** (Off/2x/4x/8x), **Frame Rate** (60/120, next start), **Generated Mipmaps** and
**Alpha to Coverage**. Click a row to change it, then
**Apply** to use it, or **Cancel** to throw the change away. **Restore Default** resets these rows too.

How it works: the host patches three slots of that screen's vtable (destructor, command, build). It does
this only after checking that cshell is at its expected base and the slots hold their original values.
It then adds the rows with the game's own control functions, so no generated code changes. The rows'
text surfaces are cached, so clicking does not leak surfaces. The rows also follow changes made in the
panel below.
This was tested offscreen with scripted mouse clicks: Apply, Cancel, Restore Default, 50-click stress,
the game's own Apply, and its render re-init.

**Panel:** press **Cmd+,** (or choose *Settings…* in the app menu). A panel over the game picture
lists the settings:
- **Select and change:** ↑↓ selects a row, ←→ changes its value, Esc or Return closes the panel.
- **When changes apply:** resolution, anti-aliasing, filtering and HD textures change immediately. The
  frame-rate cap applies after a restart.
- **Saving:** every change is saved in the same defaults keys as below.
- **Game input:** while the panel is open, the game gets no keyboard or mouse input, and Esc does not reach it.
- **Screenshots and saves:** the panel is drawn only into the window picture, never into the back buffer,
  so it cannot appear in save thumbnails.
- **What was tested:** offscreen with scripted keys, at 1x and 2x, with the Metal debug layer showing no
  validation errors. The real Cmd+, shortcut, real keyboard and mouse handling in the window, and saving a
  change have not been tried yet.

Instead of the panel, the settings can be set from the Terminal:

Every setting is a key in the defaults domain `local.mm9-native` (the same one that stores
`StartFullscreen`). An environment variable with the `M1_` name overrides the key for one start.

```bash
defaults write local.mm9-native RenderScale -int 0        # 0 = match the display (auto), 1-4 = fixed
defaults write local.mm9-native MSAA -int 4               # 1, 2, 4 or 8
defaults write local.mm9-native Anisotropy -int 16        # 1-16
defaults write local.mm9-native Trilinear -bool true
defaults write local.mm9-native MaxFPS -int 120           # frame-rate cap, clamped to 120 (see below)
defaults write local.mm9-native TextureReplace -bool true # load HD textures from HDTextures/replace
defaults write local.mm9-native TextureDump -bool true    # write every texture to HDTextures/dump
defaults delete local.mm9-native RenderScale              # back to the default
```

| Setting (key / env) | Default | What it does |
|---|---|---|
| `RenderScale` / `M1_SCALE` (`auto`) | 1 | Renders 3D and 2D at an integer multiple of 800×600 (up to 3200×2400). |
| `MSAA` / `M1_MSAA` | 1 | Multisample anti-aliasing. |
| `Anisotropy` / `M1_ANISO` | 1 | Anisotropic filtering for the game's mipmapped textures. |
| `Trilinear` / `M1_TRILINEAR` | off | Blends between mip levels (the game asks for point mip filtering). |
| `MaxFPS` / `M1_MAXFPS` | not set (the game's own `MaxFPS 60` applies) | Frame-rate cap passed to the engine as `+MaxFPS`, at most 120. |
| `TextureDump` / `M1_TEXDUMP` | off | Dumps each distinct texture once as `<hash>.png` plus `index.tsv`. |
| `TextureReplace` / `M1_TEXREPLACE` | off | Uses `<hash>.png` or `<hash>.dds` from the replace folder instead of the original. |
| `TextureDir` / `M1_TEXDIR` | `HDTextures` in the game folder | Base folder for `dump/` and `replace/`. |
| `M1_NOCULL`, `M1_NOCOLORKEY` (env only) | off | Turn the new cull-mode and colour-key handling off again. |
| `M1_NOVSYNC` (env only) | off | Turns off vsync in the window. |

The game folder is `~/Library/Application Support/MM9 Native/game` for the builder's app, so the
texture folders are `…/MM9 Native/game/HDTextures/{dump,replace}`.

## 0. Direct3D correctness

- **Cull mode** (`D3DRENDERSTATE_CULLMODE`) is now applied per draw: CW → Metal front-face culling,
  CCW → back-face culling. This was checked by forcing CCW on the bootcamp view: the picture stayed
  the same, while the opposite mapping removed nearly all geometry. In practice the game sets
  `CULL_NONE` on every draw (12.3 million draws counted) and culls on the CPU, so nothing changes on screen.
- **Colour-key render state** (`D3DRENDERSTATE_COLORKEYENABLE`): textures with a source colour key get a
  keyed copy, and the shader discards key texels. The game never turned this on in the main menu or
  bootcamp, and no bound texture had a colour key, so this path is implemented but untested on real content.
- **Back buffer → primary Blt** was already handled (the loading screen uses it). The old README line was stale.

## 1. Frame rate

- **Where the 60 fps cap comes from:** the engine's own `MaxFPS` console variable (`"MaxFPS" "60"` in
  autoexec.cfg). The engine's limiter lands a little under the nominal value: 60 gives about 57.8 fps and
  120 gives 110–113 fps. In a window, vsync (`displaySyncEnabled`) is a second limit at the display's
  refresh rate.
- **Does the game speed up?** It was tested with timed scripted input at 30, 60, 120, 240 fps and uncapped:
  - **Walking and turning** cover the same distance in the same time at every frame rate. The difference
    is within the 2 px run-to-run noise of the distance measure.
  - **The in-game clock does speed up above about 120 fps.** Ten seconds of game time at 60, 90 and 120 fps
    all advanced the clock from 6:00 to 6:05. At 144 fps it read 6:06, at 180–240 fps 6:08, and uncapped
    (about 700 fps) 6:37. The engine evidently advances world time by at least about 1/120 s per frame.
- **Decision:** the host's `MaxFPS` setting is clamped to 120 (0 = uncapped also becomes 120).
  `M1_MAXFPS_FORCE=1` skips the clamp for benchmarks. The default stays the player's own 60. Setting
  `MaxFPS 120` on a ProMotion (120 Hz) display gives smoother motion with the clock correct.
  The game's own config can still be set to `MaxFPS 0` by hand; that is not prevented.

## 2. Image quality

- **Render scale:** the game draws everything as pre-transformed 800×600 screen coordinates. The host
  keeps that coordinate system and only makes the colour and depth targets S times larger. So 3D, the UI
  and movies scale together and stay aligned, while the game still sees an 800×600 device. When the game
  reads the back buffer (save thumbnails), it is box-filtered back to 800×600. A thumbnail taken at scale 2
  with MSAA 4 was checked. The UI art is still 800×600 artwork, so it stays pixel-sharp but blocky. Only the
  3D scene gains detail.
- **MSAA:** multisample colour and depth targets are resolved into the back buffer at the end of every
  render pass.
- **Texture filtering:** in bootcamp, 54 % of texture bindings are mipmapped with linear min/mag filtering
  and *point* mip filtering. These are the bindings that anisotropy and trilinear filtering affect. UI
  sprites are point-sampled and non-mipmapped, so they are untouched.

## 2b. Generated mipmaps and alpha to coverage (off by default)

- **Generated Mipmaps** (`GenMipmaps` / `M1_GENMIPS`): 3D textures that the game uploads without a mip
  chain get one. In bootcamp, about a quarter of all texture bindings are such textures.
  - **Only 3D draws are affected.** Draws with the Z test off (UI, sprites) are never linear-filtered
    unmipped textures, so the Z test cleanly separates 2D from 3D and the UI stays pixel-exact.
  - **How the mips are made:** opaque textures use GPU mip generation on RGBA8. Alpha textures use a CPU
    filter that keeps alpha coverage at 0.5, because the game's alpha test is always greater than 0.
  - **Cost:** 0.1–0.3 MB per area.
  - **Visible effect:** small. The game's ground and wall textures already have mips; the unmipped ones
    are a few 64×64 16-bit textures per area.
- **Alpha to Coverage** (`AlphaToCoverage` / `M1_A2C`): with MSAA on, alpha-tested draws that are not
  blended get antialiased edges.
  - **Where it acts:** bootcamp has no such draws. Yorwick has two 256×256 foliage textures. Most of the
    game's foliage is alpha-blended, so the effect is confined to a few leaf edges.
- **fps:** at scale 4 + MSAA 4 there is no measurable cost (335.7 fps with both off, 335.0 with both on,
  uncapped).

## 3. HD textures

- **Dump:** each uploaded texture is hashed (a 64-bit xxHash64-style hash over its level-0 pixels, seeded
  with width, height, format and colour key). Each new hash is written once as a straight-alpha RGBA
  `<hash>.png`. Encoding runs on a background queue, and a line is appended to `index.tsv`.
  - **Formats:** DXT1/3/5, 32-bit, RGB565, ARGB/XRGB1555 and ARGB4444 are decoded. Colour-key texels get
    alpha 0.
  - **Dynamic textures:** a surface whose contents change more than 3 times (movies, the loading-screen
    animation) is not hashed from then on.
  - **Bootcamp and the main menu** give 278 textures: 231 ARGB1555 (mostly 64×64), 14 RGB565, 14 XRGB1555,
    9 DXT1, 5 XRGB8888, 3 DXT5 and 2 ARGB4444.
  - **Determinism:** 128 of 140 names were the same across two runs. The 12 that differ are small 16-bit
    textures that change over time.
- **Replace:** at start the host scans `replace/` once. When an uploaded texture's hash has a file, that
  file is used at any size.
  - **PNG** files get a generated mip chain.
  - **DDS** files can be DXT1/3/5 or 32-bit BGRA, and use the file's own mips.
  - **Alpha follows the original format:** a texture without alpha (565, XRGB) stays opaque. For a
    colour-keyed texture, the replacement's alpha 0 is the key.
  - **2D blits** of replaced surfaces use the original size for their texture coordinates.
- **Tool:** `python3 dev/texlist.py <TextureDir> [--format F] [--min-size N] [--missing|--replaced] [--list]`
  lists the dumped textures, the ones that have a replacement, and replacement files that match nothing.
  The dumped textures themselves are game-derived: keep them on your Mac and never share them.
- **Robustness:** replacement files over 8192 pixels on a side, undecodable PNGs and truncated DDS files are
  rejected with a log line, and the original texture is used. This was tested with a pack containing a
  random-bytes PNG, a PNG header claiming 32767×32767, and a truncated DDS. Unused replacements are freed
  when no surface uses them any more. The hash ignores the unused bits of the X formats.
- **Workflow:** play with `TextureDump` on, then run `texlist.py`. Upscale the textures you want and save
  them under the same name in `replace/`, then switch `TextureReplace` on.

## Numbers (bootcamp spawn view, offscreen, Apple M4 Pro, 20 s windows)

| Configuration | Uncapped fps | Main-thread ms/frame, uncapped | MaxFPS 60: fps, main-thread ms/frame |
|---|---|---|---|
| Before these changes | 739 | 1.35 | 57.9 · 3.72 |
| All defaults after the changes | 646–744 (load-dependent, see below) | 1.34–1.55 | 57.8 · 3.23–3.56 |
| `MaxFPS` 120 (host setting) | 110–113 (capped) | 2.8–2.9 | — |
| Scale 2 | 746 | 1.34 | 56.9 · 4.13 |
| Scale 2 + MSAA 4 + aniso 16 + trilinear | 677–701 | 1.47 | 56.9–57.6 · 4.16 |
| Scale 4 + MSAA 4 + aniso 16 | 345 | 1.98 | 56.4 · 4.27 |
| Texture dump on | ~700 | — | 57.2 |
| Replace, 184 files / identity pack of 278 | 539–724 / 632–705 | — | — |
| Scale 2 + MSAA 4 + aniso 16 + trilinear + replace | 493 (machine under load) | — | 57.2 |

Run-to-run noise on this machine is large uncapped (496–745 fps for identical default runs, depending on what
else the Mac was doing), so differences under about 10 % are not meaningful. The uncapped
runs are limited by the main thread (the game's software T&L), so GPU cost shows only at scale 4.
Offscreen runs have no vsync and no window.

## Open questions and what the owner should test

Not yet checked in a real window: auto scale on the display, the drawable at scale > 1, MSAA in the
window, `MaxFPS 120` with vsync on a ProMotion display, and the `defaults` keys. (All the tests above ran
offscreen and used the env variables.)

Test guide for the owner (about 10 minutes):
1. Run `defaults write local.mm9-native RenderScale -int 0; defaults write local.mm9-native MSAA -int 4;
   defaults write local.mm9-native Anisotropy -int 16; defaults write local.mm9-native Trilinear -bool true`.
   Then start the game.
   - Main menu: is it sharp, and do the hover highlights sit on the buttons?
   - Start or load a game. Is the 3D view sharper with smooth edges, and are the portraits, compass and
     dialog boxes in their usual places? Try fullscreen (Ctrl+Cmd+F) and back.
   - Save (F5) and open Load Game: does the save show the right preview picture?
2. Run `defaults write local.mm9-native MaxFPS -int 120` and restart. Walk around outdoors for a minute.
   Does it feel smoother than before, without stutter? Does the clock in the top right advance at the
   normal speed (about 1 game minute per 2 real seconds)?
3. Optional: run `defaults write local.mm9-native TextureDump -bool true`, play for a few minutes, and
   check that `HDTextures/dump` fills with PNG files.
4. Undo everything: `defaults delete local.mm9-native RenderScale` (and the same for `MSAA`,
   `Anisotropy`, `Trilinear`, `MaxFPS` and `TextureDump`).

Further work that is not done:
- **Wider than 4:3:** the UI is fixed to 800×600, and changing that would mean UI changes.
- **Mipmaps for non-mipmapped 3D textures:** about 46 % of bindings are non-mipmapped. GPU mip generation
  is not possible for DXT formats.
- **Alpha-to-coverage for alpha-tested foliage under MSAA.**
- **An HD pack:** none is made here. The test replacements were tinted copies.
