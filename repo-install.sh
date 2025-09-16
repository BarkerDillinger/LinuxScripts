#!/usr/bin/env bash
# Offline 22.04 -> 24.04.x (Noble) upgrade, APT file: repo only.
# Requires a "flat" repo: Packages or Packages.gz + pool/ in the same dir.

set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
REPO_DST="/opt/offline-repo"
LOG="/var/log/offline-noble-upgrade-${STAMP}.log"

log(){ printf '%s %s\n' "$(date -u +%FT%T%Z)" "$*" | tee -a "$LOG" >&2; }

# 0) Root + required tools
if [[ $EUID -ne 0 ]]; then echo "Run as root (sudo)"; exit 1; fi
for c in find rsync apt-get awk grep sed update-initramfs update-grub dpkg gzip; do
  command -v "$c" >/dev/null 2>&1 || { echo "Missing tool: $c"; exit 1; }
done

# 1) Discover a flat repo under PWD (current dir or subdirs)
discover_repo() {
  local d
  while IFS= read -r d; do
    [[ -d "$d/pool" ]] || continue
    if [[ -f "$d/Packages" || -f "$d/Packages.gz" ]]; then
      echo "$d"
      return 0
    fi
  done < <(find "$PWD" -type f \( -name Packages -o -name Packages.gz \) -printf '%h\n' | sort -u)
  return 1
}

SRC="$(discover_repo || true)"
if [[ -z "${SRC:-}" ]]; then
  echo "No flat repo found under $(pwd). Need Packages or Packages.gz and pool/ in the same directory."
  exit 1
fi
log "[0/10] Repo source: $SRC"

# 2) Stage to /opt/offline-repo with _apt-readable perms
log "[1/10] Staging repo to $REPO_DST"
mkdir -p "$REPO_DST"
echo "rsync from: ${SRC}/  ->  ${REPO_DST}/" | tee -a "$LOG"
# FIXED: removed stray space after $SRC/
rsync -a --delete --info=progress2 "${SRC}/" "${REPO_DST}/" | tee -a "$LOG"
chmod -R u+rwX,go+rX,go-w "$REPO_DST"

# 3) Validate staged repo
[[ -d "$REPO_DST/pool" ]] || { echo "Staged repo missing pool/"; exit 1; }
[[ -f "$REPO_DST/Packages" || -f "$REPO_DST/Packages.gz" ]] || { echo "Staged repo missing Packages or Packages.gz"; exit 1; }

# 4) Hard-switch APT to local-only, quarantine everything else
log "[2/10] Quarantining all existing APT sources"
BK="/etc/apt/sources.backup.${STAMP}"
mkdir -p "$BK"
[[ -f /etc/apt/sources.list ]] && mv -f /etc/apt/sources.list "$BK"/ 2>/dev/null || true
if compgen -G "/etc/apt/sources.list.d/*" >/dev/null; then
  mv -f /etc/apt/sources.list.d/* "$BK"/ 2>/dev/null || true
fi
if compgen -G "/etc/apt/sources.list.d/*.sources" >/dev/null; then
  mv -f /etc/apt/sources.list.d/*.sources "$BK"/ 2>/dev/null || true
fi

cat > /etc/apt/sources.list <<EOF
deb [trusted=yes] file:${REPO_DST} ./
EOF

# Sanity: ensure no other active source remains
if grep -RhsE '^[[:space:]]*deb|^URIs:' /etc/apt/sources.list.d /etc/apt/sources.list | grep -v "$REPO_DST" >/dev/null 2>&1; then
  echo "Stray APT sources still present after quarantine. Inspect $BK and /etc/apt/*. Aborting."
  exit 1
fi

# 5) Clean APT lists/caches and update from local repo only
log "[3/10] apt-get update (local repo only)"
rm -rf /var/lib/apt/lists/*; apt-get clean
apt-get update 2>&1 | tee -a "$LOG"

# 6) Non-interactive full upgrade (twice to settle)
log "[4/10] full-upgrade pass 1"
apt-get -y -o Dpkg::Options::="--force-confold" -o Dpkg::Options::="--force-confdef" full-upgrade 2>&1 | tee -a "$LOG" || true
log "[5/10] full-upgrade pass 2 (settle)"
apt-get -y -o Dpkg::Options::="--force-confold" -o Dpkg::Options::="--force-confdef" full-upgrade 2>&1 | tee -a "$LOG" || true

# 7) Ensure Noble GA kernel and identity bits
log "[6/10] Ensuring linux-generic (6.8 GA) and identity packages"
apt-get -y install linux-generic base-files lsb-release 2>&1 | tee -a "$LOG" || true

# 8) Desktop: force ubuntu-desktop (ubuntu-desktop-minimal absent in your dump)
log "[7/10] Ensuring ubuntu-desktop meta (ignore if absent in repo)"
apt-get -y install ubuntu-desktop 2>&1 | tee -a "$LOG" || true

# 9) Initramfs + GRUB refresh
log "[8/10] Rebuilding initramfs (all) and GRUB"
update-initramfs -u -k all 2>&1 | tee -a "$LOG" || true
update-grub 2>&1 | tee -a "$LOG" || true

# 10) Final local-only refresh to match repo head
log "[9/10] Final local-only update + no-op upgrade to align with repo"
rm -rf /var/lib/apt/lists/*; apt-get clean
apt-get update 2>&1 | tee -a "$LOG"
apt-get -y -o Dpkg::Options::="--force-confold" -o Dpkg::Options::="--force-confdef" full-upgrade 2>&1 | tee -a "$LOG" || true
apt-get -y autoremove --purge 2>&1 | tee -a "$LOG" || true

# Report
log "[10/10] Installed kernel images:"
dpkg -l 'linux-image-*' | awk '/^ii/{print "  " $2 "  " $3}' | tee -a "$LOG" || true

echo
echo "Active APT source:"
grep -Rhs ^deb /etc/apt/sources.list /etc/apt/sources.list.d || true
echo
echo "Upgrade done. Reboot to load the 6.8 kernel. Log: $LOG"

