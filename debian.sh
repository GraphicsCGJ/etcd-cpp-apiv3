#!/bin/bash

# 1. Environment variables
export SOURCE_DIR=$(pwd)
export REPO_BASE="/opt/etcd-cpp-apiv3-repo"
export LIST_FILE="/etc/apt/sources.list.d/etcd-cpp-apiv3.list"

# Helper: print error message and exit if the last command failed
_check_error() {
  if [ $? -ne 0 ]; then
    echo "❌ Error: $1"
    exit 1
  fi
}

# Helper: run a command and stream its output
_run_with_log() {
  "$@" 2>&1
  return $?
}

_build() {
  echo "🔨 [Build] Source directory: ${SOURCE_DIR}"
  cd "${SOURCE_DIR}" || exit 1

  echo "🧹 [Prepare] Resetting debian/ directory..."
  echo "	Command: git restore debian/ && git clean -fd debian/"
  _run_with_log bash -c "git restore debian/ && git clean -fd debian/"
  _check_error "Failed to reset debian/"
  echo "  > debian/ reset complete"

  echo "📝 [1/3] Generating version with dch..."
  echo "	Command: dch -v \${NEW_VER} --force-bad-version --no-query \"Automated CI/CD build\""

  export DEBFULLNAME="Gyujin"
  export DEBEMAIL="ckjin95@gmail.com"

  # Append build timestamp to current version
  # e.g. 0.15.4-1 -> 0.15.4-1+build202603082115
  local CURRENT_VER=$(dpkg-parsechangelog -S Version)
  local NEW_VER="${CURRENT_VER}+build$(date +%Y%m%d%H%M)"
  echo "  > Current version: ${CURRENT_VER}"
  echo "  > New version:     ${NEW_VER}"

  _run_with_log dch -v "${NEW_VER}" --force-bad-version --no-query "Automated CI/CD build"
  _check_error "Failed to update version with dch"
  echo "  > changelog updated"

  echo "📦 [2/3] Starting isolated build with pdebuild..."
  echo "	Command: sudo pdebuild --pbuilder pbuilder --debbuildopts \"-us -uc -b\" --buildresult \${SOURCE_DIR}/dist"
  echo "  > Output path: ${SOURCE_DIR}/dist"
  mkdir -p "${SOURCE_DIR}/dist"
  _run_with_log sudo pdebuild --pbuilder pbuilder --debbuildopts "-us -uc -b" --buildresult "${SOURCE_DIR}/dist" -- --basetgz /var/cache/pbuilder/jammy-base.tgz
  _check_error "pdebuild failed"
  echo "  > pdebuild complete"

  echo "📂 [3/3] Copying build artifacts to repository..."
  echo "	Command: sudo cp \${SOURCE_DIR}/dist/libetcd-cpp-apiv3-dev_\${NEW_VER}_*.deb \${REPO_BASE}/"
  echo "  > Target repository: ${REPO_BASE}"
  sudo mkdir -p "$REPO_BASE"
  _run_with_log sudo cp "${SOURCE_DIR}/dist/libetcd-cpp-apiv3-dev_${NEW_VER}_"*.deb "$REPO_BASE/"
  _check_error "Failed to copy package"
  echo "  > .deb file copied"

  echo "✅ Build and copy complete (version: ${NEW_VER})"
  cd "${SOURCE_DIR}" || exit 1
  git checkout debian/changelog
  echo "  > debian/changelog restored"

  echo "🗑️  [Cleanup] Removing source package artifacts from ../"
  rm -f "${SOURCE_DIR}/../etcd-cpp-apiv3_"*.dsc \
        "${SOURCE_DIR}/../etcd-cpp-apiv3_"*.tar.gz \
        "${SOURCE_DIR}/../etcd-cpp-apiv3_"*.build \
        "${SOURCE_DIR}/../etcd-cpp-apiv3_"*_source.changes
  echo "  > Artifacts removed"
}

