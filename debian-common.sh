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
#
# JFROG  (for package --remote)
#   --jfrog-token <token>  JFrog Reference Token (Identity Token)

# Maintainer identity used by dch when bumping the changelog version.
DEBFULLNAME="${DEBFULLNAME:-Gyujin}"
DEBEMAIL="${DEBEMAIL:-ckjin95@gmail.com}"

# Parse the subcommand first, then consume remaining flags.
DISTRO="noble"  # default: Ubuntu 24.04 LTS
CLEAN_APT_LIST=0
CLEAN_TARBALL=0
PACKAGE_MODE=""
TARBALL_DIR="/var/cache/pbuilder"
SOURCE_DIR=$(pwd)
JFROG_TOKEN=""
JFROG_URL="https://gyujinv2.jfrog.io/artifactory/gj-test"  # fixed remote target
COMMAND="$1"
shift
while [ $# -gt 0 ]; do
  case "$1" in
    --jammy)        DISTRO="jammy" ;;   # Target Ubuntu 22.04 instead of the default 24.04
    --apt-list)     CLEAN_APT_LIST=1 ;; # Also remove APT source list on clean
    --tarball)      CLEAN_TARBALL=1 ;;  # Also remove custom base tarball on clean
    --local)        PACKAGE_MODE="local" ;;
    --remote)       PACKAGE_MODE="remote" ;;
    --name)         DEBFULLNAME="$2"; shift ;;
    --email)        DEBEMAIL="$2"; shift ;;
    --tarball-dir)  TARBALL_DIR="$2"; shift ;;  # Override tarball directory (e.g. for CI caching)
    --source-dir)   SOURCE_DIR=$(realpath "$2"); shift ;;  # Override source directory (e.g. for monorepo CI)
    --jfrog-token)  JFROG_TOKEN="$2"; shift ;;
  esac
  shift
done

# Absolute path of the source tree; used throughout to avoid working-directory confusion.
export SOURCE_DIR

# Build output directory, separated by distro (e.g. dist/jammy/, dist/noble/).
DIST_DIR="${SOURCE_DIR}/dist/${DISTRO}"
# Local APT package repository inside the project tree, separated by distro.
DIST_PKG_DIR="${SOURCE_DIR}/dist-package/${DISTRO}"
LIST_FILE="/etc/apt/sources.list.d/${PKG_NAME}.list"

export DEBFULLNAME DEBEMAIL

# Detect the host GNU triple for build artifact directory naming (e.g. x86_64-linux-gnu).
HOST_GNU_TYPE=$(dpkg-architecture -qDEB_HOST_GNU_TYPE 2>/dev/null || echo "x86_64-linux-gnu")
# Short architecture name for tarball naming (e.g. amd64, arm64).
HOST_ARCH=$(dpkg-architecture -qDEB_HOST_ARCH 2>/dev/null || echo "amd64")

# Default pbuilder base tarball for the selected distro.
# TARBALL_DIR defaults to /var/cache/pbuilder but can be overridden with --tarball-dir.
BASE_BASETGZ="${TARBALL_DIR}/${DISTRO}-base.tgz"

# If a custom suffix is given, point to the customized tarball instead.
# Architecture is embedded in the name to distinguish multi-arch tarballs.
if [ -n "${CUSTOM_BASETGZ_SUFFIX:-}" ]; then
  BASETGZ="${TARBALL_DIR}/${DISTRO}-${CUSTOM_BASETGZ_SUFFIX}-${HOST_ARCH}.tgz"
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

# Build .deb packages inside an isolated pbuilder chroot and drop them into dist/.
_build() {
  echo "🔨 [Build] Source directory: ${SOURCE_DIR}"
  cd "${SOURCE_DIR}" || exit 1

  _ensure_base

  echo "📝 [1/2] Generating version with dch..."
  local CURRENT_VER BASE_VER
  CURRENT_VER=$(dpkg-parsechangelog -S Version)
  # Strip any accumulated +build... suffix so timestamps never pile up.
  BASE_VER="${CURRENT_VER%%+build*}"
  local NEW_VER="${BASE_VER}+build$(date +%y%m%d-%H%M%S)"
  echo "  > Current version: ${CURRENT_VER}"
  echo "  > New version:     ${NEW_VER}"

  # Back up changelog before dch modifies it; restore on exit regardless of outcome.
  cp debian/changelog debian/changelog.bak
  trap 'mv "${SOURCE_DIR}/debian/changelog.bak" "${SOURCE_DIR}/debian/changelog"; trap - EXIT' EXIT

  dch -v "${NEW_VER}" --force-bad-version --no-query "Automated CI/CD build" \
    || _check_error "Failed to update version with dch"
  echo "  > changelog updated"

  echo "📦 [2/2] Starting isolated build with pdebuild..."
  echo "  > Output path: ${DIST_DIR}"
  mkdir -p "${DIST_DIR}"

  local bindmount_args=()
  [ -n "${EXTRA_BINDMOUNTS:-}" ] && bindmount_args=(--bindmounts "${EXTRA_BINDMOUNTS}")

  # -us -uc: skip signing (unnecessary for local/CI builds).
  # -b: binary-only build (no source package needed).
  sudo pdebuild --pbuilder pbuilder --debbuildopts "-us -uc -b" --buildresult "${DIST_DIR}" -- \
    --basetgz "${BASETGZ}" \
    "${bindmount_args[@]}" \
    || _check_error "pdebuild failed"
  echo "  > pdebuild complete"

  echo "✅ Build complete (version: ${NEW_VER})"

  # pdebuild generates source package artifacts (.dsc, .tar.gz, etc.) in the parent directory.
  # Remove them so the working tree stays clean after every build.
  echo "🗑️  [Cleanup] Removing source package artifacts from ../"
  rm -f "${SOURCE_DIR}/../${PKG_NAME}_"*.dsc \
        "${SOURCE_DIR}/../${PKG_NAME}_"*.tar.gz \
        "${SOURCE_DIR}/../${PKG_NAME}_"*.build \
        "${SOURCE_DIR}/../${PKG_NAME}_"*_source.changes
  echo "  > Artifacts removed"
}

