#!/usr/bin/env python3
import argparse
from versioning import advance

parser = argparse.ArgumentParser(description='Update the shared app and provider version and advance the build number.')
parser.add_argument('version', metavar='MAJOR.MINOR.PATCH')
args = parser.parse_args()
try:
    build = advance(args.version)
except ValueError as error:
    parser.error(str(error))
print(f'MacDPI {args.version}, build {build}, applies to the host and both providers.')
