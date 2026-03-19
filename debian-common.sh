#!/bin/bash
# =============================================================================
# debian-common.sh — Shared pbuilder/Debian packaging logic
# Invoke this from a project-specific debian.sh after setting variables below.
# =============================================================================
#
# REQUIRED
#   PKG_NAME              Debian source package name        (e.g. "nixl")
#   DEB_PKG_NAMES         Binary package name array         (e.g. ("libnixl" "nixlbench"))
#
# OPTIONAL
#   CUSTOM_BASETGZ_SUFFIX  Use a custom base tarball: ${DISTRO}-${SUFFIX}.tgz
#                          Created automatically on first run if missing.
#   EXTRA_BINDMOUNTS       Host path(s) bind-mounted into the pbuilder chroot.
#   CUSTOM_BASE_SETUP      Shell command run inside chroot to configure custom base.
#   CLEAN_EXTRA_DIRS       Extra dirs to rm -rf on clean (default: obj-${HOST_GNU_TYPE}/)
#
# MAINTAINER  (priority: CLI flag > env var > default)
#   --name <name>   / DEBFULLNAME    Maintainer full name  (default: Gyujin)
#   --email <email> / DEBEMAIL       Maintainer email      (default: ckjin95@gmail.com)

# Maintainer identity used by dch when bumping the changelog version.
DEBFULLNAME="${DEBFULLNAME:-Gyujin}"
DEBEMAIL="${DEBEMAIL:-ckjin95@gmail.com}"

# Absolute path of the source tree; used throughout to avoid working-directory confusion.
SOURCE_DIR=$(pwd)
export SOURCE_DIR

# Local APT repository and source list paths derived from the package name.
REPO_BASE="/opt/${PKG_NAME}-repo"
LIST_FILE="/etc/apt/sources.list.d/${PKG_NAME}.list"

# Parse the subcommand first, then consume remaining flags.
DISTRO="noble"
FORCE=0
COMMAND="$1"
shift
while [ $# -gt 0 ]; do
  case "$1" in
    --jammy)  DISTRO="jammy" ;;   # Target Ubuntu 22.04 instead of the default 24.04
    --force)  FORCE=1 ;;          # Enable destructive cleanup (repo, APT list, base tarball)
    --name)   DEBFULLNAME="$2"; shift ;;
    --email)  DEBEMAIL="$2"; shift ;;
  esac
  shift
done

export DEBFULLNAME DEBEMAIL

# Detect the host GNU triple for build artifact directory naming (e.g. x86_64-linux-gnu).
HOST_GNU_TYPE=$(dpkg-architecture -qDEB_HOST_GNU_TYPE 2>/dev/null || echo "x86_64-linux-gnu")

# Default pbuilder base tarball for the selected distro.
BASE_BASETGZ="/var/cache/pbuilder/${DISTRO}-base.tgz"

# If a custom suffix is given, point to the customized tarball instead.
if [ -n "${CUSTOM_BASETGZ_SUFFIX:-}" ]; then
  BASETGZ="/var/cache/pbuilder/${DISTRO}-${CUSTOM_BASETGZ_SUFFIX}.tgz"
else
  BASETGZ="${BASE_BASETGZ}"
fi

# Print an error message and abort. Call as: some_command || _check_error "message"
_check_error() {
  echo "❌ Error: $1"
  exit 1
}

# Ensure the custom pbuilder base tarball exists.
# Skipped entirely when CUSTOM_BASETGZ_SUFFIX is not set (uses the stock base).
# On first run: creates the distro base, copies it, then applies CUSTOM_BASE_SETUP inside the chroot.
_ensure_base() {
  [ -z "${CUSTOM_BASETGZ_SUFFIX:-}" ] && return 0

  if sudo test -s "${BASETGZ}"; then
    echo "  > Base tarball already exists: ${BASETGZ}"
    return 0
  fi

  echo "🔧 [Base] Creating custom pbuilder base tarball (one-time setup)..."

  # Create the stock distro base if it doesn't exist yet.
  if ! sudo test -s "${BASE_BASETGZ}"; then
    echo "  > Base tarball not found: ${BASE_BASETGZ}"
    echo "  > Creating ${DISTRO} base tarball (this may take a while)..."
    sudo pbuilder --create --distribution "${DISTRO}" --basetgz "${BASE_BASETGZ}" \
      --mirror "http://archive.ubuntu.com/ubuntu" \
      --debootstrapopts "--include=ca-certificates" \
      || _check_error "Failed to create base tarball"
    echo "  > Base tarball created: ${BASE_BASETGZ}"
  fi

  # Copy the stock base as the starting point for the custom tarball.
  echo "  > Copying ${BASE_BASETGZ} → ${BASETGZ}"
  sudo cp "${BASE_BASETGZ}" "${BASETGZ}" || _check_error "Failed to copy base tarball"

  # Run the caller-supplied setup command inside the chroot and save the result.
  if [ -n "${CUSTOM_BASE_SETUP:-}" ]; then
    echo "  > Configuring custom base tarball..."
    local bindmount_args=()
    [ -n "${EXTRA_BINDMOUNTS:-}" ] && bindmount_args=(--bindmounts "${EXTRA_BINDMOUNTS}")
    sudo pbuilder --execute --save-after-exec \
      --basetgz "${BASETGZ}" \
      "${bindmount_args[@]}" \
      -- /bin/sh -c "${CUSTOM_BASE_SETUP}" \
      || _check_error "Failed to configure base tarball"
  fi

  echo "  > Base tarball ready: ${BASETGZ}"
}

