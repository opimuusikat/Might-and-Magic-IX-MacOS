#!/bin/bash
# Build the static innoextract 1.9 (zlib licence) that the installer app bundles, for macOS 13+, arm64.
# Needs: Command Line Tools, cmake, and Homebrew's boost, xz and zstd (static libs). Output:
#   build/innoextract-build/innoextract-1.9/b/innoextract
# Boost 1.92's filesystem no longer pulls in directory_iterator by itself, hence the one-line patch.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"; W="$ROOT/build/innoextract-build"; mkdir -p "$W"; cd "$W"
[ -f inno.tgz ] || curl -sSL -o inno.tgz https://constexpr.org/innoextract/files/innoextract-1.9.tar.gz
[ "$(shasum -a 256 inno.tgz | cut -d' ' -f1)" = 6344a69fc1ed847d4ed3e272e0da5998948c6b828cb7af39c6321aba6cf88126 ] || { echo "bad checksum"; exit 1; }
rm -rf innoextract-1.9; tar xzf inno.tgz
/usr/bin/python3 - <<'P'
p='innoextract-1.9/src/stream/slice.cpp'; s=open(p).read()
s=s.replace('#include <boost/filesystem/operations.hpp>','#include <boost/filesystem/directory.hpp>\n#include <boost/filesystem/operations.hpp>',1); open(p,'w').write(s)
P
mkdir -p "$HOME/.mm9-static"; ln -sf /opt/homebrew/opt/zstd/lib/libzstd.a "$HOME/.mm9-static/"   # path without spaces
cd innoextract-1.9 && mkdir -p b && cd b
cmake .. -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=13.0 \
  -DUSE_STATIC_LIBS=ON -DCMAKE_PREFIX_PATH="/opt/homebrew/opt/boost;/opt/homebrew/opt/xz" \
  -DCMAKE_EXE_LINKER_FLAGS="-L$HOME/.mm9-static" > /dev/null
make -j"$(sysctl -n hw.ncpu)"
otool -L innoextract
