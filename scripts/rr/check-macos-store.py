#!/usr/bin/env python3
"""Audit the built store bundle, including its effective sandbox entitlements."""
import pathlib, plistlib, subprocess, sys
app = pathlib.Path(sys.argv[1])
info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
assert info['CFBundleIdentifier'] == 'in.roundrobin.bridgey.store'
assert not any(k.startswith('SU') for k in info)
assert not (app / 'Contents/Frameworks').exists()
assert (app / 'Contents/Resources/Licences/LICENSE.txt').read_text().startswith('MIT License')
binary = app / 'Contents/MacOS/BridgeyMacStore'
linked = subprocess.check_output(['otool', '-L', str(binary)], text=True)
strings = subprocess.check_output(['strings', '-a', str(binary)], text=True)
for forbidden in ['Sparkle.framework', 'MediaRemote.framework', 'MRMediaRemote', 'com.apple.coreservices.useractivityd', 'CGEventPost', 'llama.framework']:
    assert forbidden not in linked + strings, forbidden
raw = subprocess.run(['codesign', '-d', '--entitlements', ':-', str(app)], check=True, capture_output=True).stdout
entitlements = plistlib.loads(raw)
expected = {'com.apple.security.app-sandbox', 'com.apple.security.network.client', 'com.apple.security.network.server', 'com.apple.security.files.user-selected.read-write'}
assert set(entitlements) == expected and all(entitlements.values()), entitlements.keys()
print('Store bundle: sandbox, selected files, network only; excluded frameworks and APIs absent.')
