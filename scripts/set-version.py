#!/usr/bin/env python3
import pathlib, plistlib, re, sys
root=pathlib.Path(__file__).resolve().parents[1]
if len(sys.argv)!=2 or not re.fullmatch(r'\d+\.\d+\.\d+',sys.argv[1]):
    raise SystemExit('Usage: scripts/set-version.py MAJOR.MINOR.PATCH')
version=sys.argv[1]
(root/'VERSION').write_text(version+'\n')
p=root/'MacDPI.xcodeproj/project.xcproj'
p.write_text(re.sub(r'("MARKETING_VERSION": ")[^"]+',lambda m:m[1]+version,p.read_text()))
p=root/'Extension/Info.plist'
info=plistlib.loads(p.read_bytes());info['CFBundleShortVersionString']=version
p.write_bytes(plistlib.dumps(info))
print('Updated VERSION, Xcode configurations, and provider metadata. Update CHANGELOG.md before packaging.')
