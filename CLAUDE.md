# Mangosteen

Before starting, read `PROJECT_CONTEXT.md`: project state, architecture, rules that must not be broken, known gaps
and the next step. Update it at the end of a larger stage of work.

- The user writes in Russian; answer in Russian.
- Build and test: `xcodegen generate`, then
  `xcodebuild test -scheme Mangosteen -destination 'platform=macOS' -derivedDataPath build.noindex/test`.
- New user-facing strings: Russian key in code → `scripts/translations.json` → `python3 scripts/check_translations.py --write`.
- Check every changed window with the DEBUG `--snapshot` mode before handing it over.
- The Windows version lives in a separate repository (`SpaceCadet0/Mangosteen-Windows`); changes are passed there
  only when the user asks.
