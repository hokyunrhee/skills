---
name: pundit-authorization
description: Pundit best practices for Rails apps with `gem 'pundit'` installed — policy classes, the `Pundit::Authorization` module, the `authorize`/`policy_scope`/`verify_*` quartet, and `permitted_attributes` for role-based strong parameters. Silent when Gemfile lacks `gem 'pundit'`. Triggers when the user writes a policy, wires a controller to Pundit, adds role-based attributes, debugs `Pundit::NotAuthorizedError`, or asks about policy scopes.
---

## Core principle

Pundit is a thin wrapper around Ruby classes named `<Model>Policy`. Every policy class answers a fixed set of boolean predicates (`index?`, `show?`, `create?`, `update?`, `destroy?`) against a `(user, record)` pair. Apply Pundit consistently across the controller surface — the `verify_*` callbacks catch forgotten authorizations early, before they become security bugs.

## Decision matrix

| Situation                                                  | Use                                                                                           |
| ---------------------------------------------------------- | --------------------------------------------------------------------------------------------- |
| Single-record authorization in a controller action         | `authorize @record`                                                                           |
| Collection filtering in an `index` action                  | `policy_scope(Scope)`                                                                         |
| namespaced policy (admin)                                  | `authorize [:admin, @record]` / `policy_scope([:admin, Scope])`                               |
| Controller without a model (dashboard, report)             | `authorize :dashboard, :show?`                                                                |
| Role-based permitted attributes                            | `permitted_attributes_for_<action>` in policy + `permitted_attributes(@record)` in controller |
| Legitimate skip (public endpoint, webhook, health check)   | `skip_authorization` / `skip_policy_scope` inside the action                                  |
| Authorization outside a controller (job, service, console) | `Pundit.authorize(user, record, :query?)` with strict variant                                 |

## Setup

Two steps, run in order, once per project. Everything beyond this is situational and lives in Patterns.

1. **[Low freedom — MANDATORY first step]** Confirm Pundit is actually in the project. Grep `Gemfile` for `^\s*gem\s+['"]pundit['"]`. If absent, stop. Do not advise on authorization at all — leave the decision to the user's broader auth strategy.

2. **[Low freedom]** Install — only if the generator has not already been run (check for `app/policies/application_policy.rb`):

```bash
bundle add pundit
bin/rails generate pundit:install
```

This generates `app/policies/application_policy.rb` with default-deny predicates (every action returns `false`) and a nested `Scope` class. Then ensure `ApplicationController` includes the authorization module:

```ruby
class ApplicationController < ActionController::Base
  include Pundit::Authorization
end
```

`include Pundit::Authorization` is a mechanical prerequisite, not a design choice. The opinionated pieces — how failures surface to the user, whether to enforce a safety net for forgotten `authorize` calls — live in the Patterns section below.

## Patterns

Each pattern below addresses a different situation. They are **not a sequence** — but they **compose**. A single feature task often applies several patterns together. Apply whichever combination the task needs.

### Rescue handler for `Pundit::NotAuthorizedError`

**When:** you want failed `authorize` calls to surface as a user-facing response rather than a raw 500. Pundit works without a handler — it just bubbles up as an unhandled exception, which is almost never what you want in production.

**[Medium freedom]** The handler **shape** is stable (`rescue_from Pundit::NotAuthorizedError, with: :user_not_authorized`). The handler **body** depends on the response format. Pick the variant that matches the controller's primary response format; for mixed codebases, branch on `request.format` inside the handler.

**HTML apps (flash + redirect)** — the most common default:

```ruby
class ApplicationController < ActionController::Base
  include Pundit::Authorization

  rescue_from Pundit::NotAuthorizedError, with: :user_not_authorized

  private

  def user_not_authorized
    flash[:alert] = "You are not authorized to perform this action."
    redirect_back_or_to(root_path)
  end
end
```

If the handler grows conditionals beyond format branching, the logic belongs elsewhere (a policy predicate, a role check, a feature flag), not in the handler.

### Consolidated verify callback

**When:** guaranteeing every action either authorizes a record or applies a policy scope. Place this once in `ApplicationController`:

**[Low freedom]** Place this once in `ApplicationController` to guarantee every action either authorizes a record or applies a policy scope:

```ruby
class ApplicationController < ActionController::Base
  include Pundit::Authorization
  after_action :verify_pundit_authorization

  private

  def verify_pundit_authorization
    if action_name == "index"
      verify_policy_scoped
    else
      verify_authorized
    end
  end
end
```

For actions that legitimately skip authorization, call `skip_authorization` or `skip_policy_scope` inside the action — do not edit this callback.

### Policy per model

**When:** you are adding authorization for a specific model.