_clean() {
  echo "🧹 [Clean] Removing build artifacts and repository config"
  cd "${SOURCE_DIR}" || exit 1

  echo "🗑️  [1/5] Removing dist/ and debian build artifacts..."
  echo "	Command: git restore debian/changelog && git clean -fdx debian/ obj-x86_64-linux-gnu/ dist/"
  git restore debian/changelog 2>/dev/null
  git clean -fdx debian/ obj-x86_64-linux-gnu/ dist/
  echo "  > Build artifacts removed"

  echo "🗑️  [2/5] Clearing local repository... (${REPO_BASE})"
  echo "	Command: sudo rm -rf \${REPO_BASE}/*"
  if [ -d "$REPO_BASE" ]; then
    sudo rm -rf "${REPO_BASE:?}"/*
    echo "  > Repository directory ($REPO_BASE) cleared"
  else
    echo "  > Repository directory not found, skipping"
  fi

  echo "🗑️  [3/5] Removing APT source list... (${LIST_FILE})"
  echo "	Command: sudo rm -f \${LIST_FILE}"
  if [ -f "$LIST_FILE" ]; then
    sudo rm -f "$LIST_FILE"
    echo "  > APT source list ($LIST_FILE) removed"
  else
    echo "  > Source list file not found, skipping"
  fi

  echo "🔄 [4/5] Removing source package artifacts from ../"
  rm -f "${SOURCE_DIR}/../etcd-cpp-apiv3_"*.dsc \
        "${SOURCE_DIR}/../etcd-cpp-apiv3_"*.tar.gz \
        "${SOURCE_DIR}/../etcd-cpp-apiv3_"*.build \
        "${SOURCE_DIR}/../etcd-cpp-apiv3_"*_source.changes
  echo "  > Source artifacts removed"

  echo "🔄 [5/5] Refreshing APT index..."
  echo "	Command: sudo apt update"
  _run_with_log sudo apt update

  echo "✨ Clean complete!"
  cd "${SOURCE_DIR}" || exit 1
}

_package() {
  echo "📦 [Package] Setting up local APT repository"
  cd "${SOURCE_DIR}" || exit 1

  echo "🔍 [1/3] Verifying repository directory and generating Packages index..."
  echo "	Command: sudo dpkg-scanpackages . /dev/null | sudo tee Packages && sudo gzip -fk Packages"
  if [ ! -d "$REPO_BASE" ]; then
    echo "❌ Repository directory not found. Run _build first."
    exit 1
  fi
  echo "  > Repository path: ${REPO_BASE}"
  cd "$REPO_BASE" || exit 1

  _run_with_log bash -c "sudo dpkg-scanpackages . /dev/null | sudo tee Packages > /dev/null"
  _check_error "Failed to generate Packages index"
  echo "  > Packages index generated"

  _run_with_log sudo gzip -fk Packages
  _check_error "Failed to create Packages.gz"
  echo "  > Packages.gz compressed"

  echo "📋 [2/3] Registering APT source list..."
  echo "	Command: echo \"deb [trusted=yes] file://\${REPO_BASE} ./\" | sudo tee \${LIST_FILE}"
  echo "  > Target path: ${LIST_FILE}"
  echo "deb [trusted=yes] file://${REPO_BASE} ./" | sudo tee "$LIST_FILE" > /dev/null
  _check_error "Failed to register source list"
  echo "  > Source list registered"

  sudo chmod -R 755 "$REPO_BASE"
  _check_error "Failed to set repository permissions"
  echo "  > Repository permissions (755) set"

  echo "🔄 [3/3] Running apt update..."
  echo "	Command: sudo apt update"
  _run_with_log sudo apt update
  _check_error "apt update failed"

  echo "--------------------------------------------------"
  echo "✅ All done!"
  echo "Check install: apt list libetcd-cpp-apiv3-dev"
  echo "--------------------------------------------------"
  cd "${SOURCE_DIR}" || exit 1
}

# Usage
echo "💡 Usage (source debian.sh then call, or run directly):"
echo "  _build   : bump version with dch and run pdebuild in isolation"
echo "  _package : set up and register local APT repository"
echo "  _clean   : remove all build artifacts and repository config"

# Entry point
case "$1" in
  build)   _build ;;
  package) _package ;;
  clean)   _clean ;;
  all)     _build && _package ;;
  *)       echo "Usage: $0 {build|package|clean|all}" ;;
esac
