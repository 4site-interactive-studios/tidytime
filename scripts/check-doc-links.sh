#!/usr/bin/env bash
# check-doc-links.sh — verify that relative Markdown links across the repo resolve to files
# that exist. External (http/https/mailto) links and pure #anchors are skipped. Exits non-zero
# if any relative link is broken. Runs on macOS's default bash 3.2.
set -uo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

out="$(mktemp)"
trap 'rm -f "$out"' EXIT

# For every markdown file, pull out `](target)` link targets and check each one.
find . -name '*.md' -not -path './.git/*' -not -path './.build/*' | while IFS= read -r f; do
  dir="$(dirname "$f")"
  grep -oE '\]\([^)]+\)' "$f" | sed -E 's/^\]\(//; s/\)$//' | while IFS= read -r link; do
    case "$link" in
      http://*|https://*|mailto:*|\#*) continue ;;
    esac
    target="${link%%#*}"          # strip any #anchor
    [ -z "$target" ] && continue
    if [ ! -e "$dir/$target" ]; then
      printf 'BROKEN: %s -> %s\n' "$f" "$link" >> "$out"
    fi
  done
done

if [ -s "$out" ]; then
  sort -u "$out"
  count="$(sort -u "$out" | wc -l | tr -d ' ')"
  printf '\n%s broken link(s).\n' "$count"
  exit 1
fi

echo "All relative documentation links resolve."
