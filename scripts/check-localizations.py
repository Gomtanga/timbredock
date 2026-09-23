#!/usr/bin/env python3
"""Check shipped en/ko tables and format arguments without launching audio."""
import json
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
RESOURCES = ROOT / 'SystemAudioProcessor/Sources/SystemAudioProcessor/Resources'
PLACEHOLDER = re.compile(r'%(?!%)(?:\d+\$)?[-+ #0]*(?:\d+|\*)?(?:\.(?:\d+|\*))?(?:hh|ll|[hlLzjt])?[@diuoxXfFeEgGcCsSp]')

def read_table(path):
    result = subprocess.run(['plutil', '-convert', 'json', '-o', '-', str(path)],
                            check=True, capture_output=True, text=True)
    return json.loads(result.stdout)

def check():
    translations = {}
    for locale in ('en', 'ko'):
        merged = {}
        tables = sorted((RESOURCES / f'{locale}.lproj').glob('*.strings'))
        assert tables, f'No tables for {locale}'
        translations[locale] = {}
        for path in tables:
            table = read_table(path)
            assert not merged.keys() & table.keys(), f'Duplicate keys across tables: {path}'
            merged.update(table)
            translations[locale][path.name] = table
        translations[locale]['all'] = merged
    assert translations['en'].keys() == translations['ko'].keys(), 'Locale tables differ'
    for name, english in translations['en'].items():
        korean = translations['ko'][name]
        assert english.keys() == korean.keys(), f'Locale keys differ in {name}: {english.keys() ^ korean.keys()}'
        for key, value in english.items():
            assert value.strip() and korean[key].strip(), f'Empty translation: {key}'
            assert PLACEHOLDER.findall(value) == PLACEHOLDER.findall(korean[key]), f'Format arguments differ: {key}'
    keys = translations['en']['all']
    for source in (ROOT / 'SystemAudioProcessor/Sources/SystemAudioProcessor').glob('*.swift'):
        for key in re.findall(r'L10n\.(?:string|format)\("([^"\\]+)"', source.read_text()):
            assert key in keys, f'Missing localization {key} in {source.name}'
    print(f'LocalizationChecks: {len(keys)} en/ko keys, table parity and format arguments passed')

if __name__ == '__main__':
    check()
