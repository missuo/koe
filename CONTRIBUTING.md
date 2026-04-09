# Contributing

Contributions are welcome! Before you open a PR, please note:

## Commit Convention

All commits **must** follow the [Conventional Commits](https://www.conventionalcommits.org/) specification. We recommend using the [Ship](https://github.com/missuo/ship) skill to generate commit messages automatically:

```bash
npx skills add missuo/ship
```

Then simply run `/ship` in Claude Code (or any compatible AI coding agent) to stage, commit, and push with a properly formatted message.

### Commit Types

| Type | When to use |
|---|---|
| `feat` | New functionality |
| `fix` | Bug fixes |
| `docs` | Documentation only |
| `style` | Formatting, no logic changes |
| `refactor` | Code restructuring without behavior change |
| `perf` | Performance improvements |
| `test` | Adding or updating tests |
| `build` | Build system or dependency changes |
| `ci` | CI/CD configuration |
| `chore` | Maintenance tasks |

### Message Format

```
<type>(<scope>): <short summary>

<optional body>

<optional footer>
```

Scope is auto-detected from file paths (e.g., `asr`, `llm`, `ui`, `config`). Breaking changes must include a `BREAKING CHANGE:` footer.

## Pull Request Guidelines

- Keep PRs focused on a single purpose
- Ensure the app still builds (`make build`)
- Verify hold-to-talk and tap-to-toggle both work
- Update docs if you changed any user-facing behavior
- For release-worthy user-facing changes, update both `CHANGELOG.md` and `docs/update-feed.json`
- See the [Contributing Guide](https://koe.li/docs/contributing) for the full contributor workflow
