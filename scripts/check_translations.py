#!/usr/bin/env python3
"""Checks that every localizable key the compiler extracted has an English and Spanish translation.

Run after a build (SWIFT_EMIT_LOC_STRINGS=YES writes .stringsdata files):
    scripts/check_translations.py [derived data path, default build.noindex]
New Russian strings go into scripts/translations.json; Localizable.strings are generated from it with --write.
"""
import glob, json, os, re, sys

root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
derived = next((a for a in sys.argv[1:] if not a.startswith('--')), os.path.join(root, 'build.noindex'))
table = json.load(open(os.path.join(root, 'scripts', 'translations.json')))
cyrillic = re.compile('[А-Яа-яЁё]')
keys = set()
for path in glob.glob(os.path.join(derived, '**', 'Mangosteen.build', '**', '*.stringsdata'), recursive=True):
    for entries in json.load(open(path)).get('tables', {}).values():
        keys.update(e['key'] for e in entries if cyrillic.search(e['key']))
missing = sorted(k for k in keys if k not in table or not table[k].get('en') or not table[k].get('es'))
if '--write' in sys.argv:
    def esc(s): return s.replace('\\', '\\\\').replace('"', '\\"').replace('\n', '\\n')
    for lang in ('en', 'es'):
        lines = ['/* Generated from scripts/translations.json. Keys are the Russian text. */']
        lines += [f'"{esc(k)}" = "{esc(table[k][lang])}";' for k in sorted(table)]
        with open(os.path.join(root, 'Mangosteen', 'Resources', f'{lang}.lproj', 'Localizable.strings'), 'w') as f:
            f.write('\n'.join(lines) + '\n')
print(f"{len(keys)} keys in code, {len(table)} translated, {len(missing)} missing")
for key in missing:
    print('  missing:', json.dumps(key, ensure_ascii=False))
sys.exit(1 if missing else 0)
