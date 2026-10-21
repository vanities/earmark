#!/usr/bin/env python3
"""Build a separate simulator integration-test target; leave the committed project untouched."""
import argparse
import json
from pathlib import Path
import subprocess
import tempfile
import yaml

parser = argparse.ArgumentParser()
parser.add_argument('--udid', required=True, help='Dedicated test simulator; never a physical device')
parser.add_argument('--result', required=True, type=Path, help='New .xcresult output path')
parser.add_argument('--root', default='/tmp/mango-earmark-smb-fixtures')
parser.add_argument('--original-epub', type=Path, help='Mango only; server must export it as ORIGINAL')
parser.add_argument('--only', action='append', default=[], help='Test method name; repeat to select several')
args = parser.parse_args()
repo = Path(__file__).resolve().parents[2]
app = 'Mango' if (repo/'Mango').is_dir() else 'Earmark'
target = app + 'NASAuditTests'
if args.result.exists(): parser.error('Result path already exists')
devices = json.loads(subprocess.check_output(['xcrun','simctl','list','devices','available','-j']))
if not any(d['udid'] == args.udid for group in devices['devices'].values() for d in group):
    parser.error('UDID is not an available simulator')
args.result = args.result.resolve()
with tempfile.TemporaryDirectory(prefix=app+'-nas-audit-') as name:
    work = Path(name)
    for child in [app,app+'Tests',app+'Widgets','Shared','Config']:
        if (repo/child).exists(): (work/child).symlink_to(repo/child, target_is_directory=True)
    spec = yaml.safe_load((repo/'project.yml').read_text())
    (work/'NASAuditTests.swift').symlink_to(Path(__file__).with_name('Tests.swift').resolve())
    (work/'FixtureServiceControl.swift').symlink_to(Path(__file__).with_name('FixtureServiceControl.swift').resolve())
    base = spec['targets'][app+'Tests']
    spec['targets'][target] = dict(base, sources=['NASAuditTests.swift', 'FixtureServiceControl.swift'],
        settings={'base': dict(base['settings']['base'], PRODUCT_BUNDLE_IDENTIFIER='com.vanities.'+app.lower()+'NASAuditTests')})
    environment = {'SMB_AUDIT_ROOT': str(Path(args.root).resolve())}
    if args.original_epub: environment['MANGO_AUDIT_ORIGINAL_EPUB'] = str(args.original_epub.resolve(strict=True))
    spec['schemes']['NASQA'] = {'build': {'targets': {app: 'all', target: ['test']}},
        'test': {'targets': [target], 'environmentVariables': environment}}
    (work/'project.yml').write_text(yaml.safe_dump(spec, sort_keys=False))
    subprocess.run(['xcodegen','generate','--spec',str(work/'project.yml')], check=True)
    command = ['xcodebuild','test','-project',str(work/(app+'.xcodeproj')),'-scheme','NASQA',
        '-destination','platform=iOS Simulator,id='+args.udid,'-parallel-testing-enabled','NO',
        '-collect-test-diagnostics','never','-resultBundlePath',str(args.result),
        '-derivedDataPath',str(args.result.parent/(app+'-NASAuditDerivedData'))]
    for method in args.only: command += ['-only-testing:'+target+'/'+target+'/'+method]
    print('Log:',args.result.with_suffix('.log'), flush=True)
    with args.result.with_suffix('.log').open('w') as log:
        result = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT)
    raise SystemExit(result.returncode)
