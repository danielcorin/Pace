#!/bin/bash
# Imports Alfred's clipboard history into Pace, preserving timestamps and
# source apps. Text entries come from the clipboard table; images from the
# TIFF files Alfred keeps alongside it. Entries run through Pace's normal
# `pace add` path, so the sensitive-content filter applies and duplicates
# merge by content fingerprint (re-running bumps their copy counts but adds
# nothing twice).
#
# Usage: scripts/import-alfred.sh
#   ALFRED_CLIPBOARD_DB=/path/to/clipboard.alfdb  overrides the database path
#   PACE_CLI=/path/to/pace                        overrides the CLI location
set -uo pipefail

DB="${ALFRED_CLIPBOARD_DB:-$HOME/Library/Application Support/Alfred/Databases/clipboard.alfdb}"
DATA_DIR="$DB.data"

PACE="${PACE_CLI:-}"
if [ -z "$PACE" ]; then
  for candidate in "$HOME/.local/bin/pace" "/Applications/Pace.app/Contents/Helpers/pace"; do
    if [ -x "$candidate" ]; then PACE="$candidate"; break; fi
  done
fi
[ -n "$PACE" ] || { echo "pace CLI not found; install it from Pace Settings or set PACE_CLI" >&2; exit 1; }
[ -f "$DB" ] || { echo "Alfred clipboard database not found at $DB" >&2; exit 1; }

"$PACE" unlock >/dev/null || { echo "Could not unlock Pace" >&2; exit 1; }

imported=0
skipped=0
rejected=0

# Oldest first, so when Alfred holds several copies of the same content the
# newest timestamp ends up as the item's lastCopiedAt.
while IFS= read -r rowid; do
  # Alfred timestamps are seconds since 2001-01-01 (Apple reference epoch).
  ts=$(sqlite3 "$DB" "SELECT CAST(ts + 978307200 AS INTEGER) FROM clipboard WHERE rowid=$rowid")
  dataType=$(sqlite3 "$DB" "SELECT dataType FROM clipboard WHERE rowid=$rowid")
  app=$(sqlite3 "$DB" "SELECT COALESCE(NULLIF(app, ''), 'Alfred') FROM clipboard WHERE rowid=$rowid")

  case "$dataType" in
    0)
      text=$(sqlite3 "$DB" "SELECT item FROM clipboard WHERE rowid=$rowid")
      if [ -z "$text" ]; then skipped=$((skipped + 1)); continue; fi
      if printf '%s' "$text" | "$PACE" add --source "$app" --source-kind application --timestamp "$ts" >/dev/null 2>&1; then
        imported=$((imported + 1))
      else
        rejected=$((rejected + 1))
      fi
      ;;
    1)
      # dataHash already includes the file extension (e.g. "<sha1>.tiff").
      hash=$(sqlite3 "$DB" "SELECT dataHash FROM clipboard WHERE rowid=$rowid")
      file="$DATA_DIR/$hash"
      if [ ! -f "$file" ]; then skipped=$((skipped + 1)); continue; fi
      # The IPC frame limit is 32 MB; convert oversized TIFFs to PNG first.
      cleanup=""
      if [ "$(/usr/bin/stat -f %z "$file")" -gt 25000000 ]; then
        converted="$(mktemp -t pace-import).png"
        if sips -s format png "$file" --out "$converted" >/dev/null 2>&1; then
          file="$converted"
          cleanup="$converted"
        fi
      fi
      if "$PACE" add --file "$file" --source "$app" --source-kind application --timestamp "$ts" >/dev/null 2>&1; then
        imported=$((imported + 1))
      else
        rejected=$((rejected + 1))
      fi
      [ -n "$cleanup" ] && rm -f "$cleanup"
      ;;
    *)
      skipped=$((skipped + 1))
      ;;
  esac
done < <(sqlite3 "$DB" "SELECT rowid FROM clipboard ORDER BY ts ASC")

echo "Imported: $imported"
echo "Skipped (empty, unsupported type, or missing image file): $skipped"
echo "Rejected (sensitive-content filter or add errors): $rejected"
