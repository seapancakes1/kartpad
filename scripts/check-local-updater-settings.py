#!/usr/bin/env python3
"""Reject local updater settings that the bundled helper couldn't use."""
import json, sys

settings = json.load(open(sys.argv[1]))
missing = [key for key in ('python', 'repo', 'state', 'config', 'initial', 'buildCommand') if key not in settings]
missing += ['initial.' + key for key in ('version', 'root', 'profile') if key not in settings.get('initial', {})]
if missing:
    sys.exit('local updater settings lack: ' + ', '.join(missing))
if not str(settings['python']).startswith('/') or not isinstance(settings['buildCommand'], list):
    sys.exit('local updater settings need an absolute python path and a buildCommand argument list')
