# Changelog

One section per builder version, newest first. The heading must be `## <version>` and match
`BUILDER_VERSION` in `src/manifest.sh`: the MM9 Native Updater shows the section for its own
version on its welcome page. Keep each line short and in plain words, one fix per line.

To ship a fix: change the code, add a line here, bump `BUILDER_VERSION`, run `dev/make_updater.sh`
(and the installer script), then publish a GitHub release with a higher tag.

## 1.3

- Fixed: Cancel in the installer and updater now stops the whole build at once, and closing the window no longer leaves a build running in the background.
- Fixed: if replacing the app fails, your previous MM9 Native is put back instead of being lost.
- Fixed: the updater no longer starts a full rebuild just because ffmpeg is installed and everything is up to date.
- Fixed: the installer no longer gets stuck on the Installing page after Cancel.
- Fixed: dropping a file on the installer before accepting the notice no longer skips the notice.

## 1.2

- New: MM9 Native Uninstaller (red window). Moves MM9 Native, its tools and settings to the Trash; your saved games stay unless you tick them.
- The uninstaller can also remove the Wine version of the game, only if you tick it.
- The updater is now a green window, so you can tell it apart from the blue installer.
- The updater shows what is new in its version on its first page.
- The updater lets you choose an in-game bug-fix version from the last 5 published.
- Switching bug-fix version takes a minute or two: the compiled game code from your last build is kept and reused.

## 1.1

- Graphics options in the game: Options > Video Options has Resolution, Anti-aliasing, Sharp Textures, Smooth Mipmaps, HD Textures and Frame Rate. Cmd+, opens them over the game.
- HD textures load by the texture's file name; you can make your own pack from your copy of the game.
- Original Textures option: 32-bit textures stay 32-bit.
- Fixed: long play sessions could stop the game because texture slots were never reused.
- Fixed: Direct3D cull mode and colour-key render state are now handled.