# Remove build outputs.
# --apt-list : also remove the APT source list entry
# --tarball  : also remove the custom pbuilder base tarball
_clean() {
  echo "🧹 [Clean] Removing build artifacts"
  cd "${SOURCE_DIR}" || exit 1

  echo "🗑️  [1/2] Removing dist/, dist-package/, and build artifacts..."
  local clean_dirs=("dist/" "dist-package/")
  # Use caller-supplied extra dirs if provided, otherwise fall back to the default build output dir.
  if [ ${#CLEAN_EXTRA_DIRS[@]} -gt 0 ]; then
    clean_dirs+=("${CLEAN_EXTRA_DIRS[@]}")
  else
    clean_dirs+=("obj-${HOST_GNU_TYPE}/")
  fi
  rm -rf "${clean_dirs[@]}"
  echo "  > Build artifacts removed"

  # Remove source package artifacts that pdebuild generates in the parent directory.
  echo "🔄 [2/3] Removing source package artifacts from ../"
  rm -f "${SOURCE_DIR}/../${PKG_NAME}_"*.dsc \
        "${SOURCE_DIR}/../${PKG_NAME}_"*.tar.gz \
        "${SOURCE_DIR}/../${PKG_NAME}_"*.build \
        "${SOURCE_DIR}/../${PKG_NAME}_"*_source.changes
  echo "  > Source artifacts removed"

  echo "📋 [3/3] Restoring debian/changelog from backup..."
  if [ -f "${SOURCE_DIR}/debian/changelog.bak" ]; then
    mv "${SOURCE_DIR}/debian/changelog.bak" "${SOURCE_DIR}/debian/changelog"
    echo "  > changelog restored from backup"
  else
    echo "  > No changelog backup found, skipping"
  fi

  if [ "${CLEAN_APT_LIST}" = "1" ]; then
    echo "🗑️  [--apt-list] Removing APT source list... (${LIST_FILE})"
    if [ -f "$LIST_FILE" ]; then
      sudo rm -f "$LIST_FILE"
      sudo apt update
      echo "  > APT source list removed"
    else
      echo "  > Source list not found, skipping"
    fi
  fi

  if [ "${CLEAN_TARBALL}" = "1" ]; then
    # Only remove the custom tarball — never touch the stock base (shared across projects).
    if [ -n "${CUSTOM_BASETGZ_SUFFIX:-}" ]; then
      echo "🗑️  [--tarball] Removing custom base tarball... (${BASETGZ})"
      if sudo test -s "${BASETGZ}"; then
        sudo rm -f "${BASETGZ}"
        echo "  > Custom base tarball removed"
      else
        echo "  > Custom base tarball not found, skipping"
      fi
    else
      echo "  > CUSTOM_BASETGZ_SUFFIX not set, nothing to remove"
    fi
  fi

  echo "✨ Clean complete!"
}

# Remove the custom base tarball and recreate it from scratch.
# No-op if CUSTOM_BASETGZ_SUFFIX is not set (nothing to reset).
_base_reset() {
  if [ -z "${CUSTOM_BASETGZ_SUFFIX:-}" ]; then
    echo "⚠️  CUSTOM_BASETGZ_SUFFIX is not set — nothing to reset."
    exit 0
  fi

  echo "🔄 [Base Reset] Tarball: ${BASETGZ}"

  if sudo test -s "${BASETGZ}"; then
    echo "  > Removing existing custom base tarball..."
    sudo rm -f "${BASETGZ}" || _check_error "Failed to remove ${BASETGZ}"
    echo "  > Removed"
  else
    echo "  > Custom base tarball not found, will create fresh"
  fi

  _ensure_base
  echo "✅ Base reset complete: ${BASETGZ}"
}

# Create a local APT repository in dist-package/ from all .deb files in dist/.
_package_local() {
  echo "📦 [Package/local] Building local APT repository from dist/"

  echo "🔍 [1/3] Collecting .deb files..."
  if ! ls "${DIST_DIR}/"*.deb &>/dev/null; then
    echo "❌ No .deb files found in ${DIST_DIR}/. Run build first."
    exit 1
  fi

  rm -rf "${DIST_PKG_DIR}"
  mkdir -p "${DIST_PKG_DIR}"
  cp "${DIST_DIR}/"*.deb "${DIST_PKG_DIR}/" \
    || _check_error "Failed to copy .deb files to dist-package/"
  echo "  > .deb files copied to ${DIST_PKG_DIR}"

  echo "📝 [2/3] Generating Packages index..."
  cd "${DIST_PKG_DIR}" || exit 1
  dpkg-scanpackages . /dev/null | tee Packages > /dev/null \
    || _check_error "Failed to generate Packages index"
  # -k: keep the uncompressed Packages file alongside Packages.gz.
  gzip -fk Packages || _check_error "Failed to create Packages.gz"
  echo "  > Packages and Packages.gz generated"

  echo "📋 [3/3] Registering APT source list..."
  echo "  > Target path: ${LIST_FILE}"
  # trusted=yes: skip GPG signature check for the local file:// repository.
  echo "deb [trusted=yes] file://${DIST_PKG_DIR} ./" | sudo tee "$LIST_FILE" > /dev/null \
    || _check_error "Failed to register source list"
  sudo chmod -R 755 "${DIST_PKG_DIR}" || _check_error "Failed to set repository permissions"
  sudo apt update || _check_error "apt update failed"

  echo "--------------------------------------------------"
  echo "✅ Local repository ready: ${DIST_PKG_DIR}"
  echo "Install: apt install ${DEB_PKG_NAMES[*]}"
  echo "--------------------------------------------------"
  cd "${SOURCE_DIR}" || exit 1
}

# Upload .deb packages to JFrog Artifactory (https://gyujinv2.jfrog.io/artifactory/gj-test).
# Requires --jfrog-user and --jfrog-token.
_package_remote() {
  echo "📤 [Package/remote] Uploading .deb files to JFrog Artifactory"

  if [ -z "${JFROG_TOKEN}" ]; then
    echo "❌ --jfrog-token is required for remote packaging."
    exit 1
  fi

  echo "🔍 [1/2] Collecting .deb files from ${DIST_DIR}..."
  if ! ls "${DIST_DIR}/"*.deb &>/dev/null; then
    echo "❌ No .deb files found in ${DIST_DIR}/. Run build first."
    exit 1
  fi

  echo "📤 [2/2] Uploading to ${JFROG_URL} (distribution: ${DISTRO})..."
  for deb_file in "${DIST_DIR}/"*.deb; do
    local filename arch
    filename=$(basename "${deb_file}")
    # Extract architecture from filename: <name>_<version>_<arch>.deb
    arch=$(echo "${filename}" | sed 's/.*_\([^_]*\)\.deb$/\1/')

    echo "  > Uploading ${filename} (arch=${arch})..."
    curl -f -H "Authorization: Bearer ${JFROG_TOKEN}" \
      -XPUT "${JFROG_URL}/pool/${filename};deb.distribution=${DISTRO};deb.component=main;deb.architecture=${arch}" \
      -T "${deb_file}" \
      || _check_error "Failed to upload ${filename}"
    echo "  > Uploaded: ${filename}"
  done

  echo "--------------------------------------------------"
  echo "✅ Remote upload complete → ${JFROG_URL}"
  echo "--------------------------------------------------"
}

_package() {
  case "${PACKAGE_MODE}" in
    local)  _package_local ;;
    remote) _package_remote ;;
    *)
      echo "❌ Specify a package mode: package --local | --remote"
      exit 1
      ;;
  esac
}

