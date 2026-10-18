#!/bin/bash
# Double-click to build "MM9 Native.app" from your own copy of Might and Magic IX (see README.txt).
cd "$(dirname "$0")" || exit 1
/bin/bash ./src/build.sh "$@"
rc=$?
echo
read -r -p "Press Return to close this window. " _
exit $rc
