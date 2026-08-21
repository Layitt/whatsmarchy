#!/usr/bin/env bash
# Interactive, opt-in installer for local voice-note transcription.
#
# This script installs nothing on its own. It prints exactly which packages and
# downloads are involved and stops unless the user types "yes". The panel gates
# it behind a confirmation dialog too, so the choice is made twice, in the open.
#
# Nothing here is ever invoked by the poller or by any timer.
set -uo pipefail

MODEL_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/wamarchy/models"
MODEL_NAME="ggml-base.bin"
MODEL_URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/${MODEL_NAME}"

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
dim()  { printf '\033[2m%s\033[0m\n' "$*"; }

confirm() {
  local answer=""
  printf '%s [type yes to continue]: ' "$1"
  read -r answer || return 1
  [[ "$answer" == "yes" ]]
}

bold "Wamarchy — optional local voice-note transcription"
echo
echo "Transcription is entirely optional. Voice notes already play without it."
echo "Nothing below runs unless you type 'yes' at each prompt."
echo

need_pkgs=()
command -v whisper-cli >/dev/null 2>&1 || command -v whisper-cpp >/dev/null 2>&1 || need_pkgs+=("whisper-cpp")
command -v ffmpeg      >/dev/null 2>&1 || need_pkgs+=("ffmpeg")

if ((${#need_pkgs[@]} > 0)); then
  bold "Step 1 — system packages"
  echo "These Arch packages are missing and would be installed:"
  printf '  - %s\n' "${need_pkgs[@]}"
  echo
  dim "Command: sudo pacman -S --needed ${need_pkgs[*]}"
  dim "This needs your sudo password and modifies your system."
  echo
  if confirm "Install these packages now?"; then
    if command -v omarchy-pkg-add >/dev/null 2>&1; then
      omarchy-pkg-add "${need_pkgs[@]}" || { echo "Package installation failed."; exit 1; }
    else
      sudo pacman -S --needed "${need_pkgs[@]}" || { echo "Package installation failed."; exit 1; }
    fi
  else
    echo "Skipped. Nothing was installed."
    exit 0
  fi
  echo
else
  dim "whisper.cpp and ffmpeg are already installed — skipping package step."
  echo
fi

if compgen -G "$MODEL_DIR/ggml-*.bin" >/dev/null 2>&1; then
  dim "A whisper model is already present in $MODEL_DIR — nothing left to do."
  exit 0
fi

bold "Step 2 — speech model"
echo "whisper.cpp needs a model file. The multilingual 'base' model is ~148 MB."
echo
dim "Download: $MODEL_URL"
dim "Saved to: $MODEL_DIR/$MODEL_NAME"
dim "This downloads from Hugging Face over the network. Nothing is uploaded."
echo
if confirm "Download the model now?"; then
  mkdir -p -- "$MODEL_DIR" || { echo "Could not create $MODEL_DIR"; exit 1; }
  if command -v curl >/dev/null 2>&1; then
    curl -fL --progress-bar -o "$MODEL_DIR/$MODEL_NAME.part" "$MODEL_URL" \
      || { rm -f -- "$MODEL_DIR/$MODEL_NAME.part"; echo "Download failed."; exit 1; }
  elif command -v wget >/dev/null 2>&1; then
    wget -O "$MODEL_DIR/$MODEL_NAME.part" "$MODEL_URL" \
      || { rm -f -- "$MODEL_DIR/$MODEL_NAME.part"; echo "Download failed."; exit 1; }
  else
    echo "Neither curl nor wget is available."
    exit 1
  fi
  mv -f -- "$MODEL_DIR/$MODEL_NAME.part" "$MODEL_DIR/$MODEL_NAME"
  echo
  bold "Done. Reopen the Wamarchy panel and the Transcribe button will be active."
else
  echo "Skipped. No model was downloaded; transcription stays unavailable."
fi