echo "💡 Usage:"
echo "  build           [--jammy] [--name <n>] [--email <e>] [--tarball-dir <path>] [--source-dir <path>] : bump version and run pdebuild"
echo "  package --local [--jammy]                                                   : build dist-package/ from dist/*.deb"
echo "  package --remote --jfrog-token <t> [--jammy]                               : upload dist/*.deb to JFrog Artifactory"
echo "  clean                [--jammy]                                               : remove dist/, dist-package/, changelog.bak"
echo "  clean --apt-list     [--jammy]                                               : clean + remove APT source list"
echo "  clean --tarball      [--jammy] [--tarball-dir <path>]                        : clean + remove custom base tarball"
echo "  all     --local [--jammy] [--name <n>] [--email <e>] [--tarball-dir <path>] : build + package --local"
echo "  base-reset      [--jammy] [--tarball-dir <path>]                             : delete and recreate custom base tarball"
echo "  (default distro: noble / default tarball dir: /var/cache/pbuilder / default source dir: pwd)"

case "$COMMAND" in
  build)      _build ;;
  package)    _package ;;
  clean)      _clean ;;
  all)        _build && _package ;;
  base-reset) _base_reset ;;
  *)          echo "Usage: $0 {build|package --local|package --remote|clean [--force]|all --local|base-reset} [--jammy]" ;;
esac
