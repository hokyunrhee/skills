# frozen_string_literal: true
#
# auto/<target>.bench.rb — candidate lambdas + measurement harness.
#
# Edit per iter to add new candidates. Imports INPUTS and FINGERPRINT from
# <target>.fixture.rb (locked by hook after iter-0 baseline).
#
# Run:   bin/rails runner auto/<target>.bench.rb
# Env:   ITERS=<int>      override default 100 for very slow targets

require_relative File.basename(__FILE__).sub(".bench.rb", ".fixture")
# imports INPUTS, FINGERPRINT
require "digest"

ITERS  = Integer(ENV.fetch("ITERS", "100"))
WARMUP = 5

# Fixture integrity self-check — pairs with the pre-commit fixture lock.
# After this target's iter-0 baseline, the fixture's SHA must match the
# Fixture-SHA trailer recorded in that commit. Catches uncommitted edits
# before they bench. Target is derived from branch suffix so inherited
# iter-0 commits from other autoresearch branches do not false-trigger.
branch = `git rev-parse --abbrev-ref HEAD 2>/dev/null`.strip
if branch.start_with?("autoresearch/")
  target = branch.sub(%r{\Aautoresearch/}, "")
  iter0  = `git log --grep="^iter 0 baseline: #{target} " --oneline 2>/dev/null`.strip
  unless iter0.empty?
    fixture_path = __FILE__.sub(".bench.rb", ".fixture.rb")
    expected = `git log --grep="^iter 0 baseline: #{target} " --format='%(trailers:key=Fixture-SHA,valueonly=true)' -1`.strip
    actual   = Digest::SHA256.file(fixture_path).hexdigest[0, 12]
    if !expected.empty? && expected != actual
      abort "FIXTURE_TAMPERED expected=#{expected} actual=#{actual}"
    end
  end
end

# Each candidate produces the same output (FINGERPRINT-equivalent).
# Pick direction from EXPLAIN signals — see SKILL.md "EXPLAIN reading hints".
# Use INPUTS[:foo] for any value that could vary run-to-run; never literals.
CANDIDATES = {
  baseline: -> {
    # REPLACE with the production call you are optimizing.
    # Example: User.find(INPUTS[:user_id]).posts.recent.limit(INPUTS[:page_size]).to_a
    raise "Replace baseline lambda with the production call you are optimizing"
  },
  # candidate_<N>_<descriptive_slug>: -> { ... different implementation, same output ... },
}

def measure(blk)
  GC.start
  queries = 0
  db_us   = 0
  sub = ActiveSupport::Notifications.subscribe("sql.active_record") do |_, s, f, _, payload|
    next if payload[:name] == "SCHEMA" || payload[:cached]
    queries += 1
    db_us   += ((f - s) * 1_000_000).to_i
  end
  ActiveRecord::Base.connection.clear_query_cache
  t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC, :microsecond)
  result = blk.call
  t1 = Process.clock_gettime(Process::CLOCK_MONOTONIC, :microsecond)
  ActiveSupport::Notifications.unsubscribe(sub)
  { time_us: t1 - t0, db_us: db_us, queries: queries, result: result }
end

def percentile(xs, p) = xs.sort[((xs.size - 1) * (p / 100.0)).round]
def median(xs)        = percentile(xs, 50)

CANDIDATES.each do |name, blk|
  WARMUP.times { measure(blk) }
  runs  = Array.new(ITERS) { measure(blk) }
  times = runs.map { |r| r[:time_us] }
  m_us  = median(times)

  fields = {
    candidate:   name,
    median_us:   m_us,
    min_us:      times.min,
    p95_us:      percentile(times, 95),
    p99_us:      percentile(times, 99),
    max_us:      times.max,
    db_us:       median(runs.map { |r| r[:db_us] }),
    queries:     runs.first[:queries],
    iters:       ITERS,
    fingerprint: FINGERPRINT.call(runs.first[:result]),
  }
  puts "METRIC " + fields.map { |k, v| "#{k}=#{v}" }.join(" ")
end
