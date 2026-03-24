#!/bin/bash
# =============================================================================
# debian.sh — Debian packaging script (pbuilder-based)
# Project configuration is loaded from debian.cfg in the same directory.
# =============================================================================

_SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
_CFG="${_SCRIPT_DIR}/debian.cfg"
if [ ! -f "${_CFG}" ]; then
  echo "❌ debian.cfg not found: ${_CFG}"
  exit 1
fi
# shellcheck source=debian.cfg
source "${_CFG}"
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
# LOCAL PACKAGE REPO  (for package --local)
#   --pkg-dir <path>   Override the package repository directory
#                      Default: <source-dir>/dist-package/<distro>/
#                      Packages index is regenerated on every run — .deb files accumulate.
#                      Use clean --packages to wipe the repo.
#
# JFROG  (for package --jfrog)
#   Resolved in order: env var → CLI arg → fail
#   JFROG_TOKEN     / --jfrog-token     <token>  JFrog Identity Token (Reference Token)
#   JFROG_URL       / --jfrog-url       <url>    Artifactory repository URL
#   JFROG_COMPONENT / --jfrog-component <name>   Debian component  (default: main)
#
# APTLY  (for package --aptly)
#   Resolved in order: env var → CLI arg → fail
#   APTLY_TOKEN / --aptly-token <token>  Aptly API Bearer token
#   APTLY_URL   / --aptly-url   <url>    Aptly API base URL (e.g. http://aptly.example.com:8080)
#   APTLY_REPO  / --aptly-repo  <name>   Aptly local repository name

# Maintainer identity used by dch when bumping the changelog version.
DEBFULLNAME="${DEBFULLNAME:-Gyujin}"
DEBEMAIL="${DEBEMAIL:-ckjin95@gmail.com}"

# Parse the subcommand first, then consume remaining flags.
DISTRO="noble"  # default: Ubuntu 24.04 LTS
CLEAN_APT_LIST=0
CLEAN_PACKAGES=0
CLEAN_TARBALL=0
JFROG_LIST=0
JFROG_REMOVE=""
APTLY_LIST=0
APTLY_LIST_REPOS=0
APTLY_REMOVE=""
PACKAGE_MODE=""
TARBALL_DIR="/var/cache/pbuilder"
SOURCE_DIR=$(pwd)
_PKG_DIR_ARG=""
# CLI-supplied JFrog values (env vars take priority; resolved after arg parsing below).
_CLI_JFROG_TOKEN=""
_CLI_JFROG_URL=""
_CLI_JFROG_COMPONENT=""
# CLI-supplied Aptly values (env vars take priority; resolved after arg parsing below).
_CLI_APTLY_TOKEN=""
_CLI_APTLY_URL=""
_CLI_APTLY_REPO=""
COMMAND="$1"
shift
while [ $# -gt 0 ]; do
  case "$1" in
    --jammy)        DISTRO="jammy" ;;   # Target Ubuntu 22.04 instead of the default 24.04
    --apt-list)     CLEAN_APT_LIST=1 ;; # Also remove APT source list on clean
    --packages)     CLEAN_PACKAGES=1 ;; # Also remove local package repo on clean
    --tarball)      CLEAN_TARBALL=1 ;;  # Also remove custom base tarball on clean
    --list)         APTLY_LIST=1; JFROG_LIST=1 ;;
    --list-repos)   APTLY_LIST_REPOS=1 ;;
    --remove)       APTLY_REMOVE="$2"; JFROG_REMOVE="$2"; shift ;;
    --local)        PACKAGE_MODE="local" ;;
    --jfrog)        PACKAGE_MODE="jfrog" ;;
    --aptly)        PACKAGE_MODE="aptly" ;;
    --name)         DEBFULLNAME="$2"; shift ;;
    --email)        DEBEMAIL="$2"; shift ;;
    --pkg-dir)      _PKG_DIR_ARG=$(realpath "$2"); shift ;;  # Override local package repo path
    --tarball-dir)  TARBALL_DIR="$2"; shift ;;  # Override tarball directory (e.g. for CI caching)
    --source-dir)   SOURCE_DIR=$(realpath "$2"); shift ;;  # Override source directory (e.g. for monorepo CI)
    --jfrog-token)      _CLI_JFROG_TOKEN="$2"; shift ;;
    --jfrog-url)        _CLI_JFROG_URL="$2"; shift ;;
    --jfrog-component)  _CLI_JFROG_COMPONENT="$2"; shift ;;
    --aptly-token)  _CLI_APTLY_TOKEN="$2"; shift ;;
    --aptly-url)    _CLI_APTLY_URL="$2"; shift ;;
    --aptly-repo)   _CLI_APTLY_REPO="$2"; shift ;;
  esac
  shift
