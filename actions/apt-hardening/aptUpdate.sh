#!/usr/bin/env bash
# Run apt-get update, retrying past a mirror that is mid-sync.
#
# hardenApt.sh removes the indexes that fail most often and turns on apt's own
# per-file retries. What it cannot fix is a mirror that is inconsistent for the
# whole length of one apt-get update: apt caches the partially-fetched lists,
# and every subsequent run keeps validating them against the new Release file
# and keeps failing. Clearing /var/lib/apt/lists between attempts is what makes
# the retry a genuinely fresh fetch rather than a replay of the same mismatch.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=classifyAptFailure.sh
source "$SCRIPT_DIR/classifyAptFailure.sh"

ATTEMPTS="${APT_UPDATE_ATTEMPTS:-4}"
ATTEMPT_TIMEOUT="${APT_UPDATE_ATTEMPT_TIMEOUT:-5m}"

if ! [[ "$ATTEMPTS" =~ ^[0-9]+$ ]] || [ "$ATTEMPTS" -lt 1 ]; then
  ATTEMPTS=4
fi

if ! command -v apt-get >/dev/null 2>&1; then
  echo "::notice::apt-get is not available on this runner; skipping apt-get update."
  exit 0
fi

SUDO=""
if [ "$(id -u)" -ne 0 ]; then
  if sudo -n true 2>/dev/null; then
    SUDO="sudo"
  else
    echo "::notice::No root and no passwordless sudo; skipping apt-get update."
    exit 0
  fi
fi

status=0
delay=10
attemptLog="$(mktemp "${RUNNER_TEMP:-/tmp}/apt-update.XXXXXX.log")"
trap 'rm -f "$attemptLog"' EXIT

for attempt in $(seq 1 "$ATTEMPTS"); do
  echo "apt-get update attempt ${attempt}/${ATTEMPTS} (timeout ${ATTEMPT_TIMEOUT})"

  : >"$attemptLog"
  set +e
  timeout --kill-after=30s "$ATTEMPT_TIMEOUT" $SUDO apt-get update 2>&1 | tee "$attemptLog"
  pipeStatuses=("${PIPESTATUS[@]}")
  set -e
  status="${pipeStatuses[0]}"
  if [ "$status" -eq 0 ] && [ "${pipeStatuses[1]}" -ne 0 ]; then
    status="${pipeStatuses[1]}"
  fi

  if [ "$status" -eq 0 ]; then
    echo "apt-get update succeeded on attempt ${attempt}."
    exit 0
  fi

  if [ "$status" -eq 124 ] || [ "$status" -eq 137 ]; then
    echo "::warning::apt-get update timed out after ${ATTEMPT_TIMEOUT} on attempt ${attempt}."
  else
    echo "::warning::apt-get update failed with exit ${status} on attempt ${attempt}."
  fi

  # timeout(1) returning 124 (or 137 after its kill-after grace period) is
  # itself proof of a transient hang. The command may be killed before apt has
  # a chance to print one of the transport markers in the captured log.
  if [ "$status" -ne 124 ] && [ "$status" -ne 137 ] &&
    ! isTransientAptFailure "$attemptLog"; then
    echo "::error::apt-get update failed without a recognized transient apt or mirror error; not retrying a real package or configuration failure."
    exit "$status"
  fi

  if [ "$attempt" -eq "$ATTEMPTS" ]; then
    break
  fi

  # Drop the half-synced indexes so the next attempt re-fetches Release and
  # every index from scratch. Everything under lists/ is a cache apt rebuilds;
  # only `lock` and the `partial` directory itself are kept (apt expects them to
  # exist), and partial's contents - the truncated downloads - are what most
  # needs to go.
  $SUDO find /var/lib/apt/lists -mindepth 1 -maxdepth 1 \
    ! -name lock ! -name partial -exec rm -rf {} + 2>/dev/null || true
  $SUDO find /var/lib/apt/lists/partial -mindepth 1 -delete 2>/dev/null || true

  echo "Waiting ${delay}s for the mirror to finish syncing before retrying..."
  sleep "$delay"
  delay=$((delay * 2))
  if [ "$delay" -gt 60 ]; then
    delay=60
  fi
done

echo "::error::apt-get update failed after ${ATTEMPTS} attempts with a retryable timeout or recognized transient apt/mirror error (last exit ${status}). Re-running the job normally clears it."
exit "$status"
