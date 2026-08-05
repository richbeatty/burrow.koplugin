# Contributing to Burrow

Burrow is an early-stage KOReader plugin. Bug reports, device testing, documentation improvements, and focused fixes are welcome.

## Before opening an issue

Please check existing issues and confirm that:

- Burrow is the latest available version
- KOReader's built-in Cover Browser is disabled
- the problem remains after fully restarting KOReader

## Bug reports

Include:

- Burrow version
- KOReader version or full `git-rev`
- device and operating system
- exact steps to reproduce the problem
- what you expected and what happened
- a screenshot when the issue is visual
- the relevant section of `crash.log`
- a list of other plugins or userpatches that modify covers, menus, the file browser, or reader footer

Remove catalog credentials, tokens, personal paths, book titles, and other private information from logs before posting them.

## Pull requests

Keep changes focused. Avoid combining unrelated visual redesigns, refactors, and behavior changes in one pull request.

Before submitting:

1. Run the Lua syntax checks.
2. Test on KOReader when the change affects widgets or navigation.
3. Update documentation for user-facing changes.
4. Add an entry under `Unreleased` in `CHANGELOG.md`.
5. Confirm no settings, databases, logs, credentials, books, or font binaries are included.

## Code guidelines

- Follow the existing Lua style in the surrounding file.
- Guard global KOReader method wrappers so they apply only once.
- Prefer explicit module `apply()` entry points.
- Keep optional feature failures isolated from the core library.
- Preserve native KOReader widget trees unless replacement is unavoidable.
- Use Burrow-prefixed settings keys and icon names.
- Retain upstream notices in substantially derived files.

## Testing priorities

Changes should be tested in both portrait and landscape when relevant. Reader-interface changes should also be checked in light and night modes.

High-risk workflows include:

- opening a series, opening a book, and returning with the Back gesture
- repeated Home and Store switching
- Store downloads and failed-download retries
- menu opening and closing after orientation changes
- plugin disable, restart, re-enable, and restart
- upgrades from earlier Burrow versions

## License

By contributing, you agree that your contribution will be distributed under GNU AGPL v3, consistent with Burrow and the upstream projects from which portions are derived.
