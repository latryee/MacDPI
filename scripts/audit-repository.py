#!/usr/bin/env python3
"""Read-only release hygiene checks; examines tracked/source candidates, never user files."""
import ast, json, pathlib, plistlib, re, subprocess
root=pathlib.Path(__file__).resolve().parents[1]
required=['README.md','LICENSE','CONTRIBUTING.md','CODE_OF_CONDUCT.md','SECURITY.md','PRIVACY.md','ARCHITECTURE.md','COMPATIBILITY.md','INSTALLATION.md','BUILDING.md','TROUBLESHOOTING.md','PERFORMANCE.md','TEST_RESULTS.md','CHANGELOG.md','.gitignore']
for name in required: assert (root/name).is_file(),name
listed=subprocess.check_output(['git','ls-files','--cached','--others','--exclude-standard','-z'],cwd=root).split(b'\0')
for item in listed:
    if not item: continue
    path=root/item.decode()
    assert path.suffix not in ['.p12','.pem','.key','.cer','.mobileprovision','.provisionprofile'],path
    if path.suffix in ['.swift','.py','.sh','.md','.yml','.json','.plist','.entitlements']:
        text=path.read_text()
        assert ('-----'+'BEGIN PRIVATE KEY'+'-----') not in text,path
        assert ('-----'+'BEGIN RSA PRIVATE KEY'+'-----') not in text,path
        assert not re.search(r'/Users/[A-Za-z0-9_-]+/',text),path
    if path.suffix=='.py': ast.parse(path.read_text(),filename=str(path))
    if path.suffix in ['.plist','.entitlements']: plistlib.loads(path.read_bytes())
    if path.suffix=='.json': json.loads(path.read_text())
for path in (root/'scripts').glob('*.sh'): subprocess.run(['bash','-n',str(path)],check=True)
subprocess.run(['git','diff','--check'],cwd=root,check=True)
print('Required documentation, candidate files, source syntax, private-key exclusion, portable paths and whitespace verified.')
