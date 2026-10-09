#!/bin/bash
# project-map-embed.sh ROOT inv-<id> [--deadline S]   |   ROOT --mechanical [--deadline S]
# Trusted helper (plugin scripts/ directory, not writable by the project-map agent). Thin entry point for
# project-map-embed.py: validates the staged judgement, publishes one immutable generation (INTERFACES-3.2 1.3).
# Output: PM_EMBED_OK gen <seq>-<id> <bytes> (exit 0) | SUPERSEDED ... (exit 4) | PM_EMBED_ERROR <why> (exit 1).
HERE=$(cd -P "$(dirname "$0")" && pwd) || { echo "PM_EMBED_ERROR cannot resolve the script directory"; exit 1; }
[ -f "$HERE/project-map-embed.py" ] || { echo "PM_EMBED_ERROR project-map-embed.py missing next to the script"; exit 1; }
export PYTHONDONTWRITEBYTECODE=1
exec python3 "$HERE/project-map-embed.py" "$@"
