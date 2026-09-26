#!/usr/bin/env bash
# Shared failure classification for apt retry wrappers.
#
# Exit zero only when the captured command output contains evidence of a
# transient apt transport or mirror-publication failure. Exit one for every
# other failure so retries cannot hide a real package, Playwright, or workflow
# configuration error.
set -euo pipefail

hasPermanentRepositoryFailure() {
  local logFile="$1"

  grep -Eiq \
    'does not have a release file|the repository[^[:cntrl:]]+is not signed' \
    "$logFile"
}

hasMissingPackageFailure() {
  local logFile="$1"

  grep -Eiq \
    'unable to locate package|has no installation candidate' \
    "$logFile"
}

# Empty/partial package lists after a failed index fetch make apt report
# "Unable to locate package" for packages that do exist. That is a mirror
# problem (AEG-8528), not a missing-package configuration error.
hasFailedIndexDownload() {
  local logFile="$1"

  grep -Eiq \
    'index files failed to download|failed to fetch[^[:cntrl:]]*(inrelease|release\.gpg|/packages|connection (failed|timed out|reset by peer)|hash sum mismatch|file has unexpected size|mirror sync in progress)' \
    "$logFile"
}

hasPermanentAptFailure() {
  local logFile="$1"

  # Repo-configuration errors are never retryable, even when a mirror also
  # failed to publish indexes.
  if hasPermanentRepositoryFailure "$logFile"; then
    return 0
  fi

  # A warning from an earlier command cannot make a later genuine missing-
  # package error retryable. Missing-package messages that follow a failed
  # index download are the failed indexes talking, not a real missing package.
  if hasMissingPackageFailure "$logFile" && ! hasFailedIndexDownload "$logFile"; then
    return 0
  fi

  return 1
}

hasPermanentBrowserFailure() {
  local logFile="$1"

  grep -Eiq \
    'invalid installation target|unknown browser|unsupported browser|browser[^[:cntrl:]]+is not supported' \
    "$logFile"
}

isTransientAptFailure() {
  local logFile="$1"

  [ -f "$logFile" ] || return 1

  # A warning from an earlier command cannot make a later package or
  # repository-configuration error retryable.
  if hasPermanentAptFailure "$logFile"; then
    return 1
  fi

  grep -Eiq \
    'index files failed to download|file has unexpected size|mirror sync in progress|hash sum mismatch|temporary failure resolving|could not resolve|could not connect to|connection (failed|timed out|reset by peer)|network is unreachable|tls connection was non-properly terminated|429 too many requests|502 bad gateway|503 service unavailable|504 gateway time-out' \
    "$logFile"
}

isTransientPlaywrightAptFailure() {
  local logFile="$1"

  # A transient-looking warning earlier in the install is not enough: require
  # Playwright's apt subprocess exit-100 marker too. This prevents a later CDN,
  # browser-name, or configuration failure from being retried or sent through
  # the dependency-free fallback just because apt printed a harmless warning.
  ! hasPermanentBrowserFailure "$logFile" &&
    isTransientAptFailure "$logFile" &&
    grep -Eiq \
      'installation process exited with code:[[:space:]]*100|apt-get[^[:cntrl:]]*(exited|returned|failed)[^[:cntrl:]]*100' \
      "$logFile"
}

isTransientBrowserDownloadFailure() {
  local logFile="$1"

  [ -f "$logFile" ] || return 1

  # Playwright's downloader is Node-based, so its CDN failures commonly use
  # Node error codes rather than apt's prose. Keep this transport-only: invalid
  # browser names and other configuration failures must still fail immediately.
  if hasPermanentBrowserFailure "$logFile"; then
    return 1
  fi

  isTransientAptFailure "$logFile" ||
    grep -Eiq \
      '(^|[^[:alnum:]_])(ECONNRESET|ETIMEDOUT|EAI_AGAIN|ENOTFOUND)([^[:alnum:]_]|$)|socket hang up|client network socket disconnected before secure tls connection was established|server returned (response )?code:?[[:space:]]*(429|502|503|504)' \
      "$logFile"
}

# The direct entrypoint is intentionally tiny so the behavior can be exercised
# with fixture logs without invoking apt or downloading a browser.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  mode="${1:-}"
  logFile="${2:-}"

  case "$mode" in
    apt) isTransientAptFailure "$logFile" ;;
    browser) isTransientBrowserDownloadFailure "$logFile" ;;
    playwright) isTransientPlaywrightAptFailure "$logFile" ;;
    *)
      echo "Usage: $0 <apt|browser|playwright> <captured-log>" >&2
      exit 2
      ;;
  esac
fi