done

# env var > CLI arg (inherit from environment if already set, else fall back to CLI)
JFROG_TOKEN="${JFROG_TOKEN:-${_CLI_JFROG_TOKEN}}"
JFROG_URL="${JFROG_URL:-${_CLI_JFROG_URL}}"
JFROG_URL="${JFROG_URL%/}"  # strip trailing slash
JFROG_COMPONENT="${JFROG_COMPONENT:-${_CLI_JFROG_COMPONENT}}"
JFROG_COMPONENT="${JFROG_COMPONENT:-main}"  # default component
APTLY_TOKEN="${APTLY_TOKEN:-${_CLI_APTLY_TOKEN}}"
APTLY_URL="${APTLY_URL:-${_CLI_APTLY_URL}}"
APTLY_URL="${APTLY_URL%/}"  # strip trailing slash
APTLY_REPO="${APTLY_REPO:-${_CLI_APTLY_REPO}}"

# Absolute path of the source tree; used throughout to avoid working-directory confusion.
export SOURCE_DIR

# Build output directory, separated by distro (e.g. dist/jammy/, dist/noble/).
DIST_DIR="${SOURCE_DIR}/dist/${DISTRO}"
# Local APT package repository: use --pkg-dir if given, otherwise default per-distro path.
if [ -n "${_PKG_DIR_ARG}" ]; then
  DIST_PKG_DIR="${_PKG_DIR_ARG}"
else
  DIST_PKG_DIR="${SOURCE_DIR}/dist-package/${DISTRO}"
