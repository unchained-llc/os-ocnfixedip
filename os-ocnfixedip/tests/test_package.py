import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class Package(unittest.TestCase):
    def test_manifest_stages_license_and_runtime_and_checks_prerequisites(self):
        # Validate the real staging/manifest builder without requiring FreeBSD pkg.
        with tempfile.TemporaryDirectory(prefix='ocnfixedip-package-') as directory:
            directory = Path(directory)
            binary = directory / 'bin'; binary.mkdir()
            pkg = binary / 'pkg'
            pkg.write_text('''#!/usr/bin/env python3
import json, os, pathlib, sys
args=sys.argv[1:]
meta=pathlib.Path(args[args.index('-M')+1]).read_text()
plist=pathlib.Path(args[args.index('-p')+1]).read_text()
pathlib.Path(os.environ['CAPTURE']).write_text(json.dumps({'manifest':meta,'plist':plist}))
''')
            pkg.chmod(0o755)
            capture = directory / 'capture.json'
            env = dict(os.environ, PATH=str(binary)+os.pathsep+os.environ['PATH'], WORK_DIR=str(directory/'work'), OUT_DIR=str(directory/'dist'), CAPTURE=str(capture), PKG_VERSION='2026.10.28')
            subprocess.run(['sh',str(ROOT/'tools/build-pkg.sh')],env=env,check=True,capture_output=True)
            import json
            data=json.loads(capture.read_text())
            self.assertIn('usr/local/share/licenses/os-ocnfixedip/LICENSE',data['plist'])
            self.assertIn('runtime.py',data['plist'])
            self.assertNotIn('__pycache__',data['plist'])
            self.assertNotIn('.pyc',data['plist'])
            self.assertNotIn('.DS_Store',data['plist'])
            self.assertNotIn('i18n.js',data['plist'])
            self.assertIn('version: "2026.10.28"',data['manifest'])
            # The default version is the date itself, with no build suffix/time.
            date = binary / 'date'
            date.write_text('#!/bin/sh\n[ "$1" = "+%Y.%m.%d" ] || exit 1\nprintf "2026.10.28\\n"\n')
            date.chmod(0o755)
            env['PKG_VERSION']=''
            subprocess.run(['sh',str(ROOT/'tools/build-pkg.sh')],env=env,check=True,capture_output=True)
            default=json.loads(capture.read_text())
            self.assertIn('version: "2026.10.28"',default['manifest'])
            hook=data['manifest'].split('pre-install: <<EOD\n',1)[1].split('\nEOD',1)[0]
            subprocess.run(['sh','-n'],input=hook,text=True,check=True)
            self.assertIn('command -v "$tool"',hook)
            failed=subprocess.run(['/bin/sh','-c',hook],env={'PATH':str(binary)},capture_output=True,text=True)
            self.assertNotEqual(failed.returncode,0)
            self.assertIn('Missing runtime prerequisite:',failed.stderr)


if __name__=='__main__': unittest.main()
