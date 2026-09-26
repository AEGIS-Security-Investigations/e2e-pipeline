#!/usr/bin/env bash
# Git checkout for checkout-with-retry (moved from myGuardForce, AEG-3671).
#
# Sparse checkout: when SPARSE_CHECKOUT (an explicit newline/space separated
# path list) is provided, the working tree is limited to those paths and the
# fetch uses a partial clone (--filter=blob:none) so blobs OUTSIDE the sparse
# set are never downloaded. This is what actually shrinks the transfer — plain
# sparse-checkout only limits what is written to disk, not what is fetched.
# Named path presets are the caller's business: keep them in the calling repo
# and pass the resolved list in `sparse-checkout`.

set -euo pipefail

ref="${INPUT_REF:-}"
if [ -z "${ref// }" ]; then
  ref="${GITHUB_REF:?GITHUB_REF is required when INPUT_REF is empty}"
fi

fetch_depth="${INPUT_FETCH_DEPTH:-1}"
token="${INPUT_TOKEN:?INPUT_TOKEN is required}"
repository="${REPOSITORY:?REPOSITORY is required}"
workspace="${WORKSPACE:?WORKSPACE is required}"

sparse_explicit="${SPARSE_CHECKOUT:-}"
sparse_cone_mode="${SPARSE_CHECKOUT_CONE_MODE:-true}"

# Collect resolved paths into an array. Blank and whole-line `#` comments are
# skipped (gitignore-style); remaining lines are word-split so callers can pass
# a readable multiline list or space-separated dirs.
sparse_paths=()
while IFS= read -r line; do
  trimmed="${line#"${line%%[![:space:]]*}"}"
  case "$trimmed" in
    ""|"#"*) continue ;;
  esac
  for path in $line; do
    [ -n "$path" ] && sparse_paths+=("$path")
  done
done <<<"${sparse_explicit}"

cd "$workspace"

# AEG-7090: every attempt starts from a pristine git dir, never from the one the
# two-stage bootstrap left behind. That bootstrap (`actions/checkout@v5` with
# `sparse-checkout: .github` and `persist-credentials: false`) leaves a depth-1
# partial clone whose credentials have been stripped — so its promisor can no
# longer backfill blobs — plus a cone-mode sparse index for a different sha.
# Re-pointing that index at this job's sparse set makes git rewrite the working
# tree from objects it cannot fetch: "error: unable to read sha1 file of ..." and
# then, on git >= 2.52, `BUG: unpack-trees.c:494: both update and delete flags
# are set` — a SIGABRT (exit 134) that deletes the tree it was rewriting,
# including this action's own source, so the retry steps below find no script to
# run. Discarding the bootstrap object store costs nothing: this attempt fetches
# everything it needs anyway.
rm -rf .git

git config --global --add safe.directory "$workspace" 2>/dev/null || true

git init
git config --local gc.auto 0 2>/dev/null || true

git remote remove origin 2>/dev/null || true
git remote add origin "https://x-access-token:${token}@github.com/${repository}.git"

fetch_args=(--prune --no-recurse-submodules)
if [ "${fetch_depth}" = "0" ] || [ -z "${fetch_depth// }" ]; then
  :
else
  fetch_args+=(--no-tags)
  if ! [[ "${fetch_depth}" =~ ^[0-9]+$ ]]; then
    echo "fetch-depth='${fetch_depth}' must be a non-negative integer" >&2
    exit 1
  fi
  fetch_args+=("--depth=${fetch_depth}")
fi

# When a sparse set is requested, configure sparse-checkout BEFORE fetching and
# switch the fetch to a partial clone so only the blobs under the sparse paths
# are transferred (git backfills any others on demand). Without --filter the
# fetch would still download every blob, including the docs/ assets we are
# trying to avoid.
#
# The index is empty at this point (see the fresh `git init` above), so setting
# the sparse patterns only records them — it never rewrites the working tree,
# which is what made this crash on the bootstrap's populated index.
if [ "${#sparse_paths[@]}" -gt 0 ]; then
  git config core.sparseCheckout true
  if [ "${sparse_cone_mode}" = "true" ]; then
    git sparse-checkout init --cone
    git sparse-checkout set "${sparse_paths[@]}"
  else
    git sparse-checkout set --no-cone "${sparse_paths[@]}"
  fi
  fetch_args+=(--filter=blob:none)
fi

