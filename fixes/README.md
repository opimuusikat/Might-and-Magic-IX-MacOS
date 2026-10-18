# In-game bug-fix variants

Each folder here is one downloadable fix set for the native game, listed in `index.json`. The MM9 Native
Updater shows the last 5 for its builder version, what the player has installed, and lets them pick one.
The installer picks the newest variant marked stable by itself.

A variant holds the **full** set of changed `host/` files (not a diff), so it stands alone and includes the
fixes before it. Build-level work (recompiler, `build.sh`, tools) does not belong here: it goes in `src/`
with a new `BUILDER_VERSION`. Variants name the builder they were made for and are ignored by other builders.

Make one with `dev/fix.sh` (see the top of that script), then commit and push this folder.
The files are downloaded from the `main` branch and checked against the SHA-256 in `index.json` before use.
