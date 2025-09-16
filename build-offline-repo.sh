#!/usr/bin/env bash
set -euo pipefail

# build-offline-repo.sh
# Create a compact APT repository from:
#  - cached .debs in /var/cache/apt/archives
#  - repacked .debs of all currently installed packages
# Optionally fetch the newest updates (download-only) before building.

REPO_DIR="${REPO_DIR:-$HOME/offline-repo}"
POOL_DIR="$REPO_DIR/pool"
CSV_FILE="$REPO_DIR/installed-packages.csv"
INCLUDE_UPDATES="no"     # yes|no  (if yes: apt-get -d dist-upgrade to pull updates w/o installing)
REGISTER_REPO="no"       # yes|no  (add file: source to this machine)
TRUSTED_YES="yes"        # set to "no" if you plan to sign later
JOBS="$(nproc || echo 1)"

usage() {
  cat <<EOF
Usage: sudo $0 [--repo-dir <path>] [--include-updates] [--register] [--trusted=no]

Options:
  --repo-dir <path>   Where to build the repo (default: \$HOME/offline-repo)
  --include-updates   Download the latest updates (download-only) into APT cache before building
  --register          Add a local sources entry pointing at the repo and apt update
  --trusted=no        Omit [trusted=yes] in the sources entry (default: yes)

Examples:
  sudo $0
  sudo $0 --include-updates
  sudo $0 --repo-dir /opt/offline-repo --register
EOF
}

# Parse args
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo-dir) REPO_DIR="$2"; POOL_DIR="$REPO_DIR/pool"; shift 2;;
    --include-updates) INCLUDE_UPDATES="yes"; shift;;
    --register) REGISTER_REPO="yes"; shift;;
    --trusted=no) TRUSTED_YES="no"; shift;;
    -h|--help) usage; exit 0;;
    *) echo "Unknown option: $1" >&2; usage; exit 1;;
  esac
done

# Need these tools
need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing: $1" >&2; exit 1; }; }
for c in dpkg-query apt-ftparchive gzip sha256sum awk xargs dpkg-deb realpath; do need "$c"; done
# dpkg-repack is ideal but optional; we’ll warn if missing
HAVE_REPACK="yes"; command -v dpkg-repack >/dev/null 2>&1 || HAVE_REPACK="no"

echo "[i] Repo dir: $REPO_DIR"
mkdir -p "$POOL_DIR"

# 0) Optional: pull newest updates into the cache (no install)
# This shrinks your mirror to “just what your system would use if you upgraded today”.
if [[ "$INCLUDE_UPDATES" == "yes" ]]; then
  echo "[1/6] Refreshing indices and downloading updates (no install) ..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get -y --download-only dist-upgrade
else
  echo "[1/6] Skipping download of updates; using what's already on the system."
fi

# 1) Copy cached .debs first (fast path)
echo "[2/6] Harvesting cached .debs from /var/cache/apt/archives ..."
shopt -s nullglob
cache_src=(/var/cache/apt/archives/*.deb)
if (( ${#cache_src[@]} )); then
  cp -an /var/cache/apt/archives/*.deb "$POOL_DIR"/
else
  echo "    [i] No cached packages found."
fi

# 2) Repack all installed packages that are not already present as .deb in the pool
# This ensures you truly have *everything installed* captured, even if it was never cached.
echo "[3/6] Ensuring every installed package has a .deb in the pool ..."
mapfile -t INSTALLED < <(dpkg-query -W -f='${binary:Package} ${Version} ${Architecture}\n' | sort -u)

if [[ "$HAVE_REPACK" == "no" ]]; then
  echo "    [!] dpkg-repack not found. Skipping repack stage."
  echo "        Install it for a complete snapshot: sudo apt-get install dpkg-repack"
else
  pushd "$POOL_DIR" >/dev/null
  for line in "${INSTALLED[@]}"; do
    pkg="${line%% *}"; rest="${line#* }"
    ver="${rest%% *}"; arch="${line##* }"
    # Common naming patterns to detect presence (dpkg-repack names 'pkg_version_arch.deb')
    pattern1="$POOL_DIR/${pkg}_${ver}_${arch}.deb"
    pattern2="$POOL_DIR/${pkg}_*.deb"  # fallback loose match
    if ls $pattern1 >/dev/null 2>&1; then
      continue
    elif ls $pattern2 >/dev/null 2>&1 | grep -q "${pkg}_${ver}_"; then
      continue
    fi
    echo "    [+] repacking $pkg ($ver/$arch)"
    # Some virtual/meta packages or removed-but-config packages will fail; don’t stop the run.
    if ! dpkg-repack "$pkg" >/dev/null 2>&1; then
      echo "    [!] skipped $pkg (not repackable/virtual?)"
    fi
  done
  popd >/dev/null
fi

# 3) Build apt metadata
echo "[4/6] Building Packages and Packages.gz ..."
cd "$REPO_DIR"
apt-ftparchive packages ./pool > Packages
gzip -c Packages > Packages.gz

# Optional: minimal Release (unsigned)
echo "[i] Generating minimal Release ..."
apt-ftparchive release "$REPO_DIR" > Release

# 4) CSV inventory with SHA256 for auditing
echo "[5/6] Emitting CSV inventory with SHA256 -> $CSV_FILE"
echo "Package,Version,Architecture,Size,Filename,SHA256" > "$CSV_FILE"
find "$POOL_DIR" -type f -name '*.deb' -print0 \
| xargs -0 -n1 -P "$JOBS" bash -c '
  set -euo pipefail
  deb="$1"
  pkg=$(dpkg-deb -f "$deb" Package || echo "")
  ver=$(dpkg-deb -f "$deb" Version || echo "")
  arc=$(dpkg-deb -f "$deb" Architecture || echo "")
  sz=$(stat -c%s "$deb")
  fn=$(realpath --relative-to="'"$REPO_DIR"'" "$deb")
  sha=$(sha256sum "$deb" | awk "{print \$1}")
  echo "$pkg,$ver,$arc,$sz,$fn,$sha"
' _ >> "$CSV_FILE"

echo "[ok] Repo built at: $REPO_DIR"
echo "     pool/  Packages  Packages.gz  Release  installed-packages.csv"

# 5) Optional: register repo on this host (file: source) and update
if [[ "$REGISTER_REPO" == "yes" ]]; then
  LIST="/etc/apt/sources.list.d/offline-repo.list"
  SRC="deb "
  [[ "$TRUSTED_YES" == "yes" ]] && SRC+="[trusted=yes] "
  SRC+="file:$REPO_DIR ./"
  echo "[6/6] Registering local repo -> $LIST"
  echo "$SRC" | tee "$LIST" >/dev/null
  apt-get update
  echo "[i] APT now sees the local repository."
fi

