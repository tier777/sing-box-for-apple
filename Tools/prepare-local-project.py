#!/usr/bin/env python3
"""Generate an entitlement-free local-app project without changing NE targets."""
import json
import pathlib
import plistlib
import shutil
import subprocess
root = pathlib.Path(__file__).resolve().parents[1]
source = root / 'sing-box.xcodeproj'
destination = root / '.sfm-local.xcodeproj'
if destination.exists():
    shutil.rmtree(destination)
shutil.copytree(source, destination, ignore=shutil.ignore_patterns('xcuserdata'))
project = json.loads(subprocess.check_output(['plutil', '-convert', 'json', '-o', '-', str(source / 'project.pbxproj')]))
objects = project['objects']
target = next(value for value in objects.values() if value.get('isa') == 'PBXNativeTarget' and value.get('name') == 'SFM.System')
target['buildPhases'] = [identifier for identifier in target['buildPhases'] if objects[identifier].get('name') not in ('Embed System Extensions', 'Copy Helpers', 'Copy LaunchDaemon', 'Embed Foundation Extensions')]
target['dependencies'] = [identifier for identifier in target['dependencies'] if objects[objects[identifier]['target']].get('name') in ('Library', 'MacLibrary')]
for identifier in objects[target['buildConfigurationList']]['buildConfigurations']:
    settings = objects[identifier]['buildSettings']
    settings['CODE_SIGN_ENTITLEMENTS'] = ''
    settings['ENABLE_APP_SANDBOX'] = 'NO'
    settings['ENABLE_HARDENED_RUNTIME'] = 'NO'
with (destination / 'project.pbxproj').open('wb') as output:
    plistlib.dump(project, output, sort_keys=False)
for scheme in destination.rglob('*.xcscheme'):
    scheme.write_text(scheme.read_text().replace('container:sing-box.xcodeproj', 'container:.sfm-local.xcodeproj'))
print(destination)
