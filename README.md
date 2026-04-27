# hokyunrhee/skills

A Claude Code plugin by [Hokyun Rhee](https://github.com/hokyunrhee).

## Install

From GitHub:

```bash
/plugin marketplace add hokyunrhee/skills
/plugin install omakase-rails@hokyunrhee-skills
```

## What's inside

| Skill                     | Summary                                                                                                                            |
| ------------------------- | ---------------------------------------------------------------------------------------------------------------------------------- |
| `pundit-authorization`    | Pundit policy classes, `authorize`/`policy_scope`/`verify_*`, `permitted_attributes` for role-based strong params. Silent when Gemfile lacks `gem 'pundit'`. |
| `slow-query-autoresearch` | Autonomous propose-bench-gate loop for faster ActiveRecord queries with identical output. Scope: query rewrites + index-only migrations. Silent when not in a Rails app, DB unreachable, no tests, or the slow path can't be narrowed to a deterministic callable. |

## License

MIT