fi
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
  # Strip any accumulated +build... suffix so dates never pile up.
  BASE_VER="${CURRENT_VER%%+build*}"
  local NEW_VER="${BASE_VER}+build-$(date +%y%m%d)~${DISTRO}"
  echo "  > Current version: ${CURRENT_VER}"
  echo "  > New version:     ${NEW_VER}"

  # Back up changelog before dch modifies it; restore on exit regardless of outcome.
  # Stored outside debian/ to prevent dh_clean from deleting it during the build.
  cp debian/changelog "${SOURCE_DIR}/.changelog.bak"
  trap 'mv "${SOURCE_DIR}/.changelog.bak" "${SOURCE_DIR}/debian/changelog"; trap - EXIT' EXIT

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
# Default : remove dist/<distro>/ (build artifacts for the current distro) and obj dirs.
# --packages : also remove the local package repository (DIST_PKG_DIR)
# --apt-list : also remove the APT source list entry
# --tarball  : also remove the custom pbuilder base tarball
_clean() {
  echo "🧹 [Clean] Removing build artifacts"
  cd "${SOURCE_DIR}" || exit 1

  echo "🗑️  [1/3] Removing dist/${DISTRO}/ and build artifacts..."
  local clean_dirs=("dist/${DISTRO}/")
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
  if [ -f "${SOURCE_DIR}/.changelog.bak" ]; then
    mv "${SOURCE_DIR}/.changelog.bak" "${SOURCE_DIR}/debian/changelog"
    echo "  > changelog restored from backup"
  else
    echo "  > No changelog backup found, skipping"
  fi

  if [ "${CLEAN_PACKAGES}" = "1" ]; then
    echo "🗑️  [--packages] Removing local package repository... (${DIST_PKG_DIR})"
    if [ -d "${DIST_PKG_DIR}" ]; then
      rm -rf "${DIST_PKG_DIR}"
      echo "  > Package repository removed"
    else
      echo "  > Package repository not found, skipping"
    fi
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

# Manage packages in JFrog Artifactory.
# jfrog --list             : list all .deb files in the repo
# jfrog --remove <str>     : delete files whose name contains <str>
_jfrog() {
  if [ -z "${JFROG_TOKEN}" ]; then
    echo "❌ JFROG_TOKEN must be set."
    exit 1
  fi
  if [ -z "${JFROG_URL}" ]; then
    echo "❌ JFROG_URL must be set."
    exit 1
  fi

  # Derive repoKey and base Artifactory URL from JFROG_URL
  # Expected format: https://<org>.jfrog.io/artifactory/<repoKey>
  local base_url repo_key
  base_url=$(echo "${JFROG_URL}" | sed 's|/artifactory/.*|/artifactory|')
  repo_key=$(echo "${JFROG_URL}" | sed 's|.*/artifactory/||')

  if [ "${JFROG_LIST}" = "1" ]; then
    echo "📋 [JFrog] Packages in '${repo_key}':"
    curl -sf -H "Authorization: Bearer ${JFROG_TOKEN}" \
      "${base_url}/api/storage/${repo_key}/pool?list&deep=1" \
      | python3 -c "
import sys, json
data = json.load(sys.stdin)
files = [f for f in data.get('files', []) if f['uri'].endswith('.deb')]
if not files:
    print('  (empty)')
else:
    print(f\"  {'File':<60} {'Size':>10}\")
    print('  ' + '-'*72)
    for f in sorted(files, key=lambda x: x['uri']):
        size = int(f.get('size', 0))
        size_str = f'{size//1024} KB' if size >= 1024 else f'{size} B'
        print(f\"  {f['uri'].lstrip('/'):<60} {size_str:>10}\")
" || _check_error "Failed to list JFrog packages"
  fi

  if [ -n "${JFROG_REMOVE}" ]; then
    echo "🗑️  [JFrog] Removing files matching '${JFROG_REMOVE}' from '${repo_key}'..."
    local file_list
    file_list=$(curl -sf -H "Authorization: Bearer ${JFROG_TOKEN}" \
      "${base_url}/api/storage/${repo_key}/pool?list&deep=1" \
      | python3 -c "
import sys, json
data = json.load(sys.stdin)
matched = [f['uri'].lstrip('/') for f in data.get('files', [])
           if '${JFROG_REMOVE}' in f['uri'] and f['uri'].endswith('.deb')]
print('\n'.join(matched))
") || _check_error "Failed to query JFrog packages"

    if [ -z "${file_list}" ]; then
      echo "  > No matching files found"
    else
      echo "${file_list}" | while IFS= read -r filepath; do
        echo "  > Deleting: ${filepath}"
        curl -sf -X DELETE \
          -H "Authorization: Bearer ${JFROG_TOKEN}" \
          "${base_url}/${repo_key}/${filepath}" \
          || _check_error "Failed to delete ${filepath}"
        echo "  > Deleted"
      done
      echo "✅ Done"
    fi
  fi
}

# Manage packages in an Aptly repository.
# aptly --list-repos                    : list all repos on server
# aptly --list                          : show all packages in the repo (no distro needed)
# aptly --remove <str> [--jammy]        : remove packages matching <str>, then publish (distro needed for publish endpoint)
_aptly() {
  if [ -z "${APTLY_TOKEN}" ] || [ -z "${APTLY_URL}" ]; then
    echo "❌ APTLY_TOKEN, APTLY_URL must be set."
    exit 1
  fi

  if [ "${APTLY_LIST_REPOS}" = "1" ]; then
    echo "📦 [Aptly] Repositories on ${APTLY_URL}:"
    curl -sf -H "Authorization: Bearer ${APTLY_TOKEN}" \
      "${APTLY_URL}/api/repos" \
      | python3 -c "
import sys, json
repos = json.load(sys.stdin)
if not repos:
    print('  (none)')
else:
    print(f\"  {'Name':<30} {'Comment'}\")
    print('  ' + '-'*60)
    for r in repos:
        print(f\"  {r['Name']:<30} {r.get('Comment', '')}\")
" || _check_error "Failed to list aptly repos"
    return
  fi

  if [ -z "${APTLY_REPO}" ]; then
    echo "❌ APTLY_REPO must be set."
    exit 1
  fi

  local all_refs all_pkgs
  all_refs=$(curl -sf -H "Authorization: Bearer ${APTLY_TOKEN}" \
    "${APTLY_URL}/api/repos/${APTLY_REPO}/packages") \
    || _check_error "Failed to query aptly repo '${APTLY_REPO}'"
  all_pkgs=$(curl -sf -H "Authorization: Bearer ${APTLY_TOKEN}" \
    "${APTLY_URL}/api/repos/${APTLY_REPO}/packages?format=details") \
    || _check_error "Failed to query aptly repo details"

  if [ "${APTLY_LIST}" = "1" ]; then
    echo "📋 [Aptly] Packages in '${APTLY_REPO}':"
    echo "${all_pkgs}" | python3 -c "
import sys, json
pkgs = json.load(sys.stdin)
if not pkgs:
    print('  (empty)')
else:
    print(f\"  {'Package':<30} {'Version':<40} {'Arch'}\")
    print('  ' + '-'*75)
    for p in pkgs:
        print(f\"  {p['Package']:<30} {p['Version']:<40} {p['Architecture']}\")
"
  fi

  if [ -n "${APTLY_REMOVE}" ]; then
    echo "🗑️  [Aptly] Removing packages matching '${APTLY_REMOVE}' from '${APTLY_REPO}'..."
    local remove_refs
    remove_refs=$(echo "${all_refs}" | python3 -c "
import sys, json
pkgs = json.load(sys.stdin)
matched = [p for p in pkgs if '${APTLY_REMOVE}' in p]
print(json.dumps(matched))
")
    if [ "${remove_refs}" = "[]" ]; then
      echo "  > No matching packages found"
    else
      echo "  > Removing: ${remove_refs}"
      curl -sf -X DELETE \
        -H "Authorization: Bearer ${APTLY_TOKEN}" \
        -H "Content-Type: application/json" \
        --data "{\"PackageRefs\": ${remove_refs}}" \
        "${APTLY_URL}/api/repos/${APTLY_REPO}/packages" \
        || _check_error "Failed to delete packages"
      echo "  > Removed. Updating publish..."
      curl -sf --path-as-is -X PUT \
        -H "Authorization: Bearer ${APTLY_TOKEN}" \
        -H "Content-Type: application/json" \
        --data '{"Signing": {"Skip": true}}' \
        "${APTLY_URL}/api/publish/./${DISTRO}" \
        || _check_error "Failed to update aptly publish"
      echo "  > Publish updated"
    fi
  fi
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

# Add .deb files from dist/ into the local APT repository, then regenerate the Packages index.
# The repository accumulates across builds — existing packages are not removed.
# Same-filename packages (identical name+version+arch) are overwritten by the latest build.
# Use 'clean --packages' to wipe the repository from scratch.
_package_local() {
  echo "📦 [Package/local] Adding .deb files to local APT repository"
  echo "  > Repository: ${DIST_PKG_DIR}"

  echo "🔍 [1/3] Collecting .deb files from ${DIST_DIR}..."
  if ! ls "${DIST_DIR}/"*.deb &>/dev/null; then
    echo "❌ No .deb files found in ${DIST_DIR}/. Run build first."
    exit 1
  fi

  mkdir -p "${DIST_PKG_DIR}"
  cp "${DIST_DIR}/"*.deb "${DIST_PKG_DIR}/" \
    || _check_error "Failed to copy .deb files to ${DIST_PKG_DIR}/"
  echo "  > .deb files copied ($(ls "${DIST_PKG_DIR}/"*.deb | wc -l) total in repo)"

  echo "📝 [2/3] Regenerating Packages index..."
  cd "${DIST_PKG_DIR}" || exit 1
  dpkg-scanpackages . /dev/null | tee Packages > /dev/null \
    || _check_error "Failed to generate Packages index"
  # -k: keep the uncompressed Packages file alongside Packages.gz.
  gzip -fk Packages || _check_error "Failed to create Packages.gz"
  echo "  > Packages index updated"

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

# Upload .deb packages to JFrog Artifactory.
# Credentials resolved at startup: env var > CLI arg (--jfrog-token / --jfrog-url).
_package_jfrog() {
  echo "📤 [Package/jfrog] Uploading .deb files to JFrog Artifactory"

  if [ -z "${JFROG_TOKEN}" ]; then
    echo "❌ JFrog token not set. Use --jfrog-token or set JFROG_TOKEN env var."
    exit 1
  fi
  if [ -z "${JFROG_URL}" ]; then
    echo "❌ JFrog URL not set. Use --jfrog-url or set JFROG_URL env var."
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

    echo "  > Uploading ${filename} (arch=${arch}, component=${JFROG_COMPONENT})..."
    curl -f -H "Authorization: Bearer ${JFROG_TOKEN}" \
      -XPUT "${JFROG_URL}/pool/${filename};deb.distribution=${DISTRO};deb.component=${JFROG_COMPONENT};deb.architecture=${arch}" \
      -T "${deb_file}" \
      || _check_error "Failed to upload ${filename}"
    echo "  > Uploaded: ${filename}"
  done

  echo "--------------------------------------------------"
  echo "✅ JFrog upload complete → ${JFROG_URL}"
  echo "--------------------------------------------------"
}

# Upload .deb packages to an Aptly API server.
# Credentials resolved at startup: env var > CLI arg (--aptly-token / --aptly-url / --aptly-repo).
# Steps:
#   1. Upload each .deb to a temporary staging directory on the server.
#   2. Add packages from the staging directory into the local Aptly repo.
#   3. Trigger a publish update so clients can see the new packages.
_package_aptly() {
  echo "📤 [Package/aptly] Uploading .deb files to Aptly"

  if [ -z "${APTLY_TOKEN}" ]; then
    echo "❌ Aptly token not set. Use --aptly-token or set APTLY_TOKEN env var."
    exit 1
  fi
  if [ -z "${APTLY_URL}" ]; then
    echo "❌ Aptly URL not set. Use --aptly-url or set APTLY_URL env var."
    exit 1
  fi
  if [ -z "${APTLY_REPO}" ]; then
    echo "❌ Aptly repo not set. Use --aptly-repo or set APTLY_REPO env var."
    exit 1
  fi

  echo "🔍 [1/3] Collecting .deb files from ${DIST_DIR}..."
  if ! ls "${DIST_DIR}/"*.deb &>/dev/null; then
    echo "❌ No .deb files found in ${DIST_DIR}/. Run build first."
    exit 1
  fi

  # Use a per-package per-distro staging directory to avoid collisions with concurrent uploads.
  local upload_dir="${PKG_NAME}-${DISTRO}"

  echo "📤 [2/3] Uploading to ${APTLY_URL} (staging dir: ${upload_dir})..."
  for deb_file in "${DIST_DIR}/"*.deb; do
    local filename
    filename=$(basename "${deb_file}")
    echo "  > Uploading ${filename}..."
    curl -f -H "Authorization: Bearer ${APTLY_TOKEN}" \
      -F "file=@${deb_file}" \
      "${APTLY_URL}/api/files/${upload_dir}" \
      || _check_error "Failed to upload ${filename}"
    echo "  > Uploaded: ${filename}"
  done

  echo "📋 [3/3] Adding packages to repo '${APTLY_REPO}' and updating publish..."
  curl -f -X POST -H "Authorization: Bearer ${APTLY_TOKEN}" \
    "${APTLY_URL}/api/repos/${APTLY_REPO}/file/${upload_dir}" \
    || _check_error "Failed to add packages to repo '${APTLY_REPO}'"
  echo "  > Packages added to repo"

  curl -f -X PUT \
    -H "Authorization: Bearer ${APTLY_TOKEN}" \
    -H "Content-Type: application/json" \
    --data '{"Signing": {"Skip": true}}' \
    --path-as-is "${APTLY_URL}/api/publish/./${DISTRO}" \
    || _check_error "Failed to update publish for distribution '${DISTRO}'"
  echo "  > Publish updated (distribution: ${DISTRO})"

  echo "--------------------------------------------------"
  echo "✅ Aptly upload complete → ${APTLY_URL} (repo: ${APTLY_REPO}, distro: ${DISTRO})"
  echo "--------------------------------------------------"
}

_package() {
  case "${PACKAGE_MODE}" in
    local)  _package_local ;;
    jfrog)  _package_jfrog ;;
    aptly)  _package_aptly ;;
    *)
      echo "❌ Specify a package mode: package --local | --jfrog | --aptly"
      exit 1
      ;;
  esac
}

echo ""
echo "Usage: $(basename "$0") <command> [options]"
echo ""
echo "━━━ BUILD ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  build           Bump version and run pdebuild"
echo "                  [--jammy] [--name <n>] [--email <e>]"
echo "                  [--tarball-dir <path>] [--source-dir <path>]"
echo ""
echo "━━━ PACKAGE ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  package --local   Accumulate dist/*.deb into local APT repo"
echo "                    [--pkg-dir <path>] [--jammy]"
echo ""
echo "  package --jfrog   Upload dist/*.deb to JFrog Artifactory"
echo "                    [--jfrog-token <t>] [--jfrog-url <u>] [--jfrog-component <c>] [--jammy]"
echo "                    (env: JFROG_TOKEN, JFROG_URL, JFROG_COMPONENT)"
echo ""
echo "  package --aptly   Upload dist/*.deb to Aptly"
echo "                    [--aptly-token <t>] [--aptly-url <u>] [--aptly-repo <r>] [--jammy]"
echo "                    (env: APTLY_TOKEN, APTLY_URL, APTLY_REPO)"
echo ""
echo "━━━ CLEAN ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  clean             Remove dist/<distro>/ and obj dirs  [--jammy]"
echo "  clean --packages  Also remove local package repo      [--pkg-dir <path>] [--jammy]"
echo "  clean --apt-list  Also remove APT source list         [--jammy]"
echo "  clean --tarball   Also remove custom base tarball     [--tarball-dir <path>] [--jammy]"
echo ""
echo "━━━ JFROG ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  jfrog --list              List .deb files in JFrog repo"
echo "  jfrog --remove <str>      Delete files whose name contains <str>"
echo "                            (env: JFROG_TOKEN, JFROG_URL)"
echo ""
echo "━━━ APTLY ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  aptly --list-repos        List all repos on Aptly server"
echo "  aptly --list              List packages in Aptly repo  [--aptly-repo <r>]"
echo "  aptly --remove <str>      Remove packages matching <str>, update publish"
echo "                            [--aptly-repo <r>] [--jammy]"
echo ""
echo "━━━ OTHER ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  all --local       Build + package --local"
echo "                    [--pkg-dir <path>] [--jammy] [--name <n>] [--email <e>]"
echo "  base-reset        Delete and recreate custom base tarball"
echo "                    [--jammy] [--tarball-dir <path>]"
echo ""
echo "  Defaults: distro=noble  tarball-dir=/var/cache/pbuilder  source-dir=\$PWD"
echo ""

case "$COMMAND" in
  build)      _build ;;
  package)    _package ;;
  clean)      _clean ;;
  jfrog)      _jfrog ;;
  aptly)      _aptly ;;
  all)        _build && _package ;;
  base-reset) _base_reset ;;
  *)          echo "Usage: $0 {build|package --local|package --jfrog|package --aptly|clean|aptly --list|aptly --remove|all --local|base-reset} [--jammy]" ;;
esac
