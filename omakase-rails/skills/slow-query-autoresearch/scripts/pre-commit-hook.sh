#!/bin/sh
# pre-commit hook — autoresearch
#
# Installed by SKILL.md Step 1.5 to .git/hooks/pre-commit (or
# core.hooksPath/pre-commit). Removed and original restored on
# session termination.
#
# No-op outside autoresearch/* branches — does not disrupt regular work.
# On autoresearch branches, enforces three hard rules at commit time.
# Never bypass with --no-verify; that defeats the mechanical guard.
#
# Scope: this hook protects only the things that, if mis-applied, silently
# corrupt the loop before PR review can catch them — output contract,
# revertibility, metric integrity. Other out-of-scope changes (Gemfile,
# config/, app/jobs/, etc.) rely on agent self-enforcement and PR review
# at squash/cherry-pick time. See SKILL.md "Out-of-scope" for the full table.

set -e

# No-op if not on an autoresearch branch.
branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
case "$branch" in
  autoresearch/*) ;;
  *) exit 0 ;;
esac

# (1) Fixture lock — frozen after THIS target's iter-0 baseline.
# The target name is derived from the branch suffix so an inherited iter-0
# from another autoresearch branch does not falsely lock this session.
target=${branch#autoresearch/}
if git log --grep="^iter 0 baseline: ${target} " --oneline 2>/dev/null | grep -q .; then
  if git diff --cached --name-only | grep -q '^auto/.*\.fixture\.rb$'; then
    echo "fixture locked after iter-0 baseline (target: ${target})" >&2
    echo "to start a new experiment with a different contract:" >&2
    echo "  git checkout main && git checkout -b autoresearch/${target}-v2" >&2
    exit 1
  fi
fi

# (2) Migration scope — index-only.
# Allowlist: comments, class/def/end, add_index, remove_index,
# disable_ddl_transaction!, blank lines, and common index-option kwargs
# on continuation lines (algorithm:, name:, where:, using:, unique:,
# if_not_exists:). Anything else (column ops, data migration, raw SQL)
# is rejected.
for f in $(git diff --cached --name-only | grep '^db/migrate/' || true); do
  [ -f "$f" ] || continue
  disallowed=$(grep -vE '^[[:space:]]*(#|class |def |end$|add_index|remove_index|algorithm:|name:|where:|using:|unique:|if_not_exists:|disable_ddl_transaction!|$)' "$f" || true)
  if [ -n "$disallowed" ]; then
    echo "migration outside index-only scope: $f" >&2
    echo "(only add_index / remove_index allowed; see SKILL.md)" >&2
    echo "disallowed lines:" >&2
    echo "$disallowed" >&2
    exit 1
  fi
done

# (3) Forbidden content — no new cache / queue infrastructure introduction.
# This one is mechanical because Rails.cache.fetch in particular fakes the
# metric: bench clears the Active Record query cache between runs but does not clear
# Rails.cache, so a cache-fetch candidate would show a 99% improvement
# that is just measuring cache lookup, not the underlying query. Catching
# this at commit time is much cheaper than catching it after the loop has
# rejected legitimate candidates as "worse" than the false-positive winner.
new_lines=$(git diff --cached -- 'app/' 'lib/' | grep '^+' | grep -v '^+++' || true)
if echo "$new_lines" | grep -qE '(Rails\.cache\.(fetch|write|read)|Redis\.new|MemCacheStore\.|Sidekiq\.set_schedule|ActiveJob::Base\.set\()'; then
  echo "out of scope (content): introducing cache/queue infrastructure" >&2
  exit 1
fi

exit 0
