# frozen_string_literal: true
#
# auto/<target>.fixture.rb — locked after iter-0 baseline commit.
#
# Defines WHAT is being measured: pinned inputs + output equivalence
# contract. The bench file (<target>.bench.rb) imports from here.
#
# After iter-0 baseline commit:
#   - pre-commit hook rejects any diff to this file
#   - bench harness aborts if SHA differs from iter-0's Fixture-SHA trailer
#
# To change the contract (different inputs, looser fingerprint, etc.):
# the only path is a new scratch branch with a new fixture. Mid-loop
# editing invalidates prior measurements and is mechanically blocked.

require "digest"

# Inputs the candidate lambdas use. Pin everything that could vary
# run-to-run: user IDs, dates, random seeds, page sizes. Lambda bodies
# in the bench file must reference INPUTS[:foo], never hardcoded values.
INPUTS = {
  # REPLACE with your case's pinned inputs. Examples:
  # user_id:    42,
  # as_of:      Time.zone.parse("2024-04-15T09:00:00Z"),
  # page_size:  50,
  # rng_seed:   1,
}

# Output equivalence contract. The default is strict — SHA1 of the
# return value's `inspect`. This catches accidental row-order changes,
# Active Record-vs-Hash drift, hydration differences, and field-set differences.
# Tight on purpose.
#
# Override only at iter-0 with explicit user confirmation. Common
# legitimate cases:
#
#   # Consumer iterates as a Set; row order is not part of the contract.
#   # Note: do NOT use Array#hash here — Ruby seeds it per-process, so the
#   # same data hashes differently across `bin/rails runner` invocations
#   # and Gate A would always fail. Use a canonical string form (.inspect,
#   # .to_json) instead.
#   FINGERPRINT = ->(r) {
#     Digest::SHA1.hexdigest(r.map { |x| [x[:id], x[:total]] }.sort.inspect)[0, 12]
#   }
#
#   # Consumer reads only id and a derived sum.
#   FINGERPRINT = ->(r) {
#     Digest::SHA1.hexdigest([r.size, r.sum(&:total)].inspect)[0, 12]
#   }
#
# When overriding, also set the iter-0 commit's `Fingerprint-Mode: custom`
# trailer and document the relaxation in the commit body. Strategy 5
# (hydration bypass: Active Record vs find_by_sql vs exec_query) requires a
# custom fingerprint because Active Record objects and Hash representations differ under
# the strict default.
FINGERPRINT = ->(r) { Digest::SHA1.hexdigest(r.inspect)[0, 12] }
