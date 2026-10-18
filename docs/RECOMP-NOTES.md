# Native recompile of Might and Magic IX: Milestone 0 (feasibility)

Date: 2026-10-17/18. Scope: measure whether MM9 (GOG 1.3 / TELP 1.3a, LithTech, 32-bit x86 Windows)
can be statically recompiled to native arm64 macOS, so it runs without Wine or Rosetta. Nothing in
`src/`, `dist/`, `build.sh`, `QUEUE.md` or the owner's game folder was changed. All work products are in
`build/recomp-work/`. They are derived from the game and must never be published or put in `dist/`.

## Verdict: GO for M1, time-boxed

On everything measured here, MM9 is a good recompile target. Every number below is measured
unless it says "estimate".

1. **The lifter already works on MM9's code.** With the Fallout-NV-MacOS toolchain (Ghidra P-code → C
   → arm64, differential test in Unicorn), **8,774 of 8,816 testable entry points (99.5 %) match the
   original exactly**, flags included. Leaf functions: 4,588 of 4,607 (99.6 %; FNV's own M0 was 99.3 %).
   0 crashes. 15 of the 42 mismatches are flags that the x86 manual defines as *undefined*.
2. **No SIMD and no tricks.** The five game modules contain **0 MMX, 0 3DNow!, 0 SSE, 0 CPUID, 0 RDTSC**
   instructions: integer plus x87 only. There is no runtime-generated or self-modifying code. No
   C++ exception can be thrown (no RTTI type data, no `_CxxThrowException`). In a traced load +
   play run the game raised **no exceptions of its own**.
3. **The "D3D7 fixed-function → Metal" problem is small.** A Wine trace of real gameplay shows d3d.ren
   does its own transform & lighting on the CPU. Every vertex reaches D3D already in screen space
   (`XYZRHW`, 2 vertex formats, lighting off, clipping off). 97 % of draws are triangle fans, and
   three quarters of all draws have ≤ 4 vertices.
   The game sets only 24 render states and 18 texture-stage states. That is a single ubershader,
   not a fixed-function T&L emulator.
4. **There is a measured performance case.** That CPU-side T&L is x87 code, and x87 under Rosetta 2 is
   very slow. d3d.ren's own 4×4 matrix multiply runs in **2,330 ns under Rosetta vs 150 ns recompiled
   natively (15× faster)**, before any emitter optimisation. The shipped app's main thread sits at
   98–99 % CPU (QUEUE.md), so this is the most likely source of the lag. This is not yet proven:
   the share of frame time spent in x87 was not measured (see "Not measured").

Why time-boxed: the remaining work is real (multi-module loader, Win32/GDI shims, DirectDraw/D3D7 on
Metal, Miles audio). The plan below puts a hard performance gate early in M1. The Wine app in
`dist/` stays the shipping path until a native build beats it at the bench spot.

**Stop criteria:** stop and keep the Wine app if (a) M1's headless gate shows the recompiled engine
not clearly faster per frame than Wine at worlds\bootcamp, or (b) M1 does not reach the main menu
within ~5 weeks.

## Setup

| item | value |
|---|---|
| Machine | an Apple Silicon Mac |
| Ghidra | 12.1.4 (Homebrew formula) on openjdk@21 21.0.12 |
| Toolchain | github.com/thetheoryofR/Fallout-NV-MacOS @ ff8e0d79 (MIT): `DumpPcode.java`, `FixNoReturn`, `ResolveJumpTables`, `FixEntries`, `emit.py`, `build.sh`, `difftest.py` |
| Second reference | github.com/TalhaMudo/NFSU2Recomp @ dbd21e02 (MIT), runtime read for API coverage |
| Python | 3.14.7 venv: unicorn 2.1.4, numpy 2.5.4, capstone 5.0.7, pefile 2024.8.26 |
| Wine (traces only) | the shipped app's Wine 11.0 + our wow64cpu.dll, private prefix, APFS clone of the game dir |

Input SHA-256 (first 16 hex; full values in `build/recomp-work/out/`): lithtech.exe `4e9ddd2b69db934e`,
d3d.ren `f4c708f55d2c6ca6`, cshell.dll `678700ff1cc795ae`, object.lto `b1271f37e5314281`,
clientfx.fxd `d158abcb6aef362f`. A bring-your-own-game builder must check these exact files.

## 1. The code

The brief named four core modules. The runtime trace showed a fifth one that must also be
recompiled: **clientfx.fxd**, the client effects DLL that cshell loads.

| module | file | .text | functions | leaf | x86 insns | x87 insns (fns) | MMX/3DNow!/SSE | indirect calls | indirect jumps (unresolved) | SEH-frame fns |
|---|---|---|---|---|---|---|---|---|---|---|
| lithtech.exe (engine) | 647 KB | 527 KB | 4,475 | 893 | 184,808 | 12,682 (676) | 0/0/0 | 3,451 | 74 (29) | 47 |
| d3d.ren (renderer) | 680 KB | 576 KB | 1,112 | 317 | 155,254 | **37,678** (222) | 0/0/0 | 1,473 | 40 (0) | 11 |
| cshell.dll (client game) | 971 KB | 763 KB | 4,408 | 803 | 223,535 | 12,674 (508) | 0/0/0 | 7,711 | 259 (34) | 214 |
| object.lto (server game) | 2.16 MB | 968 KB | 8,851 | 1,630 | 281,735 | 11,549 (694) | 0/0/0 | 8,139 | 210 (23) | 806 |
| clientfx.fxd (effects) | 549 KB | 494 KB | 1,188 | 206 | 59,362 | 1,702 (103) | 0/0/0 | 714 | 62 (7) | 92 |
| **total** | | **3.3 MB** | **20,034** | **3,849** | **904,694** | **76,285** | **0** | **21,488** | **645 (93)** | **1,170** |

- Function counts are after Ghidra auto-analysis plus FNV's repair passes, which added 1,149 / 288 /
  1,092 / 3,006 / 172 functions found through vtables and code pointers. FNV's game has 93,500
  functions; MM9 has about a fifth of that.
- All five are MSVC 6.0 (linker 6.0) builds with a **statically linked CRT** (no msvcrt.dll import).
  There is no RTTI anywhere (0 `.?AV` type names).
- The four DLLs all prefer base 0x10000000 and all have relocations. lithtech.exe is fixed at
  0x400000. A native build picks four distinct bases and applies relocations at build time.
- d3d.ren is a quarter x87 by instruction count. That is the software T&L (section 8).
- Not disassembled after the repair passes (padding excluded): 5.2 / 8.9 / 13.2 / 8.6 KB in the first
  four modules (about 1–1.7 % of .text). clientfx.fxd has a 235 KB block of embedded debug type data
  (member names, header paths, no relocations in or out), not code. Relocated pointers into
  un-disassembled .text total 15 / 314 / 217 / 104 (d3d.ren, cshell, object.lto, clientfx). Most are
  switch tables. This is the upper bound on missed entry points that M1's boundary repair must handle.

Two middleware DLLs were also measured, to decide between recompiling and reimplementing them:

| module | functions | x86 insns | SIMD | decision |
|---|---|---|---|---|
| MSS32.DLL (Miles 6) | 1,036 | 73,074 | 18 MMX insns in 1 fn, CPUID | reimplement its API (84 entry points used), see M3 |
| BINKW32.DLL | 640 | 58,705 | **4,146 MMX** in 43 fns, CPUID, RDTSC | do not recompile; native Bink decoder or no movies |

## 2. Imports by API family, and what actually loads

Static imports (pefile), number of imported functions:

| module | kernel32 | user32/gdi32 | DDraw/D3D | DInput | DSound | Miles | Bink/Smack | winsock / DPlay | winmm | other |
|---|---|---|---|---|---|---|---|---|---|---|
| lithtech.exe | 102 | 30 + 15 | – | 1 (`DirectInputCreateA`) | – (via Miles) | **84** `_AIL_*` | 15 + 7 by GetProcAddress | 19 / 3 (ordinals) | 1 | ole32 3 |
| d3d.ren | 62 | 7 + 0 | **3** (`DirectDrawCreateEx`, `DirectDrawCreate`, `DirectDrawEnumerateA`) | – | – | – | – | – | 1 | – |
| cshell.dll | 81 | 21 + 3 | – | – | – | – | – | – | 13 (mixer/aux/mci) | advapi32 5, version 3 |
| object.lto | 65 | – | – | – | – | – | – | – | 1 | advapi32 3, version 3 |
| clientfx.fxd | 78 | – | – | – | – | – | – | – | – | – |

- The union across the five modules plus ltmsg.dll is **320 distinct Win32 imports**. 159 of those
  names already appear in the FNV and NFSU2 runtimes (kernel32 111 of 118, user32 34 of 50). The gaps
  are GDI text (16 of 18 missing: lithtech draws text with `CreateFontA`/`TextOutA` into DIB
  sections), winmm, version.dll and all of Miles. "Appears by name" is a string match, not a
  verified implementation.
- All Direct3D 7 use goes through COM vtables obtained from `DirectDrawCreateEx`. Section 8 lists the
  methods that are actually called.
- **Modules loaded at runtime** (Wine `+loaddll`, start into worlds\bootcamp): lithtech.exe,
  d3d.ren (loaded more than once, at two different bases: mode enumeration loads and unloads it),
  cshell.dll, object.lto,
  clientfx.fxd, cres.dll / sres.dll (resource-only, no code), ltmsg.dll, mss32.dll with all 11 `.m3d`
  providers and MP3DEC.ASI, and Binkw32.dll. **Never loaded:** IMA.DLL, Imusic25, Msynth25, Am18,
  IMRT25, EaxMan.dll, CDAUDIO.DLL, Smackw32.dll. Music is 17 MP3 files played through Miles.
- **Used at runtime** (Wine `+winsock,+dplay,+dinput,+dsound,+ole`, 75 s): **no socket or DirectPlay
  calls** (single-player runs client and server in-process). DirectInput is used for buffered device
  data (5,752 `GetDeviceData`). DirectSound is used only by Miles (23k buffer Locks). No game-requested COM class appeared in the
  `+ole` trace; the only classes created were Wine's own audio stack.

## 3. CPU features

| class | lithtech | d3d.ren | cshell | object.lto | clientfx |
|---|---|---|---|---|---|
| x87 | 12,682 | 37,678 | 12,674 | 11,549 | 1,702 |
| MMX / 3DNow! / SSE / SSE2 | 0 | 0 | 0 | 0 | 0 |
| CPUID / RDTSC | 0 | 0 | 0 | 0 | 0 |
| LOCK-prefixed / XCHG / CMPXCHG | 4 | 2 | 4 | 4 | – |
| string ops (REP MOVS etc.) | 2,862 | 235 | 1,200 | 2,973 | – |

The emitter skips 1 function out of 21,787 entry points (`FFREE`, in lithtech). The only x87 semantics
that mattered were the rounding control and 80-bit stores (section 7).

## 4. SEH and exceptions

- **C++ exceptions: none can be thrown.** 1,057 functions set up MSVC C++ EH frames (FuncInfo magic:
  22 / 1 / 193 / 787 / 59). That is `/GX` destructor bookkeeping. No module has RTTI type descriptors
  or a `_CxxThrowException`. The only `RaiseException` call site in each module is the CRT's
  floating-point error path.
- **`__try/__except`** (`__except_handler3`): 15 / 8 / 12 / 11 / 15 functions. `SetUnhandledExceptionFilter`
  is called only from the same pair of CRT functions near the end of each module's code.
  `IsBadReadPtr`/`IsBadWritePtr`/`IsBadCodePtr` have 1–2 call sites per module.
- **At runtime** (Wine `+seh`, 75 s of load + play): the only exceptions were
  `DBG_PRINTEXCEPTION_C` (356, Wine's implementation of the game's `OutputDebugStringA`) and Wine's
  own WoW64 unwinds. There were no access violations, no float exceptions and no C++ exceptions.
- Consequence: the recompiled code keeps the FS:[0] chain in guest memory exactly as the original
  does. `RaiseException`/`RtlUnwind` can start as "log and stop", which is what FNV does today.
  Real SEH dispatch is only needed for crash paths.

## 5. Runtime-generated code: none

There is no `VirtualProtect` or `FlushInstructionCache` import. Every `VirtualAlloc` call site in
the five modules passes `PAGE_READWRITE` (these are the CRT small-block heap). No section is both
writable and executable, and no `GetProcAddress` string names a memory-protection API.

## 6. How lithtech.exe loads the other modules

Everything crosses module boundaries as plain function pointers and C++ vtables. A static build
links all five modules into one binary, and indirect calls go through one guest-address → host-function
table (FNV's `rt_call`).

- **Renderer:** `FUN_00450007` calls `LoadLibraryA(<*.ren found by search>)`, then
  `GetProcAddress("RenderDLLSetup")`. That export writes **33 function pointers** into the engine's
  render struct (offsets 0x6c–0xfc). d3d.ren calls back into the engine through the lower part of the
  same struct. `FUN_00429ca1` loads the .ren separately, calls `GetSupportedModes`/`FreeModeList` and
  unloads it. That is why d3d.ren is loaded more than once, so a reload must re-initialise its data
  sections.
- **Client and server game code:** a generic loader (`FUN_004015c1` LoadLibrary, `FUN_0040160c`
  `GetProcAddress("SetInstanceHandle")`, `FUN_004016a7` GetProcAddress by name) loads cshell.dll and
  object.lto. `GetClientShellFunctions` / `GetServerShellFunctions` each return a create/destroy pair
  for the game's shell object. `ObjectDLLSetup` returns the server's class-definition list. After that
  the engine calls the shells through vtables (180 / 437 distinct `call [reg+off]` slots in cshell /
  object.lto), and the game calls the engine through its interface vtables.
- **Effects:** cshell calls `LoadLibraryA` on clientfx.fxd and then GetProcAddress for 6 `fx*`
  functions.
- **Middleware:** mss32.dll is a static import, and Miles loads its own providers. Binkw32.dll gets 15
  GetProcAddress names, smackw32.dll 7, EaxMan.dll `EaxManagerCreate`, IMA.DLL `MusicDLLSetup`, and
  launch.dll (absent) `GetLithTechCommandLine`. lithtech already copes with missing Bink/Smack
  ("video playback disabled").

## 7. Lifting and differential testing

Pipeline per module: Ghidra import + analysis (15–45 s), FNV repair passes (3–5 s), P-code dump
(5–8 s), `emit.py` (5–8 s), clang -O1 build of the whole module (5–7 s), difftest (2–11 s with 11
workers). **The whole pipeline takes about 3 minutes for all five modules on this machine.** Generated
C: 52 / 43 / 56 / 73 / 16 MB (240 MB). Dylibs: 6.1 / 4.6 / 7.5 / 9.6 / 1.5 MB.

### Harness changes (copies in `build/recomp-work/scripts/fnv-patched/`; upstream untouched)

| change | why |
|---|---|
| load each DLL at its own PE image base | upstream assumes 0x400000 |
| fresh Unicorn instance per function, whole image restored per trial | **Upstream bug:** state leaked between functions in one worker. The same function had 5/6 valid trials fresh and 0/6 after 400 other functions. Two identical runs differed on 532 functions; after the fix, all 16 repeated runs match entry for entry. |
| x87 registers zeroed per trial | determinism |
| "strict" emitter: load all flags at entry, store at every return, reload after calls | Upstream only stores flags a caller reads, so every leaf showed "flags-only". Strict mode tests flags exactly. |
| "RC" emitter fix: x87 `ROUND` honours the guest FPU control word | **Upstream bug:** `nearbyint()` uses the host's round-to-nearest. MSVC 6 compiles every `(int)float` cast as a call to `__ftol`, which switches the x87 to truncate, so results were off by one. A one-line fix: fails 18→9 in lithtech, 7→2 in object.lto. |

**Sanity check:** three passing d3d.ren functions were mutated by hand (FSUB→FADD, one load offset,
one flipped ZF). The harness flagged all three (2 fail, 1 flags-only).

### Results (strict flags + RC fix, whole module built, deterministic over two runs)

| module | entry points | testable | exact | flags-only | fail | untestable | exact % | leaf exact % |
|---|---|---|---|---|---|---|---|---|
| lithtech.exe | 4,596 | 1,734 | 1,715 | 10 | 9 | 2,862 | 98.9 | 98.5 (n=677) |
| d3d.ren | 1,125 | 497 | 490 | 0 | 7 | 628 | 98.6 | 100.0 (n=209) |
| cshell.dll | 4,824 | 1,914 | 1,908 | 1 | 5 | 2,910 | 99.7 | 99.7 (n=885) |
| object.lto | 9,934 | 4,183 | 4,177 | 4 | 2 | 5,751 | 99.9 | 99.8 (n=2,558) |
| clientfx.fxd | 1,308 | 488 | 484 | 0 | 4 | 820 | 99.2 | 99.3 (n=278) |
| **total** | **21,787** | **8,816** | **8,774** | **15** | **27** | **12,971** | **99.5** | **99.6 (n=4,607)** |

- "Entry points" includes secondary entries inside functions (FixEntries). "Untestable" means every
  trial of the *original* faulted in Unicorn: random pointers, or calls into Win32. That is 12 % of
  leaves and 75 % of non-leaf functions. A trace-seeded state would raise coverage. Untestable
  is not a lifter failure, but it is also not verified.
- **Pass/fail rates the brief asked for (leaf functions):** pass 99.6 %, fail 0.4 % of testable;
  untestable 615 of 5,222 leaf entry points (11.8 %). In the leaf-only build (FNV's exact M0 method,
  where tail-jump targets are missing) the fail column rises to 9 / 0 / 4 / 74 / 51. Those extra
  fails are one-instruction `JMP` thunks to functions outside the leaf set: a harness artefact.

**What the 42 non-exact results are:**

| n | class | matters? |
|---|---|---|
| 15 | flags the x86 manual leaves undefined (OF after multi-bit shifts and SHLD, SF/ZF after IMUL) | no: compiled code never reads them |
| 14 | the function calls an address with no recompiled function: function-boundary gaps, plus random code pointers that happened to run in Unicorn | yes: M1 boundary repair plus the FNV runtime's interpreter fallback |
| 6 | statically linked CRT x87 math helpers: 80-bit `FSTP/FLD TBYTE` and the transcendental dispatch (the lifter carries x87 as doubles) | small: replace those CRT helpers with host libm |
| 2 | x87 zero-divide status bit read via `FNSTSW` after a random divide (d3d.ren, result off by 4) | low |
| 1 | `FSIN` of a random 1e35 argument (x87 leaves \|x\| ≥ 2^63 unreduced) | no |
| 4 | memory/value differences not yet diagnosed (2 in lithtech, 1 cshell, 1 clientfx) | check in M1 |

In the leaf-only build, 134 of the 138 fails are the one-instruction `JMP` thunk artefact. The other 4
(CRT x87 helpers, the FSIN case) also fail in the whole-module build above.

## 8. Direct3D 7 use at runtime (Wine `+ddraw` trace, 722 frames: load + bootcamp)

Per frame in gameplay (last 434 frames): **935 `DrawPrimitive`**, 494 `SetTextureStageState`, 483
`SetRenderState`, 173 `SetTexture`, 53 surface `Lock`, 39 `BltFast`, 39 vertex-buffer `Lock`, 27
`DrawPrimitiveVB`, 3 `SetTransform`, 1 `Clear`, 1 `Flip`.

- **Geometry arrives pre-transformed.** Vertex formats: `XYZRHW|DIFFUSE|SPECULAR|TEX1` (489,305 draws)
  and `…|TEX2` (55,347). Those are the only two. `LIGHTING=0`, `CLIPPING=0`. d3d.ren transforms,
  lights and clips every vertex itself in x87 code, and D3D only rasterises.
- Primitives: `TRIANGLEFAN` 528,573, `TRIANGLELIST` 16,079 (plus 16,079 through system-memory vertex
  buffers, which Wine forwards to DrawPrimitive). 76 % of draws have ≤ 4 vertices. These small
  draws are what wined3d pays for per call. A Metal backend can append them to one per-frame buffer.
- **Render states set: 24.** Blending (SRC ZERO/ONE/SRCALPHA, DEST ONE/SRCCOLOR/INVSRCALPHA), alpha
  test (GREATER), Z enable/write (LESSEQUAL), fill mode, fog colour/start/end/table mode (fog almost
  always off), dither, Gouraud shading, cull none, perspective, specular off, colour key off,
  antialias off.
- **Texture-stage states set: 18.** Stage 0: `MODULATE` (texture × diffuse) for colour and alpha,
  point or linear min/mag filter, nearest mip level. Stage 1: `DISABLE`, `ADDSIGNED` (detail textures)
  or `ADD`.
- Texture formats created: A1R5G5B5 (1,761), X8R8G8B8 (1,230), R5G6B5 (558), **DXT5 (333)**,
  A4R4G4B4 (282), **DXT1 (226)**, A8R8G8B8 (6). Z buffer: 32-bit. Mip chains go through
  `GetAttachedSurface`.
- 2D: `BltFast` (flags WAIT), `Blt` with source colour key (`DDBLT_KEYSRC`, `SetColorKey` SRCBLT), and
  surface Lock/Unlock for UI and text.

Distinct API entry points in the whole trace: **66**. IDirect3DDevice7 17, IDirectDrawSurface7 16
(+6 through the v1 interface), IDirectDraw7 12 (+4 v1, used for mode enumeration), IDirect3D7 5,
IDirect3DVertexBuffer7 3, plus `DirectDrawCreate`/`DirectDrawCreateEx`/`DirectDrawEnumerateExA`. The
full list with counts is in `build/recomp-work/trace/methods.txt`. Add the 2 FVFs, 24 render states,
18 texture-stage states and 7 pixel formats above, and that is the whole contract a Metal backend
must meet. Metal on Apple Silicon has BC1/BC3 and 16-bit packed formats, so most textures should
upload without conversion (16-bit bit orders still to be checked).

## 9. Performance evidence: x87 under Rosetta 2

| test | Rosetta 2 (x86_64) | native arm64 |
|---|---|---|
| T&L kernel, C, x87 (`long double`) | 753–776 ns/vertex | – |
| same, VC6-style hand-written x87 (float operands), CW 0x27F / 0x37F | 707–714 / 701–710 ns/vertex | – |
| same kernel, SSE2 | 2.37–2.42 ns/vertex | 1.62–2.38 ns/vertex |
| **d3d.ren 0x10001a00** (4×4 matrix multiply, 197 insns, 193 x87): original bytes vs recompiled `g_10001a00` | **2,320–2,354 ns/call** | **149–162 ns/call** |

Both sides of the last row return identical output. x87 under Rosetta costs about 12–15 ns per
instruction (2,330 ns / 193 in the matrix function, ~710 ns / 49 in the kernel), roughly 300× the
SSE2 version of the same kernel. The M0 emitter is unoptimised (every value is a masked 128-bit
integer, x87 stack shuffles are explicit, -O1), and it still runs this MM9 function 15× faster than
Rosetta. Combined with section 8 (all T&L on the CPU in x87) and the 98–99 % main thread, this is the
strongest argument for a native build. Caveats: the Rosetta runs were 64-bit processes. Wine runs MM9
through Rosetta's 32-bit path, which was not timed separately.

Strategic note: Apple said at WWDC 2025 that Rosetta 2 stays a general-purpose tool through macOS 27.
After that only a subset aimed at older games remains, and whether Wine's 32-bit path keeps working
then is unknown. A native build does not depend on Rosetta.

## 10. Hard parts, sized by the measurements

1. **Multi-module build (M1, medium).** Rebase the four 0x10000000 DLLs to distinct bases and
   re-analyse them at those bases. Use one dispatch table across 3.3 MB of code (FNV's O(1) table
   covers only 0x400000–0x1000000, so it needs extending). Write a loader shim for LoadLibrary,
   GetProcAddress and FreeLibrary over static modules, with DllMain and TLS, and data reset when
   d3d.ren reloads. Close ~650 candidate missed entries, keeping the interpreter fallback.
2. **DirectDraw 7 + D3D7 → Metal (M2, medium, down from "biggest").** The subset in section 8: one
   ubershader with a small state key (blend, alpha test, Z, stage-1 op, filters), fans converted to lists, per-frame vertex ring buffer,
   DXT/16-bit textures, colour-keyed blits, surface locks. No fixed-function T&L, lighting or clipping.
3. **Win32 + GDI text (M1, medium).** 320 imports, half named in the reference runtimes. GDI text into
   DIB sections and `AddFontResourceA` with the game's TTF map to CoreText. Window and message loop go
   to Cocoa. There are three `CreateThread` sites plus critical sections and events.
4. **Miles (M3, medium).** 84 `_AIL_*` entry points: 2D/3D samples, streams (MP3 music and voices),
   ADPCM/ASI decode helpers, 3D provider enumeration. Reimplement them on AVAudioEngine and
   AudioToolbox instead of recompiling Miles and its 11 DirectSound/EAX providers.
5. **SEH (low).** The FS:[0] chain is maintained by the recompiled code; dispatch is needed only for
   crash paths (section 4).
6. **Bink (low).** 5 `.bik` movies. Use FFmpeg's Bink decoder (LGPL, dynamic) or skip them; lithtech
   already runs without Bink.
7. **x87 fidelity (low).** The RC fix is done; replace the 80-bit CRT helpers with libm (section 7).

## 11. Milestone plan (estimates)

These estimates are mine, not measurements. They assume the owner works with agent sessions. One
calibration point: NFSU2Recomp's dated screenshots show its first window on 2026-08-25, main menu and
first 3D race on 2026-08-26, and rendering fixes continuing to 2026-09-24. Its lifter work before
that is undated.

| milestone | contents | exit test | estimate |
|---|---|---|---|
| **M1 boot to main menu** (Win32 + DirectDraw 2D) | rebased five-module build and loader shim; kernel32/user32/advapi32/version shims (reuse FNV/NFSU2, MIT); GDI text on CoreText; Cocoa window/input; DirectDraw surfaces/blits/flip on Metal; D3D7 device creation answering the enumeration calls; Miles/Bink stubs. **Gate in week 1–2:** boot headless into worlds\bootcamp with a null D3D7 that accepts everything and measure main-thread ms/frame against Wine's at the same spot | main menu renders and responds; headless gate clearly faster than Wine | 3–5 weeks |
| **M2 D3D7 → Metal, gameplay** | the section 8 subset; batching; DXT and 16-bit textures; Z; alpha test/blend/fog; texture locks; gamma | walk bootcamp with picture parity against Wine screenshots; bench fps at the owner's spot and bootcamp | 2–4 weeks |
| **M3 audio, input, video** | Miles API on AVAudioEngine (3D positional, MP3 streams); DirectInput keyboard and mouse look; Bink via FFmpeg or skip; save/load | the QUEUE.md 10-minute owner play test passes as it does on the Wine app | 2–3 weeks |
| **M4 bring-your-own-game builder + .app** | builder checks the five SHA-256s, runs lift → emit → clang on the user's Mac (needs Xcode Command Line Tools, plus Ghidra+JDK ~1.5 GB or an embedded Sleigh library), links our runtime, ad-hoc signs the .app; no game-derived bytes ship | a friend builds from their own GOG install and plays | 1–2 weeks |

Total: about 8–14 weeks. Language: the generated code is C by construction. The host runtime can be
C/Objective-C to reuse the FNV/NFSU2 code (both MIT), or Rust for new parts at the cost of that
reuse. Recommendation: C/Objective-C for M1.

## Not measured (next numbers to get)

- Share of main-thread time spent in x87 under Wine. Get it at the M1 headless gate by comparing the
  recompiled engine's ms/frame with Wine's.
- Rosetta's 32-bit (WoW64) x87 speed, as opposed to the 64-bit speed timed here.
- Main-menu-only D3D/DDraw usage: the trace started directly in the world with `+runworld`.
- Functions that only a trace-seeded state could test (the 12,971 untestable).

## Reproduce

Everything is under `build/recomp-work/` (3.8 GB: Ghidra projects 133 MB, generated C 753 MB, libraries
179 MB, traces 2.2 GB including the cloned game dir and Wine prefix). Raw traces are gzipped there
(the 748 MB ddraw trace compresses to 8 MB).

```bash
cd "build/recomp-work"
scripts/ghidra_import.sh d3d.ren && scripts/ghidra_dump.sh d3d.ren
venv/bin/python -I scripts/fnv-patched/emit_strict_rc.py out/d3d_ren/all.jsonl gen/d3d_ren-allrc --extra out/d3d_ren/extra_entries.json
JOBS=12 repos/Fallout-NV-MacOS/recomp/build.sh gen/d3d_ren-allrc lib/d3d_ren-allrc
venv/bin/python -I scripts/fnv-patched/difftest_mm9.py inputs/d3d.ren lib/d3d_ren-allrc/librecomp.dylib out/d3d_ren/all.jsonl.regs.json results/d3d.json --jobs 11
SECS=120 scripts/trace_d3d7.sh && venv/bin/python -I scripts/d3d7_trace_stats.py trace/ddraw-trace.log out/d3d7_trace_stats.json
```

The trace script needs `trace/game` (an APFS clone, `cp -cR` of the game dir, so the owner's copy is
never written) and `trace/pfx` (a fresh prefix with `EmulateModeset=y`, as the launcher sets up). Both
already exist. It opens a game window for `SECS` seconds and stops only that prefix's wineserver.

Other scripts: `scripts/pe_census.py` (imports/exports/strings), `scripts/ghidra/MM9Census.java`
(ISA/SEH/vtable/import call-site census), `scripts/ghidra/DecompNamed.java` (exports decompiled to
`out/*/decomp_exports.c`), `bench/` (Rosetta benchmarks; `bench/fn_10001a00.h` holds game bytes,
local only). Summaries: `out/m0_summary.json`, `out/m0_difftest_final.json`,
`out/d3d7_trace_stats.json`.

## M1 gate result (headless, 2026-10-18)

**Gate passed.** The natively recompiled engine boots straight into worlds\bootcamp and renders the
spawn view with **about 1.0 ms of main-thread time per frame**. The Wine app needs **about 43 ms**
at the same spot (23.4 fps with the main thread at 98–99 %). That is roughly **40× less time per
frame**. The native side uses a null Direct3D device, so this compares CPU work only (caveats below).

What ran: one arm64 executable (`build/recomp-work/m1/bin/mm9host-o2`). It holds all five
recompiled modules, one dispatch table and the host runtime. It was started from the APFS clone
`trace/game` with `+runworld worlds\bootcamp` and the owner's settings (800x600x32, MaxFPS 60). It
gets through the statically linked CRTs, the headless window, the loader shim (cshell.dll,
clientfx.fxd, d3d.ren and object.lto), DirectInput and DirectDraw 7/Direct3D 7 on the null device.
Then it loads the world and renders frames until stopped (150 s was the longest run). The engine
reports "initialized in 2.95 seconds"; under Wine the same message says 9.32 s. No trap fired, and
no unimplemented import or COM method was called. The game's own debug output matches Wine's,
including the same NPC script compile warnings and errors.

| bootcamp spawn view | Wine app (`bench.sh`, OpenGL) | native, MaxFPS 60 (owner setting) | native, uncapped (`+MaxFPS 0`) |
|---|---|---|---|
| fps | 23.4 (22.7–23.4 across bench runs) | 57.8 (capped) | **984–1,025** (3 runs × 30 s) |
| wall ms/frame | 42.7 | 17.3 (cap) | **0.97–1.02** |
| main-thread CPU ms/frame | ≈ 42 (main thread 98–99 %) | 3.99 (23 % busy, includes the frame limiter's polling) | 0.97–1.01 (100 % busy) |
| draws/frame (DrawPrimitive + …VB) | 794–795 + 22–24 | 785 + 11–12 | same |

**Same-scene check.** I ran Wine again from the same clone and settings, with `+ddraw` filtered to
the draw calls (`m1/scripts/wine_drawcount.sh`). At the spawn it draws 794–795 DrawPrimitive plus
22–24 DrawPrimitiveVB per frame for frames 6–59. Native draws 785 + 11–12, the same scene within
about 4 % of total draws. Later in that Wine run the view changed in steps, up to 2,700 draws. That
looks like stray mouse input: the native run stays at 796 draws for 150 s of game time with no
input. The bench's fps stayed flat at 23–24 for its whole run, so the bench measured a stable view.

**Where the native frame goes** (`sample`, uncapped, 10 s, top-of-stack): d3d.ren 71 % (its x87
software T&L), lithtech.exe 16 %, object.lto 5 %, cshell.dll 1.5 %, host runtime and null device
about 4 % (dispatch, import thunks, state tracking, vertex copy).

Caveats:
1. **Null device.** Rasterisation, texture upload and the GPU driver cost nothing here. Wine's 43 ms
   includes wined3d's front end, with its ~3,300 `cs_mt_finish` spin-waits/s. The null device
   copies every DrawPrimitive's vertices into a ring buffer, as a batching backend would. Encoding
   ~800 small draws into Metal adds main-thread time in M2. It would have to exceed ~40 ms per frame
   to cancel the gain.
2. **Sound is off.** Miles is stubbed and `AIL_waveOutOpen` fails, so the engine takes its "no sound
   device" path. Also not modelled: Bink (absent; lithtech already copes), input (none, so the
   player stands at the spawn) and GDI text (TextOutA draws nothing; extents are approximate).
3. **Only the spawn view was timed.** A synthetic keyboard/mouse pan did not turn the camera: the
   bindings now enumerate and the key reaches the game's data-format offset, but the game ignores
   it. I did not investigate further, so heavier views were not timed natively.
4. **Interpreter fallback ran 9 times, all during init.** Eight roots are in d3d.ren's CRT init
   (0x10005ff4, 0x100215a4, 0x10060fa4, 0x10074294, 0x1007f4e4, 0x10082bb4, 0x10084a50, 0x100859e0)
   and one is lithtech 0x47c2b1. None is in the frame loop. They should go to `FixEntries` as
   learned entries.
5. **d3d.ren was loaded once.** The `+runworld` path skips the mode-enumeration load and unload.
   The reload path (restore the pristine image, then DllMain) is implemented but was not exercised.
6. **Build settings.** clang -O2 with `RT_FIXED_MEM` and FNV's default x86 memory ordering (every
   guest access acquire/release). Normal flag liveness plus the RC fix (`scripts/fnv-patched/emit_rc.py`;
   FFREE is emitted as a no-op, which un-skips one lithtech function).

How it was built (all under `build/recomp-work/`, all game-derived, never publish):
- **Rebase.** d3d.ren stays at 0x10000000, cshell.dll goes to 0x10100000, object.lto to 0x10300000
  and clientfx.fxd to 0x10700000 (`m1/scripts/rebase.py`). `pefile.relocate_image` cannot be used:
  it also shifts the import lookup table and corrupts the imports. The script applies only the
  HIGHLOW relocations and the ImageBase field. The three DLLs were re-imported into Ghidra at their
  new bases, followed by the FNV repair passes and DumpPcode (`m1/scripts/ghidra_m1.sh`: 20–40 s
  import, 3–5 s fix, 3–4 s dump each). lithtech.exe and d3d.ren reuse the M0 dumps.
- **Emit and compile.** 21,785 entry points, 0 skipped. All generated C compiles in 30 s with 12 jobs
  (`m1/scripts/build_gen.sh`).
- **One table.** One merged guest→host table with one dense array per code range: 0x400000–0x4B0000
  and 0x10000000–0x10900000 (`m1/host/rt_dispatch_m1.c`, `m1/scripts/merge_tables.py`).
- **Host.** `m1/host`, about 3,200 lines of C. Copied from FNV and adapted (MIT): heap, sync/thread,
  file, text and fallback shims. New: the loader shim (match by PE timestamp + image size, because
  the engine loads `DATA\cshell.dll` and `DATA\object.lto`; resource-only CRes/SRes/ltmsg mapped as
  data; LoadString, FindResource, FormatMessage), kernel32, user32/gdi32, advapi32/winmm/wsock32/
  dplayx stubs, Miles stubs, null DirectInput, null DirectDraw 7/Direct3D 7 (all 66 traced entry
  points plus the rest of each vtable) and frame statistics.

Bugs found on the way, which M1 keeps:
- lithtech loops on `while (ShowCursor(FALSE) >= 0)`, so ShowCursor needs a real display counter.
- cshell ends its loading-screen thread with `TerminateThread`. The shim now stops the thread at its
  next import call.
- d3d.ren refuses to turn 2D surfaces into texture tiles if the device reports
  `D3DPTEXTURECAPS_SQUAREONLY`. It then Blts every HUD element with an EndScene/BeginScene pair
  around it, about 120 scene breaks per frame.
- The engine rewrites autoexec.cfg. The runner restores the owner's copy before every run.

Reproduce:

```bash
cd "build/recomp-work"
venv/bin/python -I m1/scripts/rebase.py inputs m1/inputs && cp inputs/lithtech.exe m1/inputs/
for m in cshell.dll object.lto clientfx.fxd; do m1/scripts/ghidra_m1.sh $m; done
# emit: venv/bin/python -I scripts/fnv-patched/emit_rc.py out/<mod>[_m1]/all.jsonl gen/m1/<mod> --extra out/<mod>[_m1]/extra_entries.json
JOBS=12 m1/scripts/build_gen.sh -O2 && m1/scripts/build_host.sh o2
M1_QUIET=1 m1/scripts/run.sh 120 m1/logs/gate.log +MaxFPS 0      # prints the [m1] summary after 30 s in the world
m1/scripts/wine_drawcount.sh 100 m1/logs/wine_draws.txt            # same-scene check (opens a Wine window)
```

Logs: `m1/logs/run15{a,b,c}.log` (uncapped), `run18.log` (capped), `sample16.txt` (profile),
`wine_draws.txt` (Wine at the spawn).

## M1 progress: main menu on Metal (2026-10-18)

**The M1 exit test is met.** The native build starts like the shipped app (plain `lithtech.exe`, no
arguments) and opens a macOS window. The main menu renders correctly and responds to mouse and
keyboard. Checked in that window and in offscreen frame dumps:
- **Main menu:** hover highlights work.
- **Options:** the Options screen and the Game Options screen render, including their text.
- **New game:** party creation works, including the "use the generated default party" dialog.
- **Into the world:** a new game loads into the world and plays.

The same Metal path also draws the 3D world, so part of M2 already works. bootcamp renders its
textured interior, NPC models, lighting and HUD. In the live window the game holds its MaxFPS 60
cap (57–58 fps) at up to ~2,100 draws/frame, with the main thread using ~4–7 ms per frame. Wine
manages about 23 fps at the spawn.

What was added (all in `build/recomp-work/m1/host`, now about 4,100 lines):
- `metal.m`, the Metal backend for the D3D7 subset in section 8:
  - XYZRHW vertices go into a per-frame ring buffer (triangle fans become lists).
  - One ubershader covers two texture stages (the D3D7 colour/alpha ops and args), specular, fog and
    alpha test.
  - Pipelines are cached by blend state, depth state by Z enable/write/func, samplers by filter and
    address mode.
  - Textures: DXT1/3/5 upload directly as BC1/2/3; 32-bit and the three 16-bit formats map to Metal
    formats with swizzles. Mip chains are uploaded from guest memory after Unlock.
  - Clear and colour-fill become pass clears. CPU pictures blitted onto the back buffer are drawn as
    quads. Flip copies the back buffer to the window's drawable.
  - Window, event pump and keycode table follow FNV's `d3d9_metal.m` (MIT). The env switches are
    `M1_OFFSCREEN=1` and `M1_DUMP=<frames>` (PNG dumps) for testing, and `M1_NULL=1` for the gate's
    null device.
- **Input:**
  - Cocoa mouse and keyboard feed DirectInput with the game's own data-format offsets; the menu
    cursor follows DirectInput deltas. They also become Win32 messages (mouse moves and buttons on a
    virtual cursor; key down/up and characters).
  - Enumerated device objects carry the names the saved bindings use (`##x-axis`, `##205`).
  - The mouse is captured while the window is active. Cmd+Esc releases it; closing the window quits.
- **Bugs found:**
  - D3D's A1R5G5B5 is Metal `BGR5A1Unorm`. FNV's table maps it to `A1BGR5Unorm`, which puts alpha in
    bit 0 and turned the menu into speckles.
  - The menu UI ignores WM_MOUSEMOVE; it only uses DirectInput.
- **Not needed for the menu:** GDI text. The UI uses the engine's bitmap fonts, and TextOutA was not
  called on any screen tried.

Known gaps (next M1/M2 work):
- **Sound:** none (Miles is still stubbed).
- **Movies:** no intro movies (Bink absent).
- **Blts from the back buffer:** back buffer to system-memory copies (e.g. save-game thumbnails) read
  stale memory, and back buffer to primary copies are ignored.
- **Colour-key render state:** `COLORKEYENABLE` is not honoured.
- **Culling:** cull mode is always none (d3d.ren culls on the CPU).
- **Resizing:** the window keeps a fixed 800×600 back buffer.
- **Saves:** they go to the clone (`trace/game/SaveGames`), not the owner's install.
- **Settings:** the launcher restores the owner's autoexec.cfg on every start, so in-game settings
  changes do not persist yet.
- **Fullscreen:** none yet.
- **Untested here:** Load Game, the Bink intro, long play sessions.

Play it (uses the APFS clone, never the owner's install):

```bash
"build/recomp-work/m1/scripts/play.sh"
```

Screenshots: `m1/shots/bootcamp_world.png`, `m1/shots/window_party_dialog.png` (frame dumps).

## Sound: Miles on CoreAudio (2026-10-18)

The native build now has music and sound effects. `m1/host/audio.c` implements the 84 `_AIL_*`
calls lithtech.exe imports, on one CoreAudio output unit with a software mixer: 44.1 kHz float
stereo, resampling by linear interpolation, Miles volume/pan, loop blocks and counts, and a soft
knee instead of hard clipping. Miles' DLLs and providers are not used.

How the engine drives Miles, from its decompiled sound code (`m1/decomp/lt_sound.c`):
- **Effects and voices** are 2D samples. The engine parses the WAVs itself, then calls
  `set_sample_type` + `set_sample_address` + `resume_sample`, and does its own volume and pan.
- **The engine times sounds itself** with `AIL_ms_count`; it never polls sample status.
- **Music** is MP3 streams by file name (`Music\MM9-SongNN.mp3`). They are decoded on a background
  thread with AudioToolbox and start playing before decoding finishes.
- **3D samples** are used only when the configured provider name matches one exactly. The owner's
  config says `"3DSoundProviderName" "default"`, which matches none, so the game runs its 2D path,
  as it does under Wine. The 3D path is implemented anyway (one software provider, "Miles Fast 2D
  Positional Audio": distance gain, listener-relative pan, obstruction/occlusion) but is unused
  with these settings. EAX is reported as absent.
- **Formats:** every WAV in SOUNDS.REZ and VOICES.REZ is plain PCM (2,002 + 1,819 files; nearly all
  16-bit mono 22 kHz). IMA-ADPCM and MP3-in-WAV (`AIL_decompress_ADPCM/ASI`, `set_sample_file`)
  are implemented for completeness. One MS-ADPCM file (0x0002) is not supported.

Checked by tracing and an output level meter (`M1_TRACE_AUDIO=1`):
- The main-menu music plays.
- Menu clicks play their click effect over the music.
- bootcamp plays its music and the opening sound.

Not checked yet: a long play session (voice lines, footsteps, combat). The Old Man's dialogue lines
appear to be text-only.

Cost: bootcamp with real Metal rendering (offscreen) and sound on runs at **727 fps uncapped,
1.38 ms/frame**, against 1.0 ms with the null device and 42.7 ms under Wine.

`M1_NOSOUND=1` turns sound off.

## Playability polish (2026-10-18)

The native build is now set up for comfortable play: a double-clickable launcher, settings that
persist, native fullscreen, a working Load Game screen with save thumbnails, the Bink movies with
sound, and the loading screen. Everything is under `build/recomp-work/` (game-derived; never publish or copy to `dist/`). The
Wine app stays the shipping path.

**1. Launcher: `build/recomp-work/m1/MM9 Native.app`.** Double-click it, or drag it to the Dock. The
bundle holds only an Info.plist, a script that runs `m1/scripts/play.sh`, and an icon (the Wine app's
icon with a green "NATIVE" ribbon). It is ad-hoc signed. Rebuild it with `m1/scripts/make_launcher.sh`.
`play.sh` now `exec`s the game, so the app and the game are one process; the Dock icon comes from
`M1_ICON`, which the launcher sets. The owner double-clicked it and confirmed it works.

**2. Settings persist.**
- **Separate settings file.** `play.sh` no longer copies the owner's `autoexec.cfg.before-perf` over
  the config on every start. The player's settings live in `trace/game/autoexec.cfg.play`, which is
  seeded from `before-perf` on the first start. That copy is put in place before the game starts. A
  watcher copies the engine's rewritten `autoexec.cfg` back after the game exits, but only if the game
  rewrote it (not after a crash) and the file still contains its `rangebind` lines.
- **Benchmarks unchanged.** `run.sh` still resets the config to `before-perf` on every run, for
  reproducible benchmarks.
- **Clean quit.** Closing the window, Cmd+Q and the Quit menu item all post WM_CLOSE to the game.
  From there: DefWindowProc → WM_DESTROY → the game's PostQuitMessage → engine shutdown, which writes
  autoexec.cfg → ExitProcess. Before this change, closing the window called `exit(0)` and the
  settings were lost. If the game is still running 10 s after WM_CLOSE, the host exits anyway.
  `M1_SCRIPT` has a new `q` command that triggers the same quit.
- **Verified offscreen through `play.sh`:**
  - Ticking Game Options → Invert Mouse, then Apply and quit, wrote `"InvertMouse" "1.000000"`.
  - After a restart, with `autoexec.cfg` reset to `before-perf` in between as a benchmark run would
    do, the box was still ticked.
  - All 51 `rangebind` lines survive. The owner's `before-perf` copy already lacks the 52nd
    (ToggleCamera, F3) that `autoexec.cfg.orig` has.
- **Things to know:**
  - Extra `+Var value` arguments to `play.sh` are also written into the saved settings, as the engine
    does with its command line.
  - Quitting from the main menu stores `CursorCenter 0`, the menu's own value.

**3. Fullscreen.**
- **How to toggle.** Use the green button, Ctrl+Cmd+F, or Window → Toggle Full Screen (native macOS
  fullscreen, `m1/host/metal.m`).
- **Scaling.** The 800×600 back buffer is scaled to keep its aspect ratio, with black bars
  (`kCAGravityResizeAspect` with a black layer and window). The window is now resizable and stays 4:3.
- **Start in fullscreen.** The last state is remembered in the defaults domain `local.mm9-native` (key
  `StartFullscreen`). `M1_FULLSCREEN=1`/`0` overrides it for one start, and
  `defaults write local.mm9-native StartFullscreen -bool true` sets it.
- **Shortcuts.** Cmd+key presses go to a small menu bar (Hide, Quit, Minimize, Toggle Full Screen)
  and never reach the game. Cmd+Esc still releases the mouse, and a click captures it again.
- **Checked.** The owner confirmed fullscreen, starting in fullscreen, and Cmd+Esc in fullscreen.

**4. Load Game and save thumbnails.**
- **GPU readback.** New `gpu_readback` in metal.m: a Lock of the render target, or a Blt/BltFast from
  it into a system-memory surface, copies the back buffer texture (with everything encoded so far)
  into the surface's guest memory. The copy is converted from BGRA8 to 32-bit, 565 or 555. The
  thumbnail code Locks the 800×600 back buffer once per thumbnail pixel, which is 30,000 Locks for
  200×150. So the readback is cached on a back-buffer generation counter, bumped by clears, draws and
  blits: one GPU round trip per save.
- **The real bug behind the empty list.** The host ignored `SetCurrentDirectoryA`. Load Game changes
  into `C:\MM9\savegames\` and then lists `*.hdr`, so it found nothing. The host now keeps a guest
  current directory (`shims_files.c`). Relative paths resolve against it, `..` above the game root is
  kept as on Windows, and GetCurrentDirectory and GetFullPathName report it.
- **Save format.** `<name>.HDR` holds the world name at 0, then a 200×150 32-bit thumbnail at 0x58,
  stored column by column (120,000 bytes), then the party.
- **Verified with frame dumps:**
  - The autosave written on entering bootcamp and an F5 quicksave both store the right picture.
  - Load Game lists both saves, with the preview, game time, date and place.
  - Load returns to the world.
- **Also changed.** CPU Blts now scale (nearest pixel) when the source and destination rects differ.
  `M1_TRACE_DD=1` also logs Blt, BltFast, Lock and GetDC calls. Failed FindFirstFile patterns are
  logged as `[file]`.
- **Cost.** bootcamp uncapped with Metal and sound runs at 762–781 fps; it was 727. The readback runs
  only at saves.

**5. Movies (Bink).**
- **What it is.** `m1/host/bink.c` implements the 13 Binkw32 calls that lithtech's `BinkVideoMgr`
  looks up. Their use is decompiled in `m1/decomp/lt_bink.c` and `lt_bink2.c`.
- **Decoding.** Done by the `ffmpeg` command-line tool (Homebrew FFmpeg 8.1) in child processes. Raw
  BGRA frames come over a pipe. The soundtrack comes as 16-bit 44.1 kHz stereo PCM over a second pipe
  into a new pipe-stream voice in audio.c, which plays at the game's master volume and starts with
  frame 1.
- **Licence.** Nothing from FFmpeg is linked into the host; Homebrew's build is `--enable-gpl`. If no
  ffmpeg binary is found, `LoadLibrary("Binkw32.dll")` fails as before and the engine skips its movies.
  `M1_NOMOVIES=1` turns movies off, and `M1_FFMPEG=<path>` picks the binary.
- **Engine model.** BinkOpen → a DDraw surface of the movie's size → per frame: Wait, Lock, DoFrame,
  CopyToBuffer (32-bit, 555 or 565), Unlock, BltFast (centred) or Blt (stretched) onto the back
  buffer, NextFrame. The movie counts as finished at `FrameNum == Frames - 1`. Only Width, Height,
  Frames and FrameNum are read from the BINK structure. BltFast from a CPU surface onto the back
  buffer used to be ignored and now draws.
- **Verified offscreen with dumps and the audio level meter:**
  - A plain start plays 3DOLogo (81 frames), then New World Logo (195 frames in 13 s), then
    intro.bik (1,451 frames), in real time with sound.
  - Esc during the 3DO logo goes straight to the main menu; Esc ends the intro.
  - The main menu now shows the game's own **View Intro** button, which appears only when Bink loads.
    View Intro, then Esc, returns to the menu.
  - No ffmpeg processes are left behind.
- **Checked by the owner.** Audio and video stay in sync in the window.
- **Not checked yet.** Shipwreck.bik and LoseGame.bik. They are played by their own movie screens in
  cshell, not at party creation: shipwreck most likely after the training area, LoseGame on defeat.
  Also unchecked: the texture-video path (565 copies; not used so far).

**6. Loading screen.**
- **What was wrong.** The "Loading . . ." screen (the map, with a small ship that sails as loading
  progresses) never appeared. cshell's loading thread draws it with 2D DirectDraw: the background
  picture and the ship are blitted into the back buffer, and changed areas are copied to the primary
  (front) surface with Blt, never with Flip. The host ignored back buffer → primary copies, and drew
  colour-keyed sprites without transparency.
- **What changed.**
  - A Blt or BltFast onto the primary surface now shows the back buffer in the window
    (`gpu_show`, which presents like Flip but does not count a frame).
  - `DDBLT_KEYSRC` / `DDBLTFAST_SRCCOLORKEY` blits of CPU surfaces onto the back buffer use the
    source colour key: a BGRA copy with alpha 0 for key-coloured pixels, drawn with an alpha test.
  - The ship's background save and restore uses the back-buffer readback from item 4.
- **Verified.** Offscreen dumps of the shows (`M1_DUMP_SHOW=<n,...>` writes `m1_show_<n>.png`) show
  the loading screen with the ship drawn transparently. Shows happen only during loads, and bootcamp
  still runs at 724 fps uncapped. The owner confirmed it in the window when starting a new game.

**Still missing (next):**
- **Menu bar name.** The menu bar may show the process name `mm9host-o2`, because the game runs from
  `m1/bin`.
- **Movies every start.** The full logo and intro sequence is about 115 s unless skipped with Esc.
  That is the game's own behaviour, as under Wine. `M1_NOMOVIES=1` skips them; a launcher option
  could be added.
- **Earlier gaps still open:**
  - Saves still live in the clone (`trace/game/SaveGames`). Owner decision (2026-10-18): keep them
    separate from the real install at least until the native play test passes.
  - `COLORKEYENABLE`, cull mode, and back buffer → primary Blts.
  - A long play session.

## M4 plan: bring-your-own-game builder (2026-10-18, approved by the owner; built, see "M4 result" below)

Goal: a friend runs one tool on their own Mac, against their own GOG copy of the game, and gets
`MM9 Native.app`. Everything derived from the game is made on that Mac and stays there. What we
share contains only our own code, FNV's MIT code and download addresses with checksums.
Ideally the owner's 10-minute native play test passes before this is handed to friends.

### What the builder must reproduce

The steps below are today's build (sections "M1 gate result" to "Playability polish"), made into
one script. File and function counts are from the current build.

| # | step | today | builder |
|---|---|---|---|
| 1 | **Check inputs.** Five files from the GOG 1.3 install, SHA-256: `lithtech.exe` 4e9ddd2b69db934ecbd7399dd92992004e596907da4a214450f31c5dd39e56d8, `d3d.ren` f4c708f55d2c6ca666b4e550ecdc387df5ca6ddaa4c03ef6a6a5004a1c113805, `data/cshell.dll` 678700ff1cc795aeee49fe8427a42e1686d5a20dfdc1617eb46a8ef19f82f7ae, `data/object.lto` b1271f37e5314281035efe6425dd59051bb8a9b0271de0d75a5926a7bc37f162, `clientfx.fxd` d158abcb6aef362f80441dfb7584c350445d4ebaa1f380cacb6f424fe5d862df | by hand | refuse on any mismatch and name the file |
| 2 | **Rebase.** cshell → 0x10100000, object.lto → 0x10300000, clientfx → 0x10700000 (HIGHLOW relocations + ImageBase only); lithtech.exe and d3d.ren unchanged. Expected results: cshell fe1655d4…, object.lto 74b98dc6…, clientfx 36c1d785… | `m1/scripts/rebase.py` (needs pefile) | stdlib-only rewrite (no pip), output checked against those three hashes |
| 3 | **Ghidra, per module.** Import and auto-analysis; then `FixNoReturn`, `ResolveJumpTables` and `FixEntries` (writes `extra_entries.json`); then `DumpPcode … all`. Functions: 4,475 / 1,112 / 4,408 / 8,851 / 1,188 | `scripts/ghidra_import.sh` + `ghidra_dump.sh` (M0, lithtech and d3d.ren), `m1/scripts/ghidra_m1.sh` (the three rebased DLLs) | one script for all five; output hashes compared with the reference build (below) |
| 4 | **Emit.** `emit_rc.py <all.jsonl> gen/<mod> --extra extra_entries.json` (upstream emit.py + RC fix + FFREE no-op) → 21,785 entry points, 0 skipped | `scripts/fnv-patched/emit_rc.py`, `flaglive.py` | the same files; stdlib Python, and they parse under the Python 3.9 that ships with the Command Line Tools |
| 5 | **Compile** generated C: `clang -O2 -DRT_FIXED_MEM -w -I<rt.h>`, all TUs except `table.c` | `m1/scripts/build_gen.sh` | the same, jobs = core count |
| 6 | **Merge tables** → one `table.c` (21,785 functions), compiled `-O1` | `m1/scripts/merge_tables.py` | the same |
| 7 | **Host link.** `m1/host/*.c,*.m` (-O2) + module objects + `libunicorn.a` + Metal/QuartzCore/AppKit/ImageIO/UniformTypeIdentifiers/CoreGraphics/AudioToolbox/CoreAudio, `-Wl,-stack_size,0x10000000` | `m1/scripts/build_host.sh` (takes Unicorn from the Python venv) | the same, with Unicorn from the pinned wheel (below) |
| 8 | **App bundle.** Info.plist, a launcher script, an icon with a "NATIVE" ribbon, ad-hoc signed | `m1/scripts/make_launcher.sh` + `play.sh` (owner paths hard-coded; the icon from `src/AppIcon.icns`) | self-contained bundle (below); the icon is made from the friend's own `goggame-1207658978.ico` |
| 9 | **Smoke test.** | owner played it | the new binary starts offscreen, without sound or movies, and must reach the main menu |

**Reference hashes.** The builder also carries the SHA-256 of each module's `all.jsonl` and of
the merged function list, from the owner's build. A hash reveals nothing about the game, so it can
ship. If a friend's hashes all match, their Ghidra produced exactly the owner's tested input, and
the only remaining difference is their clang version. If they differ, the builder warns and carries
on. The end-to-end test shows whether a clean Ghidra run reproduces today's dumps exactly.

### What ships and what is made on the friend's Mac

| ships (our code and MIT code; about 1 MB) | made only on the friend's Mac (game-derived; never shared) |
|---|---|
| the builder script, the README and the reference hashes | the verified copy of their game folder |
| `m1/host/*` (host runtime, about 5,000 lines; ours plus FNV-derived files, MIT) | the rebased modules |
| FNV's `rt.h` and the Ghidra scripts `FixNoReturn`, `ResolveJumpTables`, `FixEntries`, `DumpPcode` (MIT, with FNV's LICENSE) | the Ghidra projects and P-code dumps (290 MB) |
| `emit_rc.py`, `flaglive.py` (FNV-derived, MIT) | the generated C (228 MB), the objects and the merged table |
| our `rebase` / `merge_tables` / icon tools | the linked binary (37 MB) |
| | the app with its icon |

Not shipped, and not needed: `m1/decomp` (decompiled game code), `bench/` (holds game bytes),
traces, shots and logs. Not shipped either; the builder downloads them: Ghidra (Apache-2.0),
Temurin JDK (GPLv2 with Classpath Exception) and Unicorn (GPLv2). Unicorn is linked statically
into a binary that never leaves the friend's Mac, so its GPL terms are not triggered. FFmpeg
(movies) is optional and only used when the friend already has it installed.
**A leak check runs before every package build:** it fails if any 128-byte run of the five game
modules appears in any packaged file, or if a packaged file is a PE image.

### Prerequisites on the friend's Mac

| what | size | how |
|---|---|---|
| Apple Silicon Mac, macOS 13 or later | – | checked first; Intel is untested and refused for now |
| Xcode Command Line Tools: clang, the macOS SDK (Metal/AppKit headers), codesign, python3 3.9 | about 0.7 GB download, 1.9 GB installed | `xcode-select --install` (a system dialog; no Xcode or Apple ID needed) |
| Ghidra 12.1.4, the exact release used here (`ghidra_12.1.4_PUBLIC_20260921.zip`, sha256 ddac49f9…) | 570 MB download, 770 MB unpacked | downloaded by the builder from GitHub, checked against its SHA-256 |
| Temurin JDK 21.0.12.1 for arm64 (sha256 3623232f…) | 200 MB download, about 330 MB unpacked | downloaded by the builder from Adoptium's GitHub releases |
| Unicorn 2.1.4 wheel (`cp37-abi3-macosx_11_0_arm64`, sha256 d6c93e0f…) for `libunicorn.a` | 12 MB | downloaded from PyPI and unzipped (no pip) |
| optional: ffmpeg for the movies | – | `brew install ffmpeg`; without it the game skips its movies |
| disk during the build | about 1.2 GB for tools (kept for rebuilds; deletable) + about 1 GB of work files (deleted afterwards) + the game copy (an APFS clone takes almost nothing; a normal copy takes 1 GB) | checked before starting |
| memory | Ghidra heap 4 GB per module, one module at a time (6 GB today) | 8 GB Macs work, but slower |

No Homebrew, no admin password and no Apple ID. Downloads go through `curl`, so the downloaded
tools carry no quarantine flag. The tools are cached in `~/Library/Caches/MM9 Native Builder`.

**Ghidra + JDK versus an embedded SLEIGH lifter: recommend Ghidra + JDK, pinned.**
- **Ghidra is what was validated.** The 99.5 % difftest and the owner's play test both ran on
  Ghidra's output. Its auto-analysis finds the 20,034 functions, recovers switch tables and marks
  no-return calls. FNV's repair passes build on that analysis.
- **SLEIGH alone is not a replacement.** An embedded SLEIGH library (libsla or pypcode, about
  20 MB) only translates instructions to P-code. We would have to rewrite function discovery,
  jump-table recovery and no-return analysis ourselves. That is several weeks of work, and the
  only way to check it would be against Ghidra on the owner's Mac.
- **Shipping Ghidra's results breaks the rule.** We could ship Ghidra's findings as address lists
  so that friends only need SLEIGH. But those lists are derived from the game, which the rule
  forbids.
- **The cost is a one-time download** of about 0.8 GB, plus 1.1 GB on disk until the friend
  deletes it. Pinning the exact release keeps a friend's analysis identical to ours.
- Revisit SLEIGH only if the download turns out to stop friends in practice.

### Where the game and the saves live on the friend's Mac

- **Input (read-only):** by default the folder that the Wine app unpacks,
  `~/Library/Application Support/Might and Magic IX/game`. Any other folder that holds
  `lithtech.exe` can be picked in a dialog. A GOG installer `.exe` is accepted only if `innoextract`
  is installed; otherwise the builder tells the friend to run the Wine app once.
- **Working copy:** the whole folder is cloned to `~/Library/Application Support/MM9 Native/game`
  (`cp -c`, with a plain copy as fallback). The game runs there, the way `trace/game` works for
  the owner, so the original is never written.
- **Saves:** they live in `…/MM9 Native/game/SaveGames`. Saves that already exist come along with
  the copy once; after that, the native and Wine games keep separate saves (as the owner decided
  for their own setup). Rebuilding keeps them: it never replaces an existing working copy.
- **Settings:** the same edits as the Wine launcher (800×600, MaxFPS 60, AutoDeactivate 0) go
  into the copy's `autoexec.cfg`. The engine then owns the file. Before each start, the launcher
  keeps a copy of the last good file and restores it if the engine left the file without its
  `rangebind` lines (for example after a crash).
- **The app:** `MM9 Native.app` goes to `~/Applications` (or a folder the friend picks). Inside:
  `Contents/MacOS/MM9Native` (launcher script), `Contents/MacOS/MM9 Native` (the game binary, so
  the menu bar shows that name), `Contents/Resources/modules/` (the five rebased modules the host
  maps at start), the icon, and `DO-NOT-SHARE.txt`. It is ad-hoc signed. A locally built app
  carries no quarantine flag, so it opens with a double-click.

### Packaging and failure reporting

- **Package:** `MM9-Native-Builder.zip`, about 1 MB, with `Build MM9 Native.command`, `README.txt`,
  `LICENSES/` and `src/`. A `.command` rather than a builder .app, because:
  - the Terminal window shows each step as it runs, the compiler included;
  - an .app would hide that and still needs the same quarantine workaround;
  - `bash build.sh` in Terminal also works and is never blocked by Gatekeeper.

  The README gives the same `xattr` line as the Wine app's README. The shippable sources live in
  a new top-level folder `native-builder/`. The zip goes to `build/native-builder/` for the owner
  to put next to the Wine zip; `dist/` and `build.sh` are left alone.
- **Steps and timing:** each step prints its name and how long it took. Its full output goes to
  `~/Library/Application Support/MM9 Native/build.log`.
- **On failure:**
  - the builder names the step and its log, shows the last 30 lines and opens a dialog;
  - early checks give plain answers: Command Line Tools missing (the `xcode-select --install`
    line), not Apple Silicon, game folder not found, wrong game version (which file, which version
    is needed), not enough disk, download or checksum failure (retried once);
  - the friend sends `build.log` to the owner. It holds tool output and file names only, no game
    bytes.
- **Rerun:** steps whose outputs are present and match are skipped.

### Estimates

| piece | my work | build time on the friend's Mac (test Mac measured; base M1 estimate) |
|---|---|---|
| preflight, game check, working copy | 0.5 day | seconds (clone) |
| tool download and cache, pinned | 0.5 day | 2–10 min, depending on the connection (0.8 GB) |
| rebase without pefile, checked against the three hashes | 2 h | 1 s |
| Ghidra stage for all five, smaller heap | 0.5 day | about 3.5 min here; about 6–8 min on a base M1 |
| emit + compile + table + host link | 0.5 day | about 1.5 min here; 3–5 min on a base M1 |
| app bundle, icon, launcher, settings guard | 0.5 day | seconds |
| smoke test, failure reporting, rerun skipping | 0.5 day | about 30 s |
| leak check, zip, README, licences | 0.5 day | – |
| end-to-end test from a clean folder (owner's GOG folder as input, read-only) | 0.5 day | – |
| **total** | **about 4 days of session time** (inside M4's 1–2 week estimate; a friend's first real build is the rest) | **about 10–25 min**, mostly download and Ghidra |

## M4 result: the builder works end to end (2026-10-18)

**The builder is done and passed its end-to-end test.** I unzipped the shareable zip into an empty
folder and ran it against the owner's Wine-app game folder, read-only. It downloaded its tools fresh
and built `MM9 Native.app` in **196 s**. The app reached the main menu, and every intermediate
result matched the owner's tested build:
- all five Ghidra P-code dumps and `extra_entries.json` files are byte-identical;
- the emitter produced 21,785 functions with 0 skipped;
- the merged function table is identical.

So a friend whose build reports "identical to the reference build" has the owner's play-tested
build. The only difference left is their clang version.

**Where things are:**
- **Shippable sources:** `native-builder/`.
  - `Build MM9 Native.command`, `README.txt`, `LICENSES/`.
  - `src/build.sh`: the builder, about 550 lines of bash 3.2, the version macOS ships.
  - `src/manifest.sh`: the pinned input hashes, tool URLs and hashes, and the reference hashes.
  - `src/tools/`: rebase without pefile, table merge, icon tools.
  - `src/recomp/`: `rt.h`, `emit_rc.py`, `flaglive.py`.
  - `src/ghidra_scripts/`: FNV's four scripts.
  - `src/host/`: a copy of `m1/host`.
- **Owner-only tools in `native-builder/dev/`:**
  - `package.sh` builds the zip, and refuses if the leak check fails;
  - `leak_check.py` is the leak check itself;
  - `sync_from_m1.sh` copies `m1/host` and the emitter in again after other sessions change them.
- **The zip:** `build/native-builder/MM9-Native-Builder.zip`: 136 KB, 40 files, sha256 `3a57b6b0…`.
  `dist/` and `build.sh` were not touched; putting the zip next to the Wine zip is the owner's call.
- **The test folder** `build/recomp-work/m4-e2e/` (the test app, its game copy, the tool cache and
  the logs of all six runs; 2.4 GB) was deleted after the test, at the owner's request.

**Final clean run, step by step** (test Mac; the Ghidra step ran 3 modules at a
time with a 6 GB heap):

| step | time | result |
|---|---|---|
| check the Mac, find and verify the game, APFS-clone it | 0–1 s | all five SHA-256s match |
| download Ghidra 12.1.4, Temurin 21.0.12.1 and Unicorn 2.1.4 (0.8 GB); build Ghidra's decompiler | 48–58 s | all three checked against their SHA-256s |
| rebase | <1 s | identical to the three expected hashes |
| Ghidra: import + analysis, repair passes, dump | 80 s | 5 of 5 identical to the reference |
| emit (Python 3.9.6 from the Command Line Tools) | 28 s | 21,785 functions, 0 skipped |
| compile (103 files, 12 jobs) | 30 s | |
| link | 2 s | merged table identical to the reference |
| app + smoke test | 8 s | 43 MB app, ad-hoc signed; main menu at 131 draws/frame, 57 fps, with the same 9 init-time fallback roots as the owner's build |

**Also tested:**
- **The owner's game folder was not changed.** I compared a fingerprint (mtime, size and mode) of
  all 163 entries before the first run and after the last one.
- **The app's own launcher works.** `Contents/MacOS/MM9Native`, run offscreen: exit 0, main menu,
  `play.log` in the right place, settings guard in effect. The engine rewrites `autoexec.cfg` in its
  own order; the content is the same and all 51 key bindings stay.
- **A rebuild works (about 15 s).** Tools reused, Ghidra/emit/compile skipped, the existing game copy and
  its saves kept (a canary file in SaveGames survived), the old app replaced, work files removed.
- **The early errors are clear.** No game found, a folder without `lithtech.exe`, and a changed
  `d3d.ren` each stop with a plain message that names the file or folder.
- **8 GB Macs are covered.** object.lto (the largest module) analysed with a 4 GB heap gives
  byte-identical output, with a peak resident size of 2.2 GB.
- **The leak check catches leaks.** In a positive control it caught a planted 200-byte run of
  `lithtech.exe` and a PE file. It reports the real package clean (170,241 game chunks from 42
  files, 40 package files).
- **Saves came along.** Saves already in the Wine folder were copied into the native game copy.

**Four bugs found by the test and fixed:**
1. **The Ghidra release zip has no Apple Silicon decompiler** (`os/mac_arm_64/decompile`).
   - Without it, Ghidra skips decompiler-based switch recovery without failing. The first run came
     out with unresolved jump tables, 156 extra functions and 10 skipped by the emitter: a different,
     untested program.
   - Homebrew's Ghidra (the reference) compiles that native part itself.
   - Fix: the builder compiles it from the C++ sources in the zip, with `make ghidra_opt` and the
     Command Line Tools (about 15 s). It also stops if any Ghidra log says the decompiler is missing.
2. **Case-insensitive file names.** The launcher script `MM9Native` overwrote the game binary
   `mm9native` in the same folder. The binary is now `MM9NativeGame`, and the builder checks that it
   is an arm64 Mach-O.
3. **Parallel Ghidra runs raced** to create Ghidra's shared file-system cache on a fresh cache, and
   one import failed. Each module's Ghidra run now gets its own settings and cache folders.
4. **A path with a space** ("Application Support") split the table-merge arguments. They are now
   passed as a bash array.

**Changes from the plan:**
- **Name in the menu bar.** The game binary is `Contents/MacOS/MM9NativeGame`. Because it runs from
  inside the bundle, the bundle's name "MM9 Native" applies (not checked in a window).
- **Ghidra memory and parallelism.** Ghidra gets a 6 GB heap on Macs with 16 GB or more and 4 GB
  otherwise. It runs one module at a time per 12 GB of memory, up to 3 at once.
- **Package size.** The zip is 136 KB, not about 1 MB.
- **Leak check granularity.** The leak check matches 64-byte aligned chunks, so it catches any
  copied run of 127 bytes or more.
- **Settings regexes.** The settings edits also accept decimal values such as `"60.000000"`.

**Not tested yet:**
- **A friend's Mac:** another machine, a base 8 GB M1, a fresh Command Line Tools install, and a
  slow connection.
- **Gatekeeper on a downloaded zip:** quarantine, the `xattr` line and the double-click into Terminal.
- **The dialogs:** the folder/installer chooser and the failure dialog. All runs used `MM9N_DIALOGS=0`.
- **The GOG-installer path:** innoextract is not installed here.
- **Windowed play of the built app.** All runs here were offscreen. Running the builder again
  (about 3.5 min) gives an app to try.

**Open points for the owner:**
- **Copyright line.** Done: `LICENSES/LICENSE.txt` names Joosep Joost.
- **Where the zip goes.** Whether to ship the zip beside the Wine zip, and when: after the native
  10-minute play test, as planned.
- **GitHub.** `native-builder/` is a git repository, published (public) at
  https://github.com/opimuusikat/Might-and-Magic-IX-MacOS. It is laid out like Fallout-NV-MacOS:
  - README.md with the bring-your-own-game disclaimer, LICENSE and `.gitignore`;
  - a `.githooks/pre-commit` guard extended with MM9's module types (enabled in the local clone);
  - `.recomp.json`;
  - `docs/RECOMP-NOTES.md`: this file, made by `dev/sync_from_m1.sh`, which drops local paths, the
    test machine's model and OS version, and the build environment's sandbox notes.

  **Before publishing:**
  - An audit of every published file found no tokens, keys, emails, local paths or session
    identifiers, and the leak check found no game bytes. Every long hex string is a SHA-256
    checksum, and every URL is a public project or download page.
  - The code opens no network connections (the Winsock/DirectPlay imports are stubs that fail) and
    reads no credentials or keychain. The only program it starts is `ffmpeg`, with a fixed
    argument list.
  - The history was squashed into one clean commit, authored as Joosep Joost with the GitHub
    no-reply address.

  After a sync, commit with that identity and push; the guard runs on every commit.
- **Keeping the sources in step.** After `m1/host` changes, run `native-builder/dev/sync_from_m1.sh`
  and then `dev/package.sh`. The reference hashes in `src/manifest.sh` change only if the Ghidra
  scripts, the rebase, Ghidra itself or the emitter's function set change.
