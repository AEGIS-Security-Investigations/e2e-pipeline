#!/usr/bin/env bash
# Install Playwright browsers (and their system libraries) without letting a
# transient Ubuntu mirror failure take the job down.
#
# `playwright install --with-deps` shells out to `sudo sh -c "apt-get update &&
# apt-get install ..."`. When a mirror is mid-sync that apt-get exits 100 and
# Playwright reports only:
#
#   Failed to install browsers
#   Error: Installation process exited with code: 100
#
# The apt configuration written by the apt-hardening action removes most of that
# exposure (fewer indexes, apt-level retries). This script covers the rest:
# retry the whole install, clearing the half-synced apt lists between attempts,
# and - if the mirror never recovers - fall back to installing the browser
# binaries without deps, which is safe only because it is immediately proven by
# actually launching the browser.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../apt-hardening/classifyAptFailure.sh
source "$SCRIPT_DIR/../apt-hardening/classifyAptFailure.sh"

BROWSERS="${PW_BROWSERS:-chromium}"
WITH_DEPS="${PW_WITH_DEPS:-true}"
ATTEMPTS="${PW_INSTALL_ATTEMPTS:-3}"
ATTEMPT_TIMEOUT="${PW_INSTALL_ATTEMPT_TIMEOUT:-90s}"
BROWSER_DOWNLOAD_TIMEOUT="${PW_BROWSER_DOWNLOAD_TIMEOUT:-3m}"
DEPS_FALLBACK="${PW_DEPS_FALLBACK:-true}"

if ! [[ "$ATTEMPTS" =~ ^[0-9]+$ ]] || [ "$ATTEMPTS" -lt 1 ]; then
  ATTEMPTS=3
fi

# Deliberately unquoted at the call sites below: BROWSERS is a space separated
# list of Playwright browser names (e.g. "chromium firefox") and must word
# split. It comes from workflow inputs, never from user data.
# shellcheck disable=SC2206
read -r -a BROWSER_ARGS <<<"$BROWSERS"

# CI restores ~/.cache/ms-playwright before this step. When that cache is warm,
# `playwright install` still hits the CDN and can time out at 90s × 3 (exit 124)
# even though Chromium already launches — that is what reddened Flaky First
# shards across unrelated PRs (AEG-10217). Probe the restored binary directly
# (not `bunx playwright`, which the install-retry tests count as an attempt)
# and skip the download when it runs. A miss falls through to install/retry.
playwrightCacheDir="${PLAYWRIGHT_BROWSERS_PATH:-$HOME/.cache/ms-playwright}"
cachedChromium=""
if [ -d "$playwrightCacheDir" ]; then
  cachedChromium="$(
    find "$playwrightCacheDir" -type f \( -name chrome -o -name chromium \) \
      -print -quit 2>/dev/null || true
  )"
fi
if [ -n "$cachedChromium" ] && [ -x "$cachedChromium" ]; then
  cachedLaunchPng="${RUNNER_TEMP:-/tmp}/playwright-cache-check.png"
  cachedLaunchStatus=0
  timeout --kill-after=10s 20s "$cachedChromium" --headless --disable-gpu \
    --screenshot="$cachedLaunchPng" about:blank \
    >/dev/null 2>&1 || cachedLaunchStatus=$?
  rm -f "$cachedLaunchPng"
  if [ "$cachedLaunchStatus" -eq 0 ]; then
    echo "Playwright Chromium already launches from cache; skipping install."
    exit 0
  fi
  echo "Cached Playwright Chromium did not launch (exit ${cachedLaunchStatus}); installing."
fi

resetAptLists() {
  # Only useful (and only permitted) where the deps install actually runs apt.
  if ! command -v apt-get >/dev/null 2>&1; then
    return 0
  fi

  local sudo_prefix=""
  if [ "$(id -u)" -ne 0 ]; then
    if sudo -n true 2>/dev/null; then
      sudo_prefix="sudo"
    else
      return 0
    fi
  fi

  # Everything under lists/ is a cache apt rebuilds; `lock` and the `partial`
  # directory itself have to stay, and partial's truncated downloads are exactly
  # what a mid-sync mirror leaves behind.
  echo "Clearing apt package lists so the retry re-fetches them from scratch."
  $sudo_prefix find /var/lib/apt/lists -mindepth 1 -maxdepth 1 \
    ! -name lock ! -name partial -exec rm -rf {} + 2>/dev/null || true
  $sudo_prefix find /var/lib/apt/lists/partial -mindepth 1 -delete 2>/dev/null || true
}

runInstall() {
  local logFile="$1"
  shift
  local status=0

  : >"$logFile"
  set +e
  timeout --kill-after=30s "$ATTEMPT_TIMEOUT" bunx playwright install "$@" 2>&1 | tee "$logFile"
  local pipeStatuses=("${PIPESTATUS[@]}")
  set -e
  status="${pipeStatuses[0]}"
  if [ "$status" -eq 0 ] && [ "${pipeStatuses[1]}" -ne 0 ]; then
    status="${pipeStatuses[1]}"
  fi

  return "$status"
}

describeFailure() {
  local status="$1"
  local attempt="$2"

  if [ "$status" -eq 124 ] || [ "$status" -eq 137 ]; then
    echo "::warning::Playwright install attempt ${attempt} timed out after ${ATTEMPT_TIMEOUT}."
  else
    echo "::warning::Playwright install attempt ${attempt} failed with exit ${status}."
  fi
}

