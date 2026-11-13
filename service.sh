#!/system/bin/sh
# Module-manager boot entry. CLI compatibility is preserved.
MODDIR=${0%/*}
exec sh "$MODDIR/CoreGate.sh" "$@"