**[Medium freedom]**

```bash
bin/rails generate pundit:policy post
```

Edit to inherit from `ApplicationPolicy` and implement only the predicates that differ from default-deny:

```ruby
class PostPolicy < ApplicationPolicy
  def create?
    user.admin?
  end

  def destroy?
    user.admin? && !record.published?
  end

  class Scope < ApplicationPolicy::Scope
    def resolve
      return scope.all if user.admin?
      scope.where(published: true)
    end
  end
end
```

`new?` defaults to `create?` and `edit?` defaults to `update?` via `ApplicationPolicy`. Do not override them unless they diverge.

### Controller call sites

**When:** wiring a specific controller action to Pundit.

**[Low freedom]** The full `authorize` signature is `authorize(record, query = nil, policy_class: nil)` — you can pass an explicit query method or policy class when inference is wrong:

```ruby
class PostsController < ApplicationController
  def index
    @posts = policy_scope(Post)
  end

  def show
    @post = Post.find(params[:id])
    authorize @post
  end

  def create
    @post = Post.new(post_params)
    authorize @post
    @post.save
    # ...
  end

  def publish
    @post = Post.find(params[:id])
    authorize @post, :publish?            # explicit query method
    @post.publish!
  end
end
```

`authorize @post` infers both the policy class (`PostPolicy`) and the predicate (`create?` in the `create` action) from context. Explicit second argument overrides predicate inference; `policy_class:` keyword overrides policy-class inference.

### Namespaced policies

**When:** the controller lives under a namespace (admin areas, versioned APIs) and the policy class should follow the same namespace — `Admin::PostPolicy` rather than `PostPolicy`.

**[Medium freedom]** Create the policy under the matching module path:

```ruby
# app/policies/admin/post_policy.rb
module Admin
  class PostPolicy < ApplicationPolicy
    def update?
      user.admin?
    end

    class Scope < ApplicationPolicy::Scope
      def resolve
        scope.all
      end
    end
  end
end
```

At the call site, pass an array — the leading symbol becomes the namespace:

```ruby
# Admin::PostsController
def update
  @post = Post.find(params[:id])
  authorize [:admin, @post]             # looks up Admin::PostPolicy
end

def index
  @posts = policy_scope([:admin, Post]) # looks up Admin::PostPolicy::Scope
end
```

### Headless policies

**When:** the controller has no underlying model — dashboards, reports, settings pages, admin consoles.

**[Medium freedom]** Define a policy class named after the abstract concept, not a model:

```ruby
# app/policies/dashboard_policy.rb
class DashboardPolicy < ApplicationPolicy
  def show?
    user.admin?
  end
end
```

At the call site, pass a symbol as the record — it becomes `record` inside the policy initializer:

```ruby
def show
  authorize :dashboard, :show?          # looks up DashboardPolicy#show?
end
```

Inheriting from `ApplicationPolicy` is optional; the default-deny baseline is the usual reason to do it.

### Role-based strong parameters

**When:** different roles should submit different subsets of attributes for the same action.

**[Medium freedom]** Define per-action allowlist methods on the policy; the controller composes them with strong parameters via Pundit's helper:

```ruby
class ArticlePolicy < ApplicationPolicy
  def permitted_attributes_for_create
    user.editor? ? [:title, :body, :category, :published_at] : [:title, :body]
  end

  def permitted_attributes_for_update
    user.editor? ? [:title, :body, :category, :published_at, :archived_at] : [:title, :body]
  end
end

class ArticlesController < ApplicationController
  def update
    authorize @article
    @article.update(permitted_attributes(@article))
  end
end
```

`permitted_attributes(@article)` resolves to `pundit_params_for(@article).permit(*policy.permitted_attributes_for_<action>)`, falling back to `policy.permitted_attributes` when the per-action method is not defined. Strong parameters are not bypassed — the policy just defines the allowlist; the final `permit` still runs.

**Upcoming (Pundit 2.6.0, unreleased as of 2026-04):** a newer form uses `expected_attributes_for_action(action_name)` on the policy plus the `expected_attributes(record)` controller helper, which internally wraps Rails 8's `params.expect`. Use it once 2.6.0 ships; on Pundit ≤ 2.5 calling `expected_attributes` raises `NoMethodError`.

### Testing policies

**When:** you have policy logic worth regression-testing. Applies in parallel with every other pattern — testing is not a "later" step.

**[High freedom]** Policies are plain Ruby classes — construct them and call the predicate:

