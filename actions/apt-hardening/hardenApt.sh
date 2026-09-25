#!/usr/bin/env bash
# Configure apt so a mid-sync Ubuntu mirror cannot fail the job.
#
# Ubuntu's archive/security mirrors publish a new Release file before every
# per-component index behind it has finished replicating. Any apt-get update
# that lands in that window fails hard:
#
#   Err:37 http://security.ubuntu.com/ubuntu noble-security/main amd64 Components
#     File has unexpected size (46348 != 46400). Mirror sync in progress?
#   E: Some index files failed to download.
#
# apt exits 100, and everything downstream (playwright install --with-deps,
# postgresql-client, ...) dies with it. Two settings remove most of that
# exposure; aptUpdate.sh adds retries for what is left.
set -euo pipefail

CONF_PATH=/etc/apt/apt.conf.d/99-ci-mirror-resilience

if ! command -v apt-get >/dev/null 2>&1; then
  echo "::notice::apt-get is not available on this runner; skipping apt hardening."
  exit 0
fi

# Runners that give the job root (containers) need no sudo; hosted runners have
# passwordless sudo. The self-hosted AWS pod has neither and bakes its system
# libraries into the image (AEG-3744), so there this is a no-op rather than a
# failure.
SUDO=""
if [ "$(id -u)" -ne 0 ]; then
  if sudo -n true 2>/dev/null; then
    SUDO="sudo"
  else
    echo "::notice::No root and no passwordless sudo; skipping apt hardening."
    exit 0
  fi
fi

$SUDO tee "$CONF_PATH" >/dev/null <<'APT_CONF'
// Written by AEGIS-Security-Investigations/e2e-pipeline actions/apt-hardening. Do not edit on the runner.

// Retry a failed index fetch inside apt itself before the process exits 100.
// Covers the common case where a mirror finishes syncing seconds later, and
// applies to every apt-get in the job - including the one Playwright shells
// out to from `playwright install --with-deps`, which we do not control.
Acquire::Retries "5";

// A stalled mirror connection should fail fast into the retry above instead of
// hanging until the step's timeout.
Acquire::http::Timeout "30";
Acquire::https::Timeout "30";
Acquire::ftp::Timeout "30";

// AppStream (dep11) metadata and Contents indexes exist to power GUI software
// centres and command-not-found. Nothing in CI reads them, they are among the
// largest files apt fetches, and - as in the failure above - they are usually
// the ones caught mid-sync. Skipping them removes the biggest single source of
// mirror-sync failures and makes apt-get update noticeably faster.
Acquire::IndexTargets::deb::DEP-11::DefaultEnabled "false";
Acquire::IndexTargets::deb::DEP-11-icons::DefaultEnabled "false";
Acquire::IndexTargets::deb::DEP-11-icons-small::DefaultEnabled "false";
Acquire::IndexTargets::deb::DEP-11-icons-hidpi::DefaultEnabled "false";
Acquire::IndexTargets::deb::DEP-11-icons-large::DefaultEnabled "false";
Acquire::IndexTargets::deb::DEP-11-icons-large-hidpi::DefaultEnabled "false";
Acquire::IndexTargets::deb::Contents-deb::DefaultEnabled "false";
Acquire::IndexTargets::deb::Contents-deb-legacy::DefaultEnabled "false";

// Translation-* indexes are localized package descriptions; CI reads package
// names, not prose. Same rationale as above.
Acquire::Languages "none";
APT_CONF

echo "Wrote $CONF_PATH"
sed -e 's/^/  /' "$CONF_PATH"
