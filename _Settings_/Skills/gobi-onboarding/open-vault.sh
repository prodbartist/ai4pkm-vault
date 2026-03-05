#!/bin/bash
# open-vault.sh — Open an Obsidian vault by name, path, or ID
# Adapted from https://github.com/Physics-of-Data/obsidian-open-vault for macOS + Linux
#
# Usage:
#   ./open-vault.sh <vault-name|vault-path|vault-id>

set -euo pipefail

# --- Platform detection ---
if [[ "$(uname)" == "Darwin" ]]; then
  OBSIDIAN_CONFIG="$HOME/Library/Application Support/obsidian/obsidian.json"
  OPEN_CMD="open"
else
  OBSIDIAN_CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/obsidian/obsidian.json"
  OPEN_CMD="xdg-open"
fi

# --- Dependency checks ---
if ! command -v jq &>/dev/null; then
  echo "ERROR: jq is required. Install with: brew install jq (macOS) or sudo apt install jq (Linux)" >&2
  exit 2
fi

if [[ ! -f "$OBSIDIAN_CONFIG" ]]; then
  echo "ERROR: Obsidian config not found at $OBSIDIAN_CONFIG. Is Obsidian installed?" >&2
  exit 3
fi

# --- Resolve absolute path (macOS-compatible) ---
resolve_path() {
  local p="$1"
  if command -v realpath &>/dev/null; then
    realpath "$p"
  else
    (cd "$p" 2>/dev/null && pwd) || echo "$p"
  fi
}

# --- Generate a random hex vault ID ---
generate_vault_id() {
  LC_ALL=C tr -dc 'a-f0-9' </dev/urandom | head -c 16
}

# --- Lookup vault in obsidian.json ---
# Returns: vault_id or empty string
find_vault_by_path() {
  local search_path="$1"
  jq -r --arg p "$search_path" '.vaults | to_entries[] | select(.value.path == $p) | .key' "$OBSIDIAN_CONFIG" 2>/dev/null | head -1
}

find_vault_by_id() {
  local search_id="$1"
  jq -r --arg id "$search_id" '.vaults[$id].path // empty' "$OBSIDIAN_CONFIG" 2>/dev/null
}

find_vault_by_name() {
  local search_name="$1"
  # Match vaults whose path ends with the given name
  jq -r --arg n "$search_name" '.vaults | to_entries[] | select(.value.path | endswith("/" + $n)) | .key' "$OBSIDIAN_CONFIG" 2>/dev/null | head -1
}

# --- Register a new vault in obsidian.json ---
register_vault() {
  local vault_path="$1"
  local vault_id
  vault_id="$(generate_vault_id)"

  # Add vault entry to obsidian.json
  local tmp
  tmp="$(mktemp)"
  jq --arg id "$vault_id" --arg p "$vault_path" '.vaults[$id] = {"path": $p, "ts": (now | floor)}' "$OBSIDIAN_CONFIG" > "$tmp"
  mv "$tmp" "$OBSIDIAN_CONFIG"

  echo "$vault_id"
}

# --- Main ---
if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <vault-name|vault-path|vault-id>" >&2
  exit 1
fi

INPUT="$1"
VAULT_ID=""
VAULT_PATH=""
NEEDS_REGISTER=false

# 1. Try as vault ID
if [[ "$INPUT" =~ ^[a-f0-9]{16}$ ]]; then
  VAULT_PATH="$(find_vault_by_id "$INPUT")"
  if [[ -n "$VAULT_PATH" ]]; then
    VAULT_ID="$INPUT"
  fi
fi

# 2. Try as path
if [[ -z "$VAULT_ID" && -d "$INPUT" ]]; then
  abs_path="$(resolve_path "$INPUT")"
  abs_path="${abs_path%/}"
  VAULT_ID="$(find_vault_by_path "$abs_path")"
  VAULT_PATH="$abs_path"

  if [[ -z "$VAULT_ID" ]]; then
    NEEDS_REGISTER=true
  fi
fi

# 3. Try as vault name
if [[ -z "$VAULT_ID" ]]; then
  VAULT_ID="$(find_vault_by_name "$INPUT")"
  if [[ -n "$VAULT_ID" ]]; then
    VAULT_PATH="$(find_vault_by_id "$VAULT_ID")"
  fi
fi

# 4. If still not found, search common directories
if [[ -z "$VAULT_ID" ]]; then
  SEARCH_DIRS=(
    "$HOME/Documents"
    "$HOME/dev"
    "$HOME/Desktop"
    "$HOME"
  )
  if [[ "$(uname)" == "Darwin" ]]; then
    SEARCH_DIRS+=("$HOME/Library/Mobile Documents/iCloud~md~obsidian/Documents")
  fi

  for dir in "${SEARCH_DIRS[@]}"; do
    if [[ -d "$dir/$INPUT" && -d "$dir/$INPUT/.obsidian" ]]; then
      abs_path="$(resolve_path "$dir/$INPUT")"
      echo "Found vault at: $abs_path"
      VAULT_ID="$(find_vault_by_path "$abs_path")"
      VAULT_PATH="$abs_path"
      if [[ -z "$VAULT_ID" ]]; then
        NEEDS_REGISTER=true
      fi
      break
    fi
  done
fi

if [[ -z "$VAULT_ID" && "$NEEDS_REGISTER" != true ]]; then
  echo "ERROR: Could not find vault '$INPUT'" >&2
  exit 4
fi

# For new vaults: register in obsidian.json, then pkill Obsidian (hard kill
# prevents it from overwriting our config on exit), then relaunch and wait
# for it to load the new config before sending the URI.
if [[ "$NEEDS_REGISTER" == true ]]; then
  echo "Vault not registered in Obsidian. Registering: $VAULT_PATH"
  VAULT_ID="$(register_vault "$VAULT_PATH")"

  # Hard-kill Obsidian so it can't overwrite our config change on exit
  pkill -x Obsidian 2>/dev/null || true
  # Wait for Obsidian to fully terminate before URI launches a new instance
  sleep 3
fi

# Open vault via URI (launches Obsidian if not running)
VAULT_NAME="$(basename "$VAULT_PATH")"
URI="obsidian://open?vault=${VAULT_NAME}"
$OPEN_CMD "$URI" 2>/dev/null
echo "OK: Vault opened in Obsidian (vault: $VAULT_NAME, id: $VAULT_ID)"
