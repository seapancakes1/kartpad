#!/usr/bin/env python3
"""Reject local updater settings that the bundled helper couldn't use.

usage: check-local-updater-settings.py SETTINGS.json
Keys are described in docs/macos-local-auto-update.md; scripts/local-updater-settings.example.json
is a starting point. Runs on Python 3.9 or newer."""
import json, os, subprocess, sys
from urllib.parse import urlparse


def problems(settings):
    if not isinstance(settings, dict):
        return ['the settings must be a JSON object']
    missing = [key for key in ('python', 'repo', 'state', 'config', 'initial', 'buildCommand') if key not in settings]
    initial = settings.get('initial') if isinstance(settings.get('initial'), dict) else {}
    missing += ['initial.' + key for key in ('version', 'root', 'profile') if key not in initial]
    if missing:
        return ['missing ' + ', '.join(missing)]
    found = []
    def absolute(name, value):
        if not isinstance(value, str) or not value.startswith('/'):
            found.append(name + ' must be an absolute path')
            return False
        return True
    if absolute('python', settings['python']):
        # The helper needs Python 3.9 or newer; the stock macOS python3 qualifies.
        try:
            probe = subprocess.run([settings['python'], '-I', '-c', 'import sys; print(sys.version_info >= (3, 9))'],
                                   capture_output=True, text=True, timeout=30)
            answer = probe.stdout.strip() if probe.returncode == 0 else None
        except (OSError, subprocess.TimeoutExpired):
            answer = None
        if answer not in ('True', 'False'):
            found.append('python does not run: ' + settings['python'])
        elif answer == 'False':
            found.append('python must be Python 3.9 or newer: ' + settings['python'])
    for key in ('state', 'config'):
        absolute(key, settings[key])
    if absolute('repo', settings['repo']) and not os.path.isfile(os.path.join(settings['repo'], 'scripts/macos-local-updater.py')):
        found.append('repo is not a KartPad checkout: ' + settings['repo'])
    if absolute('initial.root', initial['root']):
        try:
            with open(os.path.join(initial['root'], 'version.txt')) as file:
                if file.read().strip() != initial['version']:
                    found.append('initial.root is not Retro Rewind ' + str(initial['version']))
        except OSError:
            found.append('initial.root has no version.txt: ' + initial['root'])
    if absolute('initial.profile', initial['profile']):
        try:
            with open(initial['profile']) as file:
                if json.load(file)['retroRewind']['version'] != initial['version']:
                    found.append('initial.profile is not for Retro Rewind ' + str(initial['version']))
        except (OSError, ValueError, KeyError, TypeError):
            found.append('initial.profile is not a readable KartPad profile: ' + initial['profile'])
    command = settings['buildCommand']
    if not isinstance(command, list) or not command or not all(isinstance(arg, str) for arg in command):
        found.append('buildCommand must be a non-empty list of arguments')
    environment = settings.get('environment', {})
    if not isinstance(environment, dict) or not all(isinstance(k, str) and isinstance(v, str) for k, v in environment.items()):
        found.append('environment must map names to strings')
    if 'app' in settings and absolute('app', settings['app']) and not settings['app'].endswith('.app'):
        found.append('app must name the installed KartPad.app')
    if 'reviewedProfile' in settings:
        url = urlparse(str(settings['reviewedProfile']))
        if url.scheme != 'https' or url.netloc != 'raw.githubusercontent.com':
            found.append('reviewedProfile must be an https://raw.githubusercontent.com/ address')
    return found


if __name__ == '__main__':
    if len(sys.argv) != 2:
        sys.exit(__doc__.split('\n')[2])
    try:
        with open(sys.argv[1]) as file:
            loaded = json.load(file)
    except (OSError, ValueError) as exc:
        sys.exit('local updater settings are unreadable: ' + str(exc))
    found = problems(loaded)
    if found:
        sys.exit('local updater settings: ' + '; '.join(found))
