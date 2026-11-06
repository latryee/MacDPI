"""Keep the project-wide versions and command-line release versions in sync."""
import pathlib
import re

ROOT = pathlib.Path(__file__).resolve().parents[1]
PROJECT = pathlib.Path('MacDPI.xcodeproj/project.xcproj')
VERSION = re.compile(r'(?:0|[1-9][0-9]*)(?:\.(?:0|[1-9][0-9]*)){2}')
BUILD = re.compile(r'[1-9][0-9]{0,3}')


def setting(key):
    return re.compile(r'("' + key + r'":\s*")([^"]+)(")')


def versions(root=ROOT):
    version = (root / 'VERSION').read_text().strip()
    project = (root / PROJECT).read_text()
    marketing = setting('MARKETING_VERSION').findall(project)
    builds = setting('CURRENT_PROJECT_VERSION').findall(project)
    if not VERSION.fullmatch(version) or len(marketing) != 1 or marketing[0][1] != version:
        raise ValueError('VERSION and the shared Xcode marketing version must match.')
    if len(builds) != 1 or not BUILD.fullmatch(builds[0][1]):
        raise ValueError('A single shared positive Xcode build number is required.')
    return version, builds[0][1]


def advance(new_version, root=ROOT):
    current_version, current_build = versions(root)
    if not VERSION.fullmatch(new_version):
        raise ValueError('Expected MAJOR.MINOR.PATCH with no leading zeros.')
    if tuple(map(int, new_version.split('.'))) < tuple(map(int, current_version.split('.'))):
        raise ValueError('The release version cannot decrease.')
    new_build = str(int(current_build) + 1)
    if not BUILD.fullmatch(new_build):
        raise ValueError('The numeric build version has reached its supported limit.')
    project_path = root / PROJECT
    project = project_path.read_text()
    project = setting('MARKETING_VERSION').sub(lambda match: match[1] + new_version + match[3], project)
    project = setting('CURRENT_PROJECT_VERSION').sub(lambda match: match[1] + new_build + match[3], project)
    project_path.write_text(project)
    (root / 'VERSION').write_text(new_version + '\n')
    return new_build
