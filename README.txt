MM9 NATIVE BUILDER
==================

This builds "MM9 Native.app": Might and Magic IX running natively on Apple Silicon, with no Wine
and no Rosetta. It holds a steady 60 fps where the Wine app manages about 23.

For educational and research purposes only. This package contains no game code, no game assets and
nothing derived from a game. You must bring your own legally purchased copy of Might and Magic IX
(GOG release 1.3).

Made entirely with AI: the code, the documentation and the logo were all produced with AI. The code
and docs were written by Claude through Claude Code, with a person directing the work and testing
the game. Treat it as an experiment and expect rough edges.

The builder contains no part of the game. It reads YOUR OWN copy of the game, translates the
game's code into a Mac program on YOUR Mac, and the result stays on your Mac. Because the app it
makes contains the game's code, never share that app. Friends run this builder themselves.


WHAT YOU NEED
-------------
- A Mac with Apple Silicon (M1 or later) and macOS 13 or later.
- The GOG version 1.3 of the game. The easiest way is to have the "Might and Magic IX" app (the Wine
  version) and to have started it once, so it has unpacked the game. The builder finds the game
  there by itself. Any other folder with the GOG 1.3 game files also works; it will ask.
  If you only have the GOG installer (.exe), the builder unpacks it with innoextract, which you
  install once with: brew install innoextract. (Or run the Wine app once, or pick an already
  unpacked game folder, and you do not need innoextract.)
- Apple's Command Line Tools. If they are missing, the builder opens Apple's install window. They
  take about 10 minutes to install and need no Apple ID. Then run the builder again.
- About 4 GB of free disk space and an internet connection. The builder downloads Ghidra (an
  analysis tool), a Java runtime and the Unicorn library once: 0.8 GB, kept for rebuilds.
- 10 to 25 minutes, depending on the Mac and the download speed.


BUILD IT
--------
1. Unzip this folder anywhere, for example in Downloads.
2. macOS blocks downloaded scripts. Open Terminal and paste this line, then press Return
   (it assumes the folder is in Downloads):

     xattr -dr com.apple.quarantine ~/Downloads/MM9-Native-Builder

3. Double-click "Build MM9 Native.command". A Terminal window shows each step. When it says
   "Done", your app is in the Applications folder in your home folder (~/Applications).

(Instead of steps 2 and 3, you can paste this in Terminal: bash ~/Downloads/MM9-Native-Builder/src/build.sh)


UPDATING
--------
The MM9 Native Updater (MM9-Native-Updater.dmg, from the Releases page) checks the MM9 Native you have,
shows what is out of date and why, and rebuilds it with its own, newer builder. Your game copy, saves and
settings stay; the saves are copied to ~/Library/Application Support/MM9 Native/backups first, and your
old app stays in place if the update fails.


PLAYING
-------
- Double-click "MM9 Native" (drag it to the Dock if you like). Cmd+Esc frees the mouse,
  Ctrl+Cmd+F switches fullscreen, and Cmd+Q quits.
- The native game uses its own copy of the game folder:
    ~/Library/Application Support/MM9 Native/game
  Saves are in its SaveGames folder. Saves you already had in the Wine app are copied once, when
  you first build. After that the two apps keep separate saves.
- Movies (logo and intro) need ffmpeg (brew install ffmpeg). Without it, the game skips them.
- Building again keeps your native saves and settings.


IF SOMETHING GOES WRONG
-----------------------
The builder says which step failed and shows the last lines of its log. Send this file to whoever
gave you the builder:
    ~/Library/Application Support/MM9 Native/logs/build.log
It holds tool output and file names only, nothing from the game.
If the game itself misbehaves, send ~/Library/Application Support/MM9 Native/logs/play.log.


REMOVING IT
-----------
Delete "MM9 Native.app", the folder ~/Library/Application Support/MM9 Native (this deletes your
native saves!) and the tool cache ~/Library/Application Support/MM9 Native Builder (1.2 GB). You can delete the
tool cache at any time; the builder downloads the tools again if you rebuild.


ADVANCED
--------
Settings are environment variables, listed at the top of src/build.sh. Examples: MM9N_GAME (the game
folder), MM9N_APPDIR (where the app goes), and MM9N_KEEP_WORK=1 (keep the 1 GB of intermediate files).
Licences: LICENSES/. The builder's own code is MIT. It uses parts of Fallout-NV-MacOS (MIT).