# Build .deb packages inside an isolated pbuilder chroot and copy them to the local repo.
_build() {
  echo "🔨 [Build] Source directory: ${SOURCE_DIR}"
  cd "${SOURCE_DIR}" || exit 1

  _ensure_base

  echo "📝 [1/3] Generating version with dch..."
  local CURRENT_VER
  CURRENT_VER=$(dpkg-parsechangelog -S Version)
  # Append a build timestamp to make every CI artifact uniquely versioned.
  local NEW_VER="${CURRENT_VER}+build$(date +%Y%m%d%H%M)"
  echo "  > Current version: ${CURRENT_VER}"
  echo "  > New version:     ${NEW_VER}"

  # Back up changelog before dch modifies it; restore on exit regardless of outcome.
  cp debian/changelog debian/changelog.bak
  trap 'mv "${SOURCE_DIR}/debian/changelog.bak" "${SOURCE_DIR}/debian/changelog"; trap - EXIT' EXIT

  dch -v "${NEW_VER}" --force-bad-version --no-query "Automated CI/CD build" \
    || _check_error "Failed to update version with dch"
  echo "  > changelog updated"

  echo "📦 [2/3] Starting isolated build with pdebuild..."
  echo "  > Output path: ${SOURCE_DIR}/dist"
  mkdir -p "${SOURCE_DIR}/dist"

  local bindmount_args=()
  [ -n "${EXTRA_BINDMOUNTS:-}" ] && bindmount_args=(--bindmounts "${EXTRA_BINDMOUNTS}")

  # -us -uc: skip signing (unnecessary for local/CI builds).
  # -b: binary-only build (no source package needed).
  sudo pdebuild --pbuilder pbuilder --debbuildopts "-us -uc -b" --buildresult "${SOURCE_DIR}/dist" -- \
    --basetgz "${BASETGZ}" \
    "${bindmount_args[@]}" \
    || _check_error "pdebuild failed"
  echo "  > pdebuild complete"

  echo "📂 [3/3] Copying build artifacts to repository..."
  echo "  > Target repository: ${REPO_BASE}"
  sudo mkdir -p "$REPO_BASE"
  for deb_pkg in "${DEB_PKG_NAMES[@]}"; do
    sudo cp "${SOURCE_DIR}/dist/${deb_pkg}_${NEW_VER}_"*.deb "$REPO_BASE/" \
      || _check_error "Failed to copy ${deb_pkg} package"
  done
  echo "  > .deb files copied"

  echo "✅ Build and copy complete (version: ${NEW_VER})"

  # pdebuild generates source package artifacts (.dsc, .tar.gz, etc.) in the parent directory.
  # Remove them so the working tree stays clean after every build.
  echo "🗑️  [Cleanup] Removing source package artifacts from ../"
  rm -f "${SOURCE_DIR}/../${PKG_NAME}_"*.dsc \
        "${SOURCE_DIR}/../${PKG_NAME}_"*.tar.gz \
        "${SOURCE_DIR}/../${PKG_NAME}_"*.build \
        "${SOURCE_DIR}/../${PKG_NAME}_"*_source.changes
  echo "  > Artifacts removed"
}

