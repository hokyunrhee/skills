# hokyunrhee/skills

A Claude Code plugin by [Hokyun Rhee](https://github.com/hokyunrhee).

## Install

From GitHub:

```bash
/plugin marketplace add hokyunrhee/skills
/plugin install omakase-rails@hokyunrhee-skills
```

## What's inside

| Skill                     | Triggers on                                                                                                                        |
| ------------------------- | ---------------------------------------------------------------------------------------------------------------------------------- |
| `pundit-authorization`    | Pundit policy classes, verify\_\* callbacks, permitted_attributes — triggers ONLY when Gemfile has `gem 'pundit'`                  |
| `slow-query-autoresearch` | Slow Rails queries / N+1 / EXPLAIN — runs an autonomous propose-bench-gate loop on a scratch branch, keeping each iter that beats the prior best by ≥5%, until plateau. Silent when not in a Rails app, DB unreachable, or no tests. |

## License

MIT
