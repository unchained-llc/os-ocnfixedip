#!/usr/bin/env python3
# SPDX-License-Identifier: BSD-2-Clause
"""Run portable static checks and regression tests; --require-php for CI."""
from pathlib import Path
import re
import shutil
import subprocess
import sys
import xml.etree.ElementTree as ET

root = Path(__file__).resolve().parents[1]
for path in root.rglob('*.sh'):
    if '.pkgbuild' not in path.parts:
        subprocess.run(['sh', '-n', str(path)], check=True)
for path in (root / 'src').rglob('*.xml'):
    ET.parse(path)
for path in (root / 'src').rglob('*.js'):
    subprocess.run(['node', '--input-type=module', '--check'], input=path.read_text(), text=True, check=True)
for path in (root / 'src').rglob('*.volt'):
    for code in re.findall(r'<script[^>]*>(.*?)</script>', path.read_text(), re.S):
        subprocess.run(['node', '--input-type=module', '--check'], input=code, text=True, check=True)
if shutil.which('php'):
    for path in (root / 'src').rglob('*'):
        if path.suffix in ('.php', '.inc'):
            subprocess.run(['php', '-l', str(path)], check=True)
    # The configure script contains an embedded PHP interface-assignment block.
    configure = (root / 'src/opnsense/scripts/OPNsense/ocnfixedip/configure.sh').read_text()
    embedded = re.search(r"<<'PHP'\n(.*?)\nPHP", configure, re.S).group(1)
    subprocess.run(['php', '-l'], input=embedded, text=True, check=True)
elif '--require-php' in sys.argv:
    sys.exit('PHP CLI is required for this check')
else:
    print('SKIP: PHP lint (PHP CLI unavailable)', flush=True)
subprocess.run([sys.executable, '-m', 'unittest', 'discover', '-s', str(root / 'tests'), '-v'], check=True)
subprocess.run(['node', str(root / 'tests/test_ui.mjs')], check=True)
print('Static checks and regression tests passed')
