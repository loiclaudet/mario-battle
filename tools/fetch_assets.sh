#!/usr/bin/env bash
# fetch the sound effects (the mushroom kingdom, credit link required) into assets/sfx.
# run from the project root: bash tools/fetch_assets.sh
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p assets/sfx
base="https://themushroomkingdom.net/sounds/wav/smb3"
declare -A sfx=(
  [jump]=smb3_jump.wav
  [kick]=smb3_kick.wav
  [coin]=smb3_coin.wav
  [bump]=smb3_bump.wav
  [player_down]=smb3_player_down.wav
  [fireball]=smb3_fireball.wav
  [pow]=smb3_thwomp.wav
  [pipe]=smb3_pipe.wav
)
for name in "${!sfx[@]}"; do
  out="assets/sfx/$name.wav"
  if [ ! -s "$out" ]; then
    curl -fsSL -A "Mozilla/5.0" -o "$out" "$base/${sfx[$name]}"
    echo "fetched $out"
  fi
done