# Ordered fetch candidates for the requested ref (AEG-5509). A pull_request run
# checks out refs/pull/<n>/merge, which GitHub computes asynchronously and stops
# publishing while a PR is conflicted — so it can be missing when the job starts.
# `git fetch` on a missing ref exits 128 and, under `set -euo pipefail`, hard-
# fails the step.
#
# The merge ref is therefore WAITED FOR (MERGE_REF_ATTEMPTS polls, one every
# MERGE_REF_RETRY_DELAY seconds), which covers the async-computation window that
# the action's whole-checkout retry alone would race.
#
# It is deliberately NOT downgraded to refs/pull/<n>/head by default: this
# checkout feeds merge-gating workflows, and building the PR head means building
# a tree the base branch was never merged into. Publishing a green required check
# for that tree is worse than failing, so a still-missing merge ref fails loudly
# with a conflict-resolution hint. Jobs that report no merge-gating status (the
# notifiers, labelers, and cleanup workflows) can opt in with
# ALLOW_HEAD_REF_FALLBACK=true and get the head ref plus a warning. Every other
# ref has no fallback at all.
allow_head_ref_fallback="${ALLOW_HEAD_REF_FALLBACK:-false}"
merge_ref_attempts="${MERGE_REF_ATTEMPTS:-4}"
merge_ref_retry_delay="${MERGE_REF_RETRY_DELAY:-5}"

pull_number=""
if [[ "${ref}" =~ ^refs/pull/([0-9]+)/merge$ ]]; then
  pull_number="${BASH_REMATCH[1]}"
fi

ref_candidates=("${ref}")
if [ -n "${pull_number}" ] && [ "${allow_head_ref_fallback}" = "true" ]; then
  ref_candidates+=("refs/pull/${pull_number}/head")
  head_ref="${GITHUB_HEAD_REF:-}"
  if [ -n "${head_ref// }" ]; then
    ref_candidates+=("refs/heads/${head_ref}")
  fi
fi

# Fetch one candidate, polling while the remote reports it as missing. Only the
# merge ref gets more than one attempt — it is the only candidate GitHub
# publishes asynchronously; a missing head/branch ref is a settled fact. Leaves
# the last git stderr in `fetch_stderr` for the caller to classify.
#
# AEG-6446: transient transport / rate-limit failures (429, 5xx, RPC, TLS,
# connection reset) retry inside a single checkout attempt so a brief
# git/codeload blip does not burn the whole 3m step timeout. Missing-ref and
# auth failures are not retried here.
fetch_stderr=""
is_transient_git_fetch_error() {
  local err="$1"
  case "${err}" in
    *"couldn't find remote ref"*|*"Could not find remote branch"*|*"Authentication failed"*|*"could not read Username"*|*"invalid username or password"*|*"Permission denied"*|*"Repository not found"*)
      return 1
      ;;
  esac
  return 0
}

fetch_transport_attempts="${GIT_FETCH_TRANSPORT_ATTEMPTS:-3}"

fetch_ref_candidate() {
  local candidate="$1"
  local attempts="$2"
  local attempt=1
  local transport_attempt=1
  local transport_delay=3

  while :; do
    if fetch_stderr="$(git fetch origin "${fetch_args[@]}" "${candidate}" 2>&1 >/dev/null)"; then
      return 0
    fi

    if is_transient_git_fetch_error "${fetch_stderr}" && [ "${transport_attempt}" -lt "${fetch_transport_attempts}" ]; then
      echo "Transient git fetch failure for ${candidate} (transport attempt ${transport_attempt}/${fetch_transport_attempts}); waiting ${transport_delay}s." >&2
      printf '%s\n' "${fetch_stderr}" >&2
      sleep "${transport_delay}"
      transport_attempt=$((transport_attempt + 1))
      if [ "${transport_delay}" -lt 12 ]; then
        transport_delay=$((transport_delay + 5))
      fi
      continue
    fi

    # Anything other than a missing ref (transport, auth, server) is the retry
    # step's job, not this loop's — return and let the caller fail loudly.
    if [[ "${fetch_stderr}" != *"couldn't find remote ref"* ]]; then
      return 1
    fi

    if [ "${attempt}" -ge "${attempts}" ]; then
      return 1
    fi

    echo "Remote ref ${candidate} is not published yet (attempt ${attempt}/${attempts}); waiting ${merge_ref_retry_delay}s for GitHub to compute it." >&2
    sleep "${merge_ref_retry_delay}"
    attempt=$((attempt + 1))
  done
}

