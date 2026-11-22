#!/bin/bash
# Runs the Swift tests. Command Line Tools ship Swift Testing outside the default search paths,
# so without Xcode the framework dirs have to be passed explicitly.
set -euo pipefail
cd "$(dirname "$0")/../app"

flags=()
clt=/Library/Developer/CommandLineTools/Library/Developer
if ! xcode-select -p 2>/dev/null | grep -q Xcode && [ -d "$clt/Frameworks/Testing.framework" ]; then
  flags=(-Xswiftc -F"$clt/Frameworks" -Xlinker -F"$clt/Frameworks"
         -Xlinker -rpath -Xlinker "$clt/Frameworks" -Xlinker -rpath -Xlinker "$clt/usr/lib")
fi
swift test "${flags[@]}" "$@"