isRetryableInstallFailure() {
  local status="$1"
  local logFile="$2"

  # timeout(1) may kill the child before either apt or Playwright prints a
  # classifier marker. The timeout exit is sufficient evidence to retry.
  if [ "$status" -eq 124 ] || [ "$status" -eq 137 ]; then
    return 0
  fi

  if [ "$WITH_DEPS" = "true" ]; then
    # With dependencies, only retry when Playwright reports that its apt
    # subprocess exited 100 as well as a transient apt/mirror marker.
    isTransientPlaywrightAptFailure "$logFile"
  else
    # Without dependencies there is no apt subprocess. Retry recognized CDN
    # transport failures, but reject browser-name and configuration errors.
    isTransientBrowserDownloadFailure "$logFile"
  fi
}

installArgs=()
if [ "$WITH_DEPS" = "true" ]; then
  installArgs+=("--with-deps")
else
  # No apt. The 90s hung-apt bound (AEG-8528) is the wrong ceiling for a
  # Chromium tarball from cdn.playwright.dev (AEG-10216).
  ATTEMPT_TIMEOUT="$BROWSER_DOWNLOAD_TIMEOUT"
fi
installArgs+=("${BROWSER_ARGS[@]}")

status=0
delay=10
attemptLog="$(mktemp "${RUNNER_TEMP:-/tmp}/playwright-install.XXXXXX.log")"
trap 'rm -f "$attemptLog"' EXIT

for attempt in $(seq 1 "$ATTEMPTS"); do
  echo "Installing Playwright browsers: bunx playwright install ${installArgs[*]} (attempt ${attempt}/${ATTEMPTS})"

  status=0
  runInstall "$attemptLog" "${installArgs[@]}" || status=$?

  if [ "$status" -eq 0 ]; then
    echo "Playwright browsers installed on attempt ${attempt}."
    exit 0
  fi

  describeFailure "$status" "$attempt"

  if ! isRetryableInstallFailure "$status" "$attemptLog"; then
    if [ "$WITH_DEPS" = "true" ]; then
      echo "::error::Playwright install failed without a recognized transient apt/mirror exit-100 error; not retrying or hiding a real browser, CDN, or configuration failure."
    else
      echo "::error::Playwright install failed without a recognized transient browser-download transport error; not retrying a real browser or configuration failure."
    fi
    exit "$status"
  fi

  if [ "$attempt" -eq "$ATTEMPTS" ]; then
    break
  fi

  if [ "$WITH_DEPS" = "true" ]; then
    resetAptLists
  fi

  echo "Waiting ${delay}s before retrying..."
  sleep "$delay"
  delay=$((delay * 2))
  if [ "$delay" -gt 60 ]; then
    delay=60
  fi
done

if [ "$WITH_DEPS" != "true" ] || [ "$DEPS_FALLBACK" != "true" ]; then
  echo "::error::Playwright install failed after ${ATTEMPTS} attempts (last exit ${status})."
  exit "$status"
fi

# Last resort: the browser binaries come from Playwright's CDN, not from apt, so
# they can still be installed when only the apt half is broken. The runner
# images already ship the Chromium system libraries, so this usually works - but
# "usually" is not good enough to hand to the test run silently, hence the
# launch check below.
depsInstallStatus="$status"
echo "::warning::Could not install Playwright system dependencies via apt after ${ATTEMPTS} attempts; retrying without --with-deps and verifying the browser still launches."

# The --with-deps loop used the 90s hung-apt bound. The CDN download of
# Chromium is a different job and regularly needs more than 90s (AEG-10216
# jobs 104575530680 / 104575748221, exit 124).
ATTEMPT_TIMEOUT="$BROWSER_DOWNLOAD_TIMEOUT"
echo "Downloading Playwright browsers without --with-deps (timeout ${ATTEMPT_TIMEOUT})."

status=0
runInstall "$attemptLog" "${BROWSER_ARGS[@]}" || status=$?

if [ "$status" -ne 0 ]; then
  echo "::error::Playwright browser download failed as well (exit ${status}); this is not just an apt mirror problem."
  exit "$status"
fi

# Only Chromium is exercised here: it is the browser every lane in this repo
# runs, and it is the one whose missing libraries (libnspr4 / libnss3 /
# libasound2 ...) the deps install would have provided.
case " ${BROWSERS} " in
  *" chromium "*) ;;
  *)
    echo "::error::Cannot verify the dependency-free fallback because Chromium was not requested (${BROWSERS}); preserving the apt install failure."
    exit "$depsInstallStatus"
    ;;
esac

echo "Verifying Chromium launches with the system libraries already on this runner..."
launchStatus=0
timeout --kill-after=30s 3m bunx playwright screenshot \
  --browser=chromium about:blank "${RUNNER_TEMP:-/tmp}/playwright-deps-check.png" \
  >/dev/null 2>&1 || launchStatus=$?

if [ "$launchStatus" -ne 0 ]; then
  echo "::error::Chromium could not launch (exit ${launchStatus}) and its system dependencies could not be installed because the Ubuntu mirror kept failing. Re-run the job once the mirror finishes syncing."
  exit 1
fi

echo "Chromium launched successfully; continuing without the apt dependency install."