effective_ref=""
for candidate in "${ref_candidates[@]}"; do
  attempts=1
  if [ -n "${pull_number}" ] && [ "${candidate}" = "${ref}" ]; then
    attempts="${merge_ref_attempts}"
  fi

  if fetch_ref_candidate "${candidate}" "${attempts}"; then
    if [ -n "${fetch_stderr}" ]; then
      printf '%s\n' "${fetch_stderr}" >&2
    fi
    effective_ref="${candidate}"
    if [ "${candidate}" != "${ref}" ]; then
      echo "::warning::Ref ${ref} does not exist on the remote; checked out ${candidate} instead. This builds the PR head WITHOUT merging the base branch, so the result does not reflect the merge commit and must not be read as a merge-gating status."
    fi
    break
  fi

  printf '%s\n' "${fetch_stderr}" >&2

  # Move on ONLY when the ref genuinely does not exist. A transient transport,
  # auth, or server failure must never silently change which tree we build: for
  # anything other than a missing ref, fail now and let the action's retry step
  # re-attempt the requested ref from scratch.
  if [[ "${fetch_stderr}" != *"couldn't find remote ref"* ]]; then
    echo "::error::Fetching ${candidate} failed for a reason other than a missing remote ref (see above); not falling back to a different ref." >&2
    exit 1
  fi

  echo "Remote ref ${candidate} does not exist; trying the next candidate." >&2
done

if [ -z "${effective_ref}" ]; then
  if [ -n "${pull_number}" ] && [ "${allow_head_ref_fallback}" != "true" ]; then
    echo "::error::${ref} is still not published after ${merge_ref_attempts} attempts. GitHub computes the merge ref asynchronously and stops publishing it while a PR has conflicts, so resolve the conflict (or re-run once the merge ref exists). Refusing to check out refs/pull/${pull_number}/head instead: a required check that passes on the PR head would report green for a tree this base branch was never merged into. Non-merge-gating jobs can set allow-head-ref-fallback: true." >&2
  else
    echo "::error::None of the candidate refs could be fetched: ${ref_candidates[*]}" >&2
  fi
  exit 1
fi

# Pin what the requested ref resolved to before any further fetch rewrites
# FETCH_HEAD.
target_sha="$(git rev-parse FETCH_HEAD)"

# Full-history parity with actions/checkout (fetch-depth: 0): it also fetches
# every branch into refs/remotes/origin/* and every tag, and callers lean on
# that (diffs against origin/$GITHUB_BASE_REF, `git tag --list` in release
# scripts). Shallow checkouts keep fetching only the requested ref.
if [ "${fetch_depth}" = "0" ] || [ -z "${fetch_depth// }" ]; then
  all_refs_args=(--prune --no-recurse-submodules --tags)
  if [ "${#sparse_paths[@]}" -gt 0 ]; then
    all_refs_args+=(--filter=blob:none)
  fi
  all_refs_attempt=1
  until fetch_stderr="$(git fetch origin "${all_refs_args[@]}" "+refs/heads/*:refs/remotes/origin/*" 2>&1 >/dev/null)"; do
    printf '%s\n' "${fetch_stderr}" >&2
    if [ "${all_refs_attempt}" -ge "${fetch_transport_attempts}" ] || ! is_transient_git_fetch_error "${fetch_stderr}"; then
      echo "::error::Fetching all branches and tags for fetch-depth 0 failed (see above)." >&2
      exit 1
    fi
    echo "Transient failure fetching all branches and tags (attempt ${all_refs_attempt}/${fetch_transport_attempts}); retrying in 5s." >&2
    sleep 5
    all_refs_attempt=$((all_refs_attempt + 1))
  done
fi

branch_name=""
if [[ "${effective_ref}" == refs/heads/* ]]; then
  branch_name="${effective_ref#refs/heads/}"
elif [[ "${effective_ref}" != refs/pull/* ]] && [[ "${effective_ref}" != refs/tags/* ]] && ! [[ "${effective_ref}" =~ ^[0-9a-fA-F]{40}$ ]]; then
  branch_name="${effective_ref}"
fi

# --force in both branches: the bootstrap checkout leaves files from a different
# sha in the workspace, and git refuses to overwrite them ("The following
# untracked working tree files would be overwritten by checkout ... Aborting")
# unless told to. Files outside the sparse set are left where they are, which is
# what keeps this action's own source readable for the retry steps.
if [ -n "${branch_name}" ]; then
  git checkout --force -B "${branch_name}" "${target_sha}"
else
  git checkout --force "${target_sha}"
fi

git config --local --unset-all "http.https://github.com/.extraheader" 2>/dev/null || true
