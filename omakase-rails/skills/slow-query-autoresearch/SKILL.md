---
name: slow-query-autoresearch
description: Autonomous loop searching for faster ActiveRecord queries with identical output — fingerprint + timing-past-noise + tests gate each iter mechanically. Scope: query rewrites + index-only migrations only (no cache, gems, config, data migrations). Silent when not a Rails app, DB unreachable, no tests, or the slow path can't be narrowed to a deterministic callable. Make sure to use whenever the user mentions a slow query/scope/job, EXPLAIN output, N+1 patterns, or asks to "make this faster", "optimize this query", "speed up this page" — even when only describing slowness rather than asking for a fix.
---

## Philosophy

Slow-query work drifts toward guessing. The skill forces it on rails by separating *what is being optimized* (output contract — locked at iter-0) from *how it gets done* (implementation — freely searched). The harness, not the agent, decides which implementation wins. The branch is the record.

## The atom

```
propose (agent: read EXPLAIN, write candidate lambda)
   ↓
apply   (agent: edit app/, optionally db/migrate/ for index)
   ↓
measure (harness: bench, N=100 runs per candidate, METRIC line)
   ↓
gate    (rule: A fingerprint match, B median beats noise + ≥5%, C tests pass)
   ↓                                            ↓
KEEP                                          REVERT
(commit code+migration+bench)              (rollback if mig → reset --hard → empty commit)
   ↓                                            ↓
   └──────── check terminator (T1/T2/T3) ──────┘
```

Roles: agent **proposes** and **applies**, harness **measures**, rule **decides**, git **stores**. Agent has no override authority on gates. Three things in particular are hardened against agent judgment — output contract (fixture lock), revertibility (migration scope), and metric integrity (no cache layer that fakes timing) — because mis-judging any of them silently corrupts the loop before PR review can catch it. Other judgment (which direction to try, how to read EXPLAIN, when to give up, gate arithmetic) is the agent's job, with PR review at squash/cherry-pick as the second line of defense.

## Out-of-scope

Four classes of change are out of scope. Two are mechanically rejected by `scripts/pre-commit-hook.sh` because mis-applying them silently corrupts measurements or breaks the revert path before review catches it. The other two are out of scope by convention — agent self-enforces from this table; PR review at squash/cherry-pick catches the rare miss.

| Class | Examples | Why out | Enforced by |
|---|---|---|---|
| Cache / queue infrastructure | `Rails.cache.fetch`, `Redis.new`, `MemCacheStore`, `Sidekiq.set_schedule`, `ActiveJob::Base.set` | Avoids running the query rather than improving it. Also makes median deceptive: bench clears Active Record query cache between runs, not `Rails.cache`, so a cache-fetch candidate measures cache lookup, not the query. | Hook (content scan) |
| Data migration | Anything in `db/migrate/` other than `add_index` / `remove_index` | Reversibility weakens; loop's revert path can't undo data changes. | Hook (migration scope) |
| Application config | `Gemfile`, `Gemfile.lock`, `config/`, `app/initializers/`, `.env*` | Infrastructure tuning, not query change. Loud in diff — agent unlikely to reach for it; review catches it. | Convention + PR review |
| Non-query components | New files in `app/jobs/`, `lib/tasks/`, `db/seeds*` | Code organization, not query change. | Convention + PR review |

Common manual recipes (delivered at T2 plateau if EXPLAIN points there): counter_cache, materialized view, partitioning, denormalization, caching layer, read replica routing.

## Example walkthrough

User: *"DashboardController#show takes 1.2s, ActiveRecord 400ms"*.