# Remove build outputs. With --force, also wipes the local repo, APT list, and custom base tarball.
_clean() {
  echo "🧹 [Clean] Removing build artifacts${FORCE:+ and full environment}"
  cd "${SOURCE_DIR}" || exit 1

  echo "🗑️  [1/2] Removing dist/ and build artifacts..."
  local clean_dirs=("dist/")
  # Use caller-supplied extra dirs if provided, otherwise fall back to the default build output dir.
  if [ ${#CLEAN_EXTRA_DIRS[@]} -gt 0 ]; then
    clean_dirs+=("${CLEAN_EXTRA_DIRS[@]}")
  else
    clean_dirs+=("obj-${HOST_GNU_TYPE}/")
  fi
  rm -rf "${clean_dirs[@]}"
  echo "  > Build artifacts removed"

  # Remove source package artifacts that pdebuild generates in the parent directory.
  echo "🔄 [2/2] Removing source package artifacts from ../"
  rm -f "${SOURCE_DIR}/../${PKG_NAME}_"*.dsc \
        "${SOURCE_DIR}/../${PKG_NAME}_"*.tar.gz \
        "${SOURCE_DIR}/../${PKG_NAME}_"*.build \
        "${SOURCE_DIR}/../${PKG_NAME}_"*_source.changes
  echo "  > Source artifacts removed"

  if [ "${FORCE}" = "1" ]; then
    # Only remove the custom tarball — never touch the stock base (shared across projects).
    if [ -n "${CUSTOM_BASETGZ_SUFFIX:-}" ]; then
      echo "🗑️  [--force] Removing custom base tarball... (${BASETGZ})"
      if sudo test -s "${BASETGZ}"; then
        sudo rm -f "${BASETGZ}"
        echo "  > Custom base tarball removed"
      else
        echo "  > Custom base tarball not found, skipping"
      fi
    fi

    echo "🗑️  [--force] Clearing local repository... (${REPO_BASE})"
    if [ -d "$REPO_BASE" ]; then
      sudo rm -rf "${REPO_BASE:?}"/*   # :? guard prevents accidental rm -rf / if var is empty
      echo "  > Repository directory cleared"
    else
      echo "  > Repository directory not found, skipping"
    fi

    echo "🗑️  [--force] Removing APT source list... (${LIST_FILE})"
    if [ -f "$LIST_FILE" ]; then
      sudo rm -f "$LIST_FILE"
      echo "  > APT source list removed"
    else
      echo "  > Source list not found, skipping"
    fi

    echo "🔄 [--force] Refreshing APT index..."
    sudo apt update
  else
    echo "  > Skipping repo/APT cleanup (use --force to include)"
  fi

  echo "✨ Clean complete!"
}

# Register the built .deb files as a local APT repository so they can be installed with apt.
_package() {
  echo "📦 [Package] Setting up local APT repository"

  echo "🔍 [1/3] Verifying repository directory and generating Packages index..."
  if [ ! -d "$REPO_BASE" ]; then
    echo "❌ Repository directory not found. Run build first."
    exit 1
  fi
  echo "  > Repository path: ${REPO_BASE}"
  cd "$REPO_BASE" || exit 1

  # Scan all .deb files and generate the Packages metadata file required by APT.
  sudo dpkg-scanpackages . /dev/null | sudo tee Packages > /dev/null \
    || _check_error "Failed to generate Packages index"
  echo "  > Packages index generated"

  # -k: keep the uncompressed Packages file alongside Packages.gz.
  sudo gzip -fk Packages || _check_error "Failed to create Packages.gz"
  echo "  > Packages.gz compressed"

  echo "📋 [2/3] Registering APT source list..."
  echo "  > Target path: ${LIST_FILE}"
  # trusted=yes: skip GPG signature check for the local file:// repository.
  echo "deb [trusted=yes] file://${REPO_BASE} ./" | sudo tee "$LIST_FILE" > /dev/null \
    || _check_error "Failed to register source list"
  echo "  > Source list registered"

  sudo chmod -R 755 "$REPO_BASE" || _check_error "Failed to set repository permissions"
  echo "  > Repository permissions (755) set"

  echo "🔄 [3/3] Running apt update..."
  sudo apt update || _check_error "apt update failed"

  echo "--------------------------------------------------"
  echo "✅ All done!"
  echo "Check install: apt list ${DEB_PKG_NAMES[*]}"
  echo "--------------------------------------------------"
  cd "${SOURCE_DIR}" || exit 1
}

echo "💡 Usage:"
echo "  build   [--jammy] [--name <name>] [--email <email>] : bump version and run pdebuild"
echo "  package [--jammy]                                   : set up local APT repository"
echo "  clean   [--force] [--jammy]                         : remove build artifacts"
echo "  clean   --force   [--jammy]                         : clean + remove base, repo, APT"
echo "  all     [--jammy] [--name <name>] [--email <email>] : build + package"
echo "  (default distro: noble)"

case "$COMMAND" in
  build)   _build ;;
  package) _package ;;
  clean)   _clean ;;
  all)     _build && _package ;;
  *)       echo "Usage: $0 {build|package|clean [--force]|all} [--jammy]" ;;
esac