```ruby
# Minitest
require "test_helper"

class PostPolicyTest < ActiveSupport::TestCase
  def test_admin_can_create
    policy = PostPolicy.new(users(:admin), Post.new)
    assert policy.create?
  end

  def test_guest_cannot_destroy_published
    post = Post.new(published: true)
    policy = PostPolicy.new(users(:guest), post)
    refute policy.destroy?
  end

  def test_scope_excludes_unpublished_for_guest
    resolved = PostPolicy::Scope.new(users(:guest), Post).resolve
    assert_includes resolved, posts(:published)
    refute_includes resolved, posts(:draft)
  end
end
```

Policy tests are the fastest feedback loop on authorization logic. Controller tests exercise the wiring, not the policy rules.

### Pundit outside controllers

**When:** authorizing inside a background job, service object, model callback, or console script — anywhere `current_user` is not in scope.

**[Medium freedom]** Pundit exposes top-level module methods that take an explicit user — no `current_user` assumption:

```ruby
# Inside a job, service, or console
Pundit.authorize(user, @post, :destroy?)
Pundit.policy(user, @post)          # returns PostPolicy instance or nil
Pundit.policy!(user, @post)         # raises Pundit::NotDefinedError if missing
Pundit.policy_scope(user, Post)     # returns a scope or nil
Pundit.policy_scope!(user, Post)    # raises if PostPolicy::Scope missing
```

Prefer `Pundit.authorize` / `Pundit.policy_scope!` for the strict variants in non-controller code so missing policies fail loudly rather than silently nil-returning.

## Gotchas

- **`ApplicationPolicy` defaults must stay `false`.** If a predicate returns `true` by default, a newly-generated policy with no overrides silently authorizes everything. The generator's default-deny posture is a load-bearing security invariant.
- **`verify_authorized` is a reminder, not a security gate.** It raises on controller actions that _forgot_ to call `authorize`; it does not raise when `authorize` returned `false` — that is a separate `Pundit::NotAuthorizedError`. Do not confuse the two.
- **`policy_scope` and `authorize` are not interchangeable.** Use `policy_scope(Post)` for collection queries (`index`); use `authorize @post` for single-record access. Scoping a single record with `policy_scope` defeats the check; calling `authorize` on a raw collection does nothing useful.
- **`pundit_user` override.** By default, Pundit looks up `current_user`. Apps that use a different helper (`Current.user`, the Rails 8 native auth generator's `Current.session.user`) must override `pundit_user` in `ApplicationController`:

```ruby
def pundit_user
  Current.user
end
```

- **Helpers, each with a different job. Do not confuse them.**
  - `permitted_attributes(record)` — current stable helper. Returns the permitted params Hash via `pundit_params_for(record).permit(*policy.permitted_attributes_for_<action>)`, with fallback to `policy.permitted_attributes`.
  - `expected_attributes(record)` — Pundit 2.6.0+ (unreleased as of 2026-04), not on 2.5.x. Same idea but wraps Rails 8's `params.expect` instead of `params.require(...).permit(...)`.
  - `pundit_params_for(record)` — **raw params extractor only**, not an attribute resolver. Source: `params.require(pundit_param_key(record))`. Override it to change the params shape (JSON:API, nested keys, etc.). Do not splat its return value into `permit(*)` — it returns `ActionController::Parameters`, not an Array.

- **Four Pundit errors, four meanings.** Distinguish them when debugging and when writing `rescue_from` handlers:
  - `Pundit::NotAuthorizedError` — `authorize` was called and the policy predicate returned `false`. Handle with a flash + redirect.
  - `Pundit::AuthorizationNotPerformedError` — `verify_authorized` fired because the action did not call `authorize`. Handle by calling `authorize` or `skip_authorization`.
  - `Pundit::PolicyScopingNotPerformedError` (subclass of `AuthorizationNotPerformedError`) — `verify_policy_scoped` fired on an `index`-style action that did not call `policy_scope`. Handle by calling `policy_scope` or `skip_policy_scope`.
  - `Pundit::NotDefinedError` — policy or scope class does not exist for the given record. Usually means a missing `<Model>Policy` file or a typo in `authorize([:admin, record])` namespacing. Fix by creating the policy; do not rescue silently.

- **`pundit_reset!` for user switching.** After login, logout, or impersonation inside the same request cycle, call `pundit_reset!` to clear Pundit's memoized user so subsequent `authorize` / `policy_scope` calls use the new user. Rarely needed in normal request flow.

## When to leave this skill

- For authentication (login, session management) → out of scope; this plugin does not advocate migrating between auth libraries
- For role modeling (defining `admin?`, `member?`, `owner_of?` on the `User` model) → out of scope; that is domain modeling, not Pundit
- For authorization in an app that does **not** have Pundit installed → this skill stays silent; do not suggest adopting Pundit, do not suggest alternatives
