"""Validate candidate source and local docs without GUI access or dependencies.

Git's index plus non-ignored untracked files define the candidate release, so
ignored local evidence cannot satisfy a documentation link.
"""
# SPDX-License-Identifier: GPL-3.0-or-later
from __future__ import annotations

import ast
from pathlib import Path
import re
import subprocess
import sys
from urllib.parse import unquote

ROOT = Path(__file__).resolve().parents[1]
REQUIRED = (
    'README.md', 'LICENSE', 'COPYRIGHT', 'THIRD_PARTY_NOTICES.md', 'SKILL.md',
    'CONTRIBUTING.md', 'SECURITY.md', 'CHANGELOG.md',
    'docs/installation.md', 'docs/validation-status.md', '.github/workflows/ci.yml',
)
FORBIDDEN_PARTS = {'artifacts', '.cache', '.dart_tool', 'build',
                   '__pycache__', '.gradle', '.kotlin', 'ephemeral', '.venv'}
FORBIDDEN_SUFFIXES = {'.lock', '.pyc', '.log', '.exe', '.dll', '.mp4', '.mkv'}
SECRET_PATTERNS = {
    'private key': re.compile(r'-----BEGIN (?:RSA |OPENSSH |EC )?PRIVATE KEY-----'),
    'GitHub token': re.compile(r'\b(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{40,})\b'),
    'AWS access key': re.compile(r'\b(?:AKIA|ASIA)[A-Z0-9]{16}\b'),
}


def check():
    if sys.version_info < (3, 11):
        raise RuntimeError('Python 3.11+ is required')
    result = subprocess.run(
        ['git', 'ls-files', '--cached', '--others', '--exclude-standard', '-z'],
        cwd=ROOT, capture_output=True, check=True,
    )
    names = sorted(set(result.stdout.decode('utf-8').strip('\0').split('\0')) - {''})
    files = {name: ROOT / name for name in names}
    shipped = {path.resolve() for path in files.values()}
    errors = []
    for name in REQUIRED:
        if name not in files:
            errors.append(f'{name}: required release file is absent or ignored')
    for name, path in files.items():
        if FORBIDDEN_PARTS.intersection(Path(name).parts) or path.suffix in FORBIDDEN_SUFFIXES:
            errors.append(f'{name}: generated/runtime file must not be published')
        if not path.is_file():
            errors.append(f'{name}: indexed source is missing from the checkout')
            continue
        try:
            source = path.read_text(encoding='utf-8')
        except UnicodeDecodeError:
            continue  # Icons and launcher images are intentional source assets.
        for label, pattern in SECRET_PATTERNS.items():
            if pattern.search(source):
                errors.append(f'{name}: possible {label}; review before publishing')
        if path.suffix == '.py':
            try:
                ast.parse(source, filename=name, feature_version=(3, 11))
            except SyntaxError as error:
                errors.append(f'{name}:{error.lineno}: {error.msg}')
        if path.suffix == '.md':
            fenced = False
            for number, line in enumerate(source.splitlines(), 1):
                if line.lstrip().startswith(('```', '~~~')):
                    fenced = not fenced
                    continue
                if fenced:
                    continue
                for destination in re.findall(r'!?\[[^\]]*\]\(([^\s)]+)\)', line):
                    destination = destination.strip('<>')
                    if re.match(r'^[a-zA-Z][a-zA-Z0-9+.-]*:|^#', destination):
                        continue
                    destination = unquote(destination.split('#', 1)[0])
                    target = (path.parent / destination).resolve()
                    if destination and target not in shipped:
                        errors.append(f'{name}:{number}: link not in release source: {destination}')
    try:
        license_text = (ROOT / 'LICENSE').read_text(encoding='utf-8')
        if len(license_text) < 30000 or 'END OF TERMS AND CONDITIONS' not in license_text:
            errors.append('LICENSE: expected the complete GNU GPL version 3 text')
        copyright_text = (ROOT / 'COPYRIGHT').read_text(encoding='utf-8')
        if 'GPL-3.0-or-later' not in copyright_text:
            errors.append('COPYRIGHT: missing GPL-3.0-or-later grant')
        if 'Copyright (C) 2026 normalllll' not in copyright_text:
            errors.append('COPYRIGHT: missing project author notice')
    except OSError as error:
        errors.append(str(error))
    if errors:
        print('\n'.join(f'ERROR: {error}' for error in errors), file=sys.stderr)
        return 1
    print(f'Repository checks passed: {len(files)} candidate files; Python syntax, '
          'release metadata, local Markdown file links and limited secret patterns.')
    print('No GUI/device checks or external link checks were performed.')
    return 0


if __name__ == '__main__':
    try:
        raise SystemExit(check())
    except (OSError, subprocess.SubprocessError, RuntimeError) as error:
        print(f'ERROR: {error}', file=sys.stderr)
        raise SystemExit(1)
