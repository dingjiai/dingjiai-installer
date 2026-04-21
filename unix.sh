#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
MENU_FILE="$SCRIPT_DIR/menu.txt"
TITLE=''
SUBTITLE=''
declare -a MENU_KEYS=()
declare -A MENU_LABELS=()
declare -A MENU_MESSAGES=()

load_menu() {
  if [[ ! -f "$MENU_FILE" ]]; then
    printf 'Missing menu definition: %s\n' "$MENU_FILE" >&2
    exit 1
  fi

  while IFS= read -r line; do
    [[ -z "$line" ]] && continue

    case "$line" in
      TITLE=*)
        TITLE=${line#TITLE=}
        ;;
      SUBTITLE=*)
        SUBTITLE=${line#SUBTITLE=}
        ;;
      *'|'*'|'*)
        IFS='|' read -r key label message <<< "$line"
        MENU_KEYS+=("$key")
        MENU_LABELS["$key"]="$label"
        MENU_MESSAGES["$key"]="$message"
        ;;
    esac
  done < "$MENU_FILE"
}

show_menu() {
  printf '\n'
  printf '================================\n'
  printf ' %s\n' "$TITLE"
  printf ' %s\n' "$SUBTITLE"
  printf '================================\n'

  for key in "${MENU_KEYS[@]}"; do
    printf '[%s] %s\n' "$key" "${MENU_LABELS[$key]}"
  done

  printf '\n'
  printf 'Select an option: '
}

handle_choice() {
  local choice="$1"
  local message="${MENU_MESSAGES[$choice]-}"

  if [[ -z "$message" ]]; then
    printf '\nInvalid selection.\n'
    return
  fi

  printf '\n%s\n' "$message"

  if [[ "$choice" == '0' ]]; then
    exit 0
  fi
}

load_menu

while true; do
  show_menu
  read -r choice
  handle_choice "$choice"
  printf '\nPress Enter to continue...'
  read -r _
done