1. **Narrow lambda.** Agent extracts `current_user.posts.recent.limit(50)` followed by `.map { |p| [p.id, p.title, p.comments.count] }` (the view's effective traversal). Inputs pinned: `INPUTS = { user_id: 42, page_size: 50 }`. Output contract: array of `[id, title, count]` triples — strict default fingerprint.
2. **iter 0 baseline.** median 1247ms, p99 1380ms, queries=51 (1 + 50 N+1). Commit with `Fixture-SHA`, `Median-Us: 1247000`, full pre-flight body.
3. **iter 1 propose.** EXPLAIN: 50 repeated `SELECT COUNT(*) FROM comments WHERE post_id = $1`. → eager loading direction. Candidate uses `.includes(:comments)` + `.size` (Ruby-side count off the preloaded association). Bench: median 23ms, p99 28ms, queries=2. Gates A ✓ B ✓ (-98%) C ✓ → KEEP.
4. **iter 2 propose.** Now db_us 18ms ≈ median 23ms — Ruby-bound on Active Record object hydration. Try `.left_joins(:comments).group('posts.id').select('posts.id, posts.title, COUNT(comments.id) AS c')` followed by `.map { |r| [r.id, r.title, r.c.to_i] }` — composite single SQL with the same triple projection that the baseline lambda already produces. Each candidate keeps the consumer-side projection unchanged; only the SQL underneath moves. That's what keeps Gate A (fingerprint) green across SQL-shape changes. Bench: median 11ms, p99 14ms. Gate A ✓ B ✓ (-52%) C ✓ → KEEP.
5. **iter 3-5.** Try multi-column index, partial index variants, `find_by_sql`. All revert (gate B: improvements within noise after iter 2). T2 plateau fires.
6. **Handoff.** Termination report shows last-3-reverts on gate B. Cherry-pick iter 1, iter 2 to main. Out-of-scope hint: counter_cache for further reduction (separate PR; column add + backfill is data migration, not in autoresearch scope).

## Step 1 — Setup

Confirm at session start (one line, then proceed): *"About to start an autoresearch loop on `<target>`. Creates scratch branch, installs pre-commit hook, runs ~30s baseline, iterates until terminator. Migrations are index-only, mechanically enforced. Proceed?"*

### 1.0 Verify preconditions

Mechanical checks; if any fails, abort silently:

```bash
grep -qE "^\s*gem\s+['\"]rails['\"]" Gemfile && [ -f config/application.rb ]
bin/rails runner 'ActiveRecord::Base.connection.adapter_name' >/dev/null
find spec/ test/ -type f \( -name '*_spec.rb' -o -name '*_test.rb' \) 2>/dev/null | head -1 | grep -q .
```

The fourth precondition — single deterministic call site — is established in 1.1.

### 1.1 Identify call site

From user trigger. If ambiguous, ask once: *"Narrow the slow path to a single deterministic callable — e.g. `Order.where(status:'pending').recent.limit(100).to_a`."* Pin all run-to-run varying inputs (user_id, dates, random seeds).

### 1.2 Detect environment, surface as facts

```bash
bin/rails runner 'puts ActiveRecord::Base.connection.adapter_name; puts Rails.env'
# For each in-scope table: bin/rails runner "puts <Model>.count"
```

### 1.3 Test mapping

Try convention map (`app/models/foo.rb` → `test/models/foo_test.rb` or `spec/models/foo_spec.rb`). If miss, ask once: *"No spec for `<file>` — full suite each iter (default), or specific paths?"* Record answer in iter-0 body. Migration iters force full suite regardless.

### 1.4 Output contract

Default `FINGERPRINT` is strict — `SHA1(result.inspect)`. Override only if user surfaces relaxed semantics (consumer iterates as Set, Active Record vs Hash both fine, etc.). Override needs explicit user confirmation and is encoded once in `<target>.fixture.rb`. To change contract after iter-0: new scratch branch.

### 1.5 Scratch branch + hook install

```bash
git checkout -b autoresearch/<target>
mkdir -p auto

HOOKS_PATH=$(git config core.hooksPath || echo ".git/hooks")
mkdir -p "$HOOKS_PATH"
[ -f "$HOOKS_PATH/pre-commit" ] && mv "$HOOKS_PATH/pre-commit" "$HOOKS_PATH/pre-commit.autoresearch-backup"
cp <skill_dir>/scripts/pre-commit-hook.sh "$HOOKS_PATH/pre-commit"
chmod +x "$HOOKS_PATH/pre-commit"
```

The hook enforces three hard rules at commit time: fixture lock after iter-0, index-only migrations, no new cache/queue content in `app/` or `lib/` diffs. Out-of-scope changes it does *not* catch (Gemfile, `config/`, `app/jobs/`) rely on the Out-of-scope table plus PR review — the hook stays narrow so its false-positive surface stays small. Do not bypass with `--no-verify`: it's the only mechanical guard on contract/revertibility/metric integrity. If a check blocks a legitimate commit, fix the hook (or start a new branch if the contract was wrong) — don't skip.

### 1.6 Templates

```bash
cp <skill_dir>/assets/fixture_template.rb auto/<target>.fixture.rb
cp <skill_dir>/assets/bench_template.rb   auto/<target>.bench.rb
```

Edit `auto/<target>.fixture.rb`: fill `INPUTS` with pinned inputs, override `FINGERPRINT` only if confirmed in 1.4.

Edit `auto/<target>.bench.rb`: replace the `baseline:` lambda body with the production call using `INPUTS[:foo]` (no hardcoded values).

### 1.7 Baseline

```bash
bin/rails runner auto/<target>.bench.rb
```

Parse the METRIC line. Commit iter-0:

```
iter 0 baseline: <target> — median <N>ms, p99 <N>ms

Pre-flight:
- DB: <env> on <adapter>
  Tables in scope: <table> <rows>, ...
- Call site: <one-line lambda body>
- Output contract: <strict | custom (reason)>
- Tests: <convention | user-paths>
- Tests on migration iters: full suite

[required trailers — see "Trailer schema" below]
```

This commit's SHA is the anchor for all subsequent comparisons.

## Step 2 — Diagnose (once, before iter 1)

Run `EXPLAIN (ANALYZE, BUFFERS)` on the SQL the baseline lambda generates. Without this, the loop becomes guessing.

Capture the SQL first. For a single-relation baseline, `relation.to_sql` is enough:

```bash
bin/rails runner 'puts User.find(42).posts.recent.limit(50).to_sql'
```

For lambdas that fire multiple queries (N+1, traversals, Active Record-then-Ruby), subscribe to Active Record notifications and let the baseline run — then dedupe by frequency to find the dominating shape:

```bash
bin/rails runner '
  ActiveSupport::Notifications.subscribe("sql.active_record") do |_, _, _, _, p|
    next if p[:name] == "SCHEMA" || p[:cached]
    puts p[:sql]
  end
  # Inline the baseline lambda body here (same call as CANDIDATES[:baseline]):
  User.find(42).posts.recent.limit(50).each { |post| post.comments.count }
' | sort | uniq -c | sort -rn
```

Pick the highest-count or widest-row SQL, then in `bin/rails dbconsole`:

```sql
EXPLAIN (ANALYZE, BUFFERS) SELECT ...;
```

EXPLAIN reading hints (prior, not constraint — agent may propose anything not out-of-scope):

| Signal | Try |
|---|---|
| `queries: N+`, repeated identical shape | eager loading variants — `includes` / `preload` / `eager_load` / `joins+group+select` / subquery / Ruby-side merge |
| `median_us >> db_us`, wide row width | column projection — `select` / `pluck` |
| `Seq Scan ... Rows Removed > 100k`, sort spill, low selectivity | index — partial / functional / covering / multi-column |
| `Hash Aggregate`, many groups, per-group top-N | window function — `ROW_NUMBER` / `DISTINCT ON` / LATERAL |
| `median_us >> db_us` after column projection tried | hydration bypass — `find_by_sql` / `exec_query` (custom fingerprint required for Active Record-vs-Hash transition) |

## Steps 3-5 — Iterate

### Step 3: Propose
Pick the highest-leverage direction from EXPLAIN. **One hypothesis per iteration.** Bundling two changes hides which one moved the number and turns a revert into an unraveling.

### Step 4: Apply
Edit production code. Add candidate as a new entry in `CANDIDATES` with descriptive name (`candidate_2_partial_index_pending`, not `candidate_2_try`).

**Before any migration**, verify the active database is not production-shaped. Abort and surface the migration file to the user if `Rails.env.production?` is true, or if the DB name from `config/database.yml`'s active section contains `production` or `staging` (case-insensitive). The fixture inputs are pinned to dev data; migrations against a prod-shaped DB risk on data the dev seed never had — the reversibility guarantee no longer holds.

```bash
db_name=$(bin/rails runner 'puts ActiveRecord::Base.connection.current_database')
echo "$db_name" | grep -qiE '(production|staging)' && { echo "abort: prod-shaped DB"; exit 1; }
```

Then `PRE_VER=$(bin/rails db:version | awk '{print $NF}')`. `bin/rails g migration <Descriptive>`. Hook rejects non-index DDL at commit — agent learns mechanically. Run `bin/rails db:migrate`. If migration fails outright (nothing applied): `git checkout -- db/migrate/ db/schema.rb`, drop candidate, move on.

### Step 5: Bench, gate, commit

```bash
ANCHOR=$(git log --grep='^iter [0-9]\+ keep:' --format='%(trailers:key=Median-Us,valueonly=true)' -1)
ANCHOR=${ANCHOR:-$(git log --grep='^iter 0 baseline:' --format='%(trailers:key=Median-Us,valueonly=true)' -1)}
bin/rails runner auto/<target>.bench.rb
# Read $ANCHOR for Gate B comparison below.
```

Apply gates in order; short-circuit on first failure:

- **Gate A — fingerprint**: candidate's `fingerprint` == anchor's. Different bytes = different output. Non-negotiable.
- **Gate B — timing**: candidate's `median_us` is at least 5% lower than anchor's `median_us` (i.e. `candidate.median_us <= anchor.median_us * 0.95`). Anchor is the most recent KEEP, or iter-0 baseline if none — so each iter must beat the *current* best by ≥5%, not the original baseline. The N=100 medians absorb within-iter jitter; longer-term measurement drift surfaces at squash/cherry-pick time when a human re-runs the kept candidates.
- **Gate C — tests**: tests pass for the path 1.3 specified, OR full suite on migration iters.

Gates own the verdict. A candidate that passes A/B/C is kept, full stop — agent aesthetic ("this looks complex") has no override authority.

#### KEEP — one commit covering everything

Subject: `iter <N> keep: <move> — <prev>ms → <new>ms (-<pct>%)`

Body sections (free text):
- EXPLAIN signal that pointed here
- Implementation change summary
- `Next:` forward hint for next iter

Required trailers: see "Trailer schema" below.

The commit atomically bundles app code + bench candidate addition + migration (if any). One iteration, one commit.

#### REVERT — rollback if migration → reset → empty commit

Order matters:

```bash
if [ "$(bin/rails db:version | awk '{print $NF}')" != "$PRE_VER" ]; then
  bin/rails db:rollback STEP=1
fi
git reset --hard HEAD
git commit --allow-empty -m "iter <N> revert: <move> — gate <A|B|C>" -m "<body>"
```

Subject: `iter <N> revert: <move> — gate <A|B|C>`

Body sections: what failed and why, `Next:` where to look.

Required trailers: see "Trailer schema" below.

The PRE_VER check makes rollback mechanical — no risk of reverting the previous iter's migration if agent forgets which iter applied one. Empty-commit reverts keep the rejected experiment searchable without polluting code diff.

## Trailer schema

| Commit kind | Required trailers |
|---|---|
| iter-0 baseline | `Fixture-SHA`, `Median-Us`, `Min-Us`, `P95-Us`, `P99-Us`, `Max-Us`, `Db-Us`, `Queries`, `Fingerprint`. Optional: `Target-Us` (T3), `Fingerprint-Mode: custom` (1.4 override) |
| KEEP | `Move`, `Median-Us`, `Min-Us`, `P95-Us`, `P99-Us`, `Max-Us`, `Delta-Pct`, `P99-Delta-Pct`, `Tests-Run`, `Db-Us`, `Queries`, `Fingerprint` |
| REVERT | `Move`, `Gate-Failed`, `Median-Us`, `Fingerprint`, `Fingerprint-Match` |

Median is the gated metric; `P99-Us`, `Min-Us`, `P95-Us`, `Max-Us` are informational (squash-time inspection). Squash-merge candidate inspection:

```bash
git log --grep='^iter [0-9]\+ keep:' --format='%(trailers:key=P99-Delta-Pct,valueonly=true)'
```

## Step 6 — Terminate

Default is continue. Stop only when one of:

- **T1 — User stopped.** Said stop, redirected, or declared done.
- **T2 — Plateau.** Last 3 iter commits' subjects all start with `iter <N> revert:`:
  ```bash
  test "$(git log --format=%s --grep='^iter [0-9]\+ ' | head -3 | grep -c '^iter [0-9]\+ revert:')" -eq 3
  ```
- **T3 — Target.** `Target-Us` trailer exists in iter-0 AND latest KEEP's `Median-Us` ≤ `Target-Us`.

"Big win" is never a terminator. -98% just sets a new comparison point — the remaining budget may still hide another 2x. The urge to stop after a satisfying result is a bias, not a signal.

Do not ask the user between iterations on code-only candidates. Pause for the first migration of the session and when a terminator fires.

### Plateau classification (T2 only)

```bash
git log --grep='^iter [0-9]\+ revert:' --format='%(trailers:key=Gate-Failed,valueonly=true)' | head -3
```

- All same: report "plateau on dimension `<X>` (gate `<Y>`)"
- Mixed: report "plateau (mixed gates)"

### Termination report

Report which terminator, best candidate, best median, total iters, total improvement vs baseline, and:

```
To consume autoresearch/<target>:

1. Cherry-pick KEEPs (recommended for narrow PR review):
   git checkout main
   git log --grep='^iter [0-9]\+ keep:' --reverse --format=%H autoresearch/<target> ^main \
     | xargs -I {} git cherry-pick {}

2. Squash merge (recommended for compact history):
   git checkout main && git merge --squash autoresearch/<target>
   git commit -m "perf(<target>): <X>ms → <Y>ms (-<pct>%)"

3. Discard (T2 with no KEEP, or unsatisfactory):
   git branch -D autoresearch/<target>
```

### Termination diagnostic — where the next round could aim

Append after the consumption block. The skill stays strict during the loop on purpose; this section names where remaining cost lives and what relaxing the contract could try, so a single big-win iter doesn't hide a comparable second-round opportunity. The skill never starts the follow-up automatically — relaxing the contract requires explicit user confirmation ("consumer reads exactly these attributes, nothing else"), and getting that wrong is silent production breakage that the relaxed fingerprint cannot catch.

**Cost decomposition.** Run `EXPLAIN ANALYZE` on the kept SQL once (5–10s, strongly recommended — without it the dimensions collapse to just `DB-side` vs `Ruby-side`, which usually can't disambiguate SQL shape from wire as the dominant attack):

| Dimension | Source | Primary attacks |
|---|---|---|
| Server execution | `EXPLAIN ANALYZE` Execution Time | SQL shape, indexes, partition pruning |
| Planning | `EXPLAIN ANALYZE` Planning Time | Prepared statements, simpler joins (rare to dominate) |
| Network + decode | `Db-Us` − (Execution + Planning) | Column projection, payload reduction |
| Ruby-side (mostly hydration) | `Median-Us` − `Db-Us` | Bypass Active Record (`find_by_sql`, `pluck`) |

Render as ms + % of total median; the dominant row points at the next round.

**Follow-up by dominant dimension:**

| Dominant | Follow-up branch | Fingerprint relaxation |
|---|---|---|
| Network + decode | `autoresearch/<target>-projected` | Project only the columns the consumer reads — `select(...)` drops the rest |
| Ruby-side | `autoresearch/<target>-unhydrated` | Hash only consumer-read attributes — allows `find_by_sql` / `exec_query` |
| Server execution (SQL/index exhausted) | — separate PR (out of scope) | Use manual recipes: counter_cache, materialized view, partitioning, denormalization, read replica routing |

Confirm consumer-read attributes with the user, then `git checkout -b autoresearch/<target>-<suffix>` from main and override `FINGERPRINT` in the new fixture to match the relaxation column.

### Hook teardown

After the consumption decision is made (cherry-pick, squash, or discard), remove the hook so the repository returns to its pre-session state. The hook is a no-op outside `autoresearch/*` branches so leaving it installed is not actively harmful, but a stale hook from a previous session can confuse a later one — especially if `core.hooksPath` was customized or a different skill version installs a different hook later.

```bash
HOOKS_PATH=$(git config core.hooksPath || echo ".git/hooks")
rm -f "$HOOKS_PATH/pre-commit"
[ -f "$HOOKS_PATH/pre-commit.autoresearch-backup" ] && \
  mv "$HOOKS_PATH/pre-commit.autoresearch-backup" "$HOOKS_PATH/pre-commit"
```

If T2 reverts pointed at any out-of-scope pattern (see "## Out-of-scope" above), surface as a manual recipe — separate PR if applicable. Autoresearch finds; it does not ship.

## Reference files

- `assets/fixture_template.rb` — `INPUTS` + `FINGERPRINT`. Locked after iter-0 baseline by hook + harness self-check.
- `assets/bench_template.rb` — `CANDIDATES` hash + measurement loop. Imports fixture. N=100 iters, 5 warmup, emits `METRIC` line per candidate.
- `scripts/pre-commit-hook.sh` — three hard checks: fixture lock, index-only migration, no new cache/queue content. Other out-of-scope categories (Gemfile, config/, app/jobs/) are not hook-enforced — see the Out-of-scope table.
