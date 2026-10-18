# MM9 Native Builder: pinned inputs, tools and reference hashes (sourced by build.sh).
# Hashes only: nothing here is derived from the game's bytes in a way that reveals them.

BUILDER_VERSION=1.0

# The five code modules of the GOG release (Might and Magic 9: Writ of Fate 1.3, installer
# setup_might_and_magic_9_writ_of_fate_1.3_(31712).exe), as paths inside the game folder.
GAME_FILES="lithtech.exe d3d.ren data/cshell.dll data/object.lto clientfx.fxd"
sha_game() {
  case "$1" in
    lithtech.exe)    echo 4e9ddd2b69db934ecbd7399dd92992004e596907da4a214450f31c5dd39e56d8 ;;
    d3d.ren)         echo f4c708f55d2c6ca666b4e550ecdc387df5ca6ddaa4c03ef6a6a5004a1c113805 ;;
    data/cshell.dll) echo 678700ff1cc795aeee49fe8427a42e1686d5a20dfdc1617eb46a8ef19f82f7ae ;;
    data/object.lto) echo b1271f37e5314281035efe6425dd59051bb8a9b0271de0d75a5926a7bc37f162 ;;
    clientfx.fxd)    echo d158abcb6aef362f80441dfb7584c350445d4ebaa1f380cacb6f424fe5d862df ;;
  esac
}

# The modules after tools/rebase.py (d3d.ren 0x10000000, cshell 0x10100000, object.lto 0x10300000,
# clientfx 0x10700000; lithtech.exe and d3d.ren keep their bases).
MODULES="lithtech.exe d3d.ren cshell.dll object.lto clientfx.fxd"
sha_rebased() {
  case "$1" in
    lithtech.exe) echo 4e9ddd2b69db934ecbd7399dd92992004e596907da4a214450f31c5dd39e56d8 ;;
    d3d.ren)      echo f4c708f55d2c6ca666b4e550ecdc387df5ca6ddaa4c03ef6a6a5004a1c113805 ;;
    cshell.dll)   echo fe1655d4c696c4d628fd1df7cc4eccf605a7de142442942f1c25ea0c5da8d6a2 ;;
    object.lto)   echo 74b98dc6fe4a67a2f49be6770888bb23429ea89d33cea3ff4133c56a67e82fa8 ;;
    clientfx.fxd) echo 36c1d7851bddcbba69668a2b20f4471384d6e06aff753a8ffc795f2db0cc8c79 ;;
  esac
}

# Reference build (the owner's tested build, 2026-10-18): Ghidra's P-code dump and FixEntries
# output per module, and the merged guest-address table. A mismatch is reported, not fatal.
sha_ref_dump() {
  case "$1" in
    lithtech.exe) echo 406a033b741eb76df65fbde1c9519577223acb230d73a79480c3db72173fbc69 ;;
    d3d.ren)      echo b0f762c4a1fac98d4915955106a9e7377af005d92090fa645deef686065d3dac ;;
    cshell.dll)   echo fe70851dcabdb4683da9a351d6618a9772116053460454335fe9b9c71eb3e877 ;;
    object.lto)   echo e0a2a3148ebd2dc78ec4ed6239ebc4df64f3a9e00511222450aa839c5f8a614b ;;
    clientfx.fxd) echo dc45b72fb133d1345f66f27bc5ad5674542c256938eb1e26a2bf06e18070c10a ;;
  esac
}
sha_ref_extra() {
  case "$1" in
    lithtech.exe) echo 572575f0e2c00efd75ae5467b23a400768ae77197f017843cd19dceb160877df ;;
    d3d.ren)      echo 79c181403057fa98fc7e26b28612624b143c8ed4e1d14b7a1036fe0c488aa5a7 ;;
    cshell.dll)   echo 21c46d50dde930422ce39570b33c87d1d26e32d742ef663f67eead83e2aa0198 ;;
    object.lto)   echo ce1bc795ba995ef9df8ffae208745122368229b24c4a505a60b8f65dc70dd0ed ;;
    clientfx.fxd) echo 989fd197dfdd2f074b06e83382f55db03faf0a3a413fabb002446d29d3497a08 ;;
  esac
}
REF_TABLE_SHA=555b44a4405c7726bfbdb42f450e21da2c1cf125f9ffbc4750aa71e8ce4e09f6
REF_FUNCTIONS=21785

# Tools, downloaded once into the cache and checked against these SHA-256s.
GHIDRA_URL="https://github.com/NationalSecurityAgency/ghidra/releases/download/Ghidra_12.1.4_build/ghidra_12.1.4_PUBLIC_20260921.zip"
GHIDRA_SHA=ddac49f903da9d5bac833e5cc79395098b9c33cfd3279be5f31bd00387d2d4db
GHIDRA_TOP=ghidra_12.1.4_PUBLIC
JDK_URL="https://github.com/adoptium/temurin21-binaries/releases/download/jdk-21.0.12.1%2B1/OpenJDK21U-jdk_aarch64_mac_hotspot_21.0.12.1_1.tar.gz"
JDK_SHA=3623232f33a9c3baadf304480b2535f9a3cba8a58d42ecbb438ba267315d9998
JDK_TOP="jdk-21.0.12.1+1"
UNICORN_URL="https://files.pythonhosted.org/packages/6c/ae/4943c6f8524d729ec7d5e69df6407ea05d710fe77471d91cecf3fc64eb57/unicorn-2.1.4-cp37-abi3-macosx_11_0_arm64.whl"
UNICORN_SHA=d6c93e0f60328d8f4a1792af3f834137a28050fcc2305f2ec01efe8558a9844e

# Optional movie support: a static ffmpeg for Apple Silicon (Martin Riedl's build server, ffmpeg 9.0.2, GPL build;
# Apple-signed). Downloaded only when the player asks for it (MM9N_FFMPEG_DOWNLOAD=1), checked against this SHA-256,
# and run as a separate program: nothing from it is linked into the game.
FFMPEG_URL="https://ffmpeg.martin-riedl.de/download/macos/arm64/1789931890_9.0.2/ffmpeg.zip"
FFMPEG_SHA=c8ed4c4e6978a03c485edbfe4e0a5dc2380f8a30bba5150531b31b094492d924
