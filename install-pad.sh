#!/bin/zsh
# Installs PadLink on the pad over Wi‑Fi (no cable), using Android "Wireless debugging".
#   On the pad: Settings → About → tap "Build number" 7× → Developer options → Wireless debugging → ON
#   → "Pair device with pairing code". Then run:   ./install-pad.sh <ip:pair-port> <code> <ip:port>
set -e
cd "${0:A:h}"
ADB=${ANDROID_HOME:-$HOME/Library/Android/sdk}/platform-tools/adb
[[ -x $ADB ]] || ADB=adb
if [[ $# -eq 3 ]]; then
  $ADB pair "$1" "$2"
  $ADB connect "$3"
fi
$ADB install -r dist/PadLink.apk
$ADB shell am start -n app.padlink.pad/.MainActivity
echo "✓ PadLink ist auf dem Pad."
