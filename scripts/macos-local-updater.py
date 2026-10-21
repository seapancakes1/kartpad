#!/usr/bin/env python3
"""Opt-in local Mac updater: rebuild Retro Rewind off to the side, activate at next launch.

Standard library only; runs on Python 3.9 or newer (the stock macOS python3). See
docs/macos-local-auto-update.md for setup, the verification model and the state files."""
from __future__ import annotations
import argparse, contextlib, ctypes, errno, fcntl, hashlib, http.client, importlib.util, json, os, re, shutil, stat
import subprocess, sys, tempfile, threading, time, urllib.error, urllib.request, zipfile
from pathlib import Path, PurePosixPath
from urllib.parse import urlparse

sys.dont_write_bytecode=True  # a __pycache__ inside the signed app would break its signature

def _pins():
    """The maintainers' pinning script, bundled beside this one: feed URL and version order.
    Importing it reads nothing and opens no connection."""
    spec=importlib.util.spec_from_file_location('kartpad_retro_pins',Path(__file__).with_name('update-retro-rewind-profile.py'))
    module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
    return module
pins=_pins()

FEED = pins.VERSION_FEED
DELETIONS = FEED.replace('RetroRewindVersion.txt','RetroRewindDelete.txt')
CDN = 'https://cdn.update.rwfc.net/RetroRewind/zip/'
# The pack KartPad's maintainers last reviewed (version and hashes); settings may name a fork's copy.
REVIEW_HOST = 'raw.githubusercontent.com'
REVIEWED = 'https://'+REVIEW_HOST+'/chrissotraidis/kartpad/main/builder/profiles/mkwii-rmcp01-rev0.json'
MAX_ARCHIVE = 3_000_000_000
MAX_EXPANDED = 4_000_000_000
MIN_FREE = 8_000_000_000
TRIAL_LAUNCHES = 2  # unconfirmed launches a new app gets before it is rolled back
RETRYABLE_HTTP = {408, 425, 429, 500, 502, 503, 504}
# Failures that would only repeat until something changes; automatic checks skip them.
STICKY = ('build', 'verification', 'configuration', 'unverified', 'checkout')
STATE_FILES = ('active.json', 'pending.json', 'rollback.json', 'trial.json', 'installed.json')
PACK = ('version', 'root', 'profile', 'packVersion')  # what a pack record keeps
# The checkout's own profile: pulling the maintainers' support for a new Retro Rewind changes it.
CHECKOUT_PROFILE = 'builder/profiles/mkwii-rmcp01-rev0.json'
# Where a copy of the installed app is never taken for the app itself having moved.
NOT_MOVED = {'.Trash', '.Trashes', 'AppTranslocation'}
STAGE = re.compile(r'\d+(?:\.\d+){1,3}-\w+')
BACKUPS = 'Backups.noindex'  # previous apps, out of Applications (and Spotlight)
# What the player owns in the riivolution folder beside a pack: saves and Riivolution's option choices.
PLAYER_DATA = ('save', 'config')
NETWORK = (urllib.error.URLError, http.client.HTTPException, TimeoutError, ConnectionError)

class VerificationError(ValueError): pass
class StorageError(Exception): pass
class OutdatedCheckout(Exception):
    """A rebuild failed for a version the checkout's own profile doesn't support yet."""
class Unverified(VerificationError):
    """Files the maintainers haven't reviewed: never installed without the player's say-so."""
    def __init__(self, reason, message):
        super().__init__(message);self.reason=reason

def version(value):
    try:return pins.version_key(value)
    except (TypeError,ValueError):raise VerificationError('Invalid pack version') from None

def pack(item):
    return {key:item[key] for key in PACK if key in item}

def pack_version(item):
    """What a pack's version.txt says: its feed version, unless the release shipped a stale one
    (Retro Rewind 6.13.3's says 6.13.2), which the maintainers' review pins as packVersion."""
    return item.get('packVersion') or item['version']

def atomic_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix('.tmp')
    tmp.write_text(json.dumps(value, indent=2)+'\n')
    os.replace(tmp, path)

def load(path):
    return json.loads(path.read_text()) if path.exists() else None

def store(path, value):
    if value is None: path.unlink(missing_ok=True)
    else: atomic_json(path, value)

def digest(path):
    hasher=hashlib.sha256()
    with path.open('rb') as file:
        for chunk in iter(lambda:file.read(1<<20),b''):hasher.update(chunk)
    return hasher.hexdigest()

def length(response):
    headers = getattr(response, 'headers', None)
    return int(headers.get('Content-Length', '0')) if headers else 0

def source_host(url):
    """The one host each download may come from, redirects included."""
    if url in (FEED, DELETIONS): return 'update.rwfc.net'
    if url.startswith(CDN): return 'cdn.update.rwfc.net'
    return REVIEW_HOST

def fetch(url, maximum, offset=0):
    expected = source_host(url)
    if urlparse(url).scheme != 'https' or urlparse(url).netloc != expected:
        raise VerificationError('Update URL is outside the official sources')
    headers = {'User-Agent':'KartPad-Local-Updater/2'}
    if offset: headers['Range'] = f'bytes={offset}-'
    response = urllib.request.urlopen(urllib.request.Request(url, headers=headers), timeout=30)
    if urlparse(response.url).scheme != 'https' or urlparse(response.url).netloc != expected:
        response.close()
        raise VerificationError('Update redirected outside the official source')
    if offset + length(response) > maximum:
        response.close()
        raise VerificationError('Update exceeds the download limit')
    return response

def manifest(url):
    with fetch(url, 1_000_000) as response:
        text = response.read(1_000_001)
    if len(text) > 1_000_000: raise VerificationError('Manifest exceeds download limit')
    return text.decode()

def download(url, archive, report):
    """Retry transient failures, resuming from the bytes already on disk."""
    for attempt in range(4):
        offset = archive.stat().st_size if archive.exists() else 0
        try:
            with fetch(url, MAX_ARCHIVE, offset) as response:
                if offset and getattr(response, 'status', 200) != 206: offset = 0
                size = offset + length(response) if length(response) else 0
                total, last_report = offset, 0.0
                with archive.open('ab' if offset else 'wb') as out:
                    while chunk := response.read(1024*1024):
                        total += len(chunk)
                        if total > MAX_ARCHIVE: raise VerificationError('Update exceeds download limit')
                        out.write(chunk)
                        if time.monotonic()-last_report >= 0.5:
                            report(total, size); last_report = time.monotonic()
            if size and total != size: raise ConnectionError('Download ended early')
            return
        except NETWORK as exc:
            if isinstance(exc, urllib.error.HTTPError):
                if exc.code == 416: archive.unlink(missing_ok=True)
                elif exc.code not in RETRYABLE_HTTP: raise
            if attempt == 3: raise
            time.sleep(2**attempt)

def releases(text, installed):
    result = []
    for line in text.splitlines():
        parts = line.split()
        if not parts: continue
        key = version(parts[0])
        if len(parts) < 2 or not parts[1].startswith(CDN) or urlparse(parts[1]).netloc != 'cdn.update.rwfc.net':
            raise VerificationError('Invalid official update manifest')
        if key > version(installed): result.append((parts[0], parts[1]))
    return sorted(result, key=lambda item:version(item[0]))

def deletions(text, installed, latest):
    """Pack files the official updater removes, by the version that removes them."""
    result = {}
    for line in text.splitlines():
        parts = line.split()
        if not parts: continue
        if len(parts) < 2: raise VerificationError('Invalid official delete list')
        if not version(installed) < version(parts[0]) <= version(latest): continue
        # Other entries are the official updater's own downloads at the SD card root.
        if parts[1].rstrip('/') == '/RetroRewind6': raise VerificationError('Update removes the whole pack')
        if not parts[1].startswith('/RetroRewind6/'): continue
        relative = PurePosixPath(parts[1][len('/RetroRewind6/'):])
        if not relative.parts or '..' in relative.parts or '\\' in parts[1]:
            raise VerificationError('Unsafe path in the official delete list')
        result.setdefault(parts[0], []).append(relative)
    return result

def remove(root, paths):
    removed = 0
    for relative in paths:
        path = root/relative
        if not path.parent.resolve().is_relative_to(root.resolve()):
            raise VerificationError('Delete list path escapes the pack')
        if path.is_symlink() or path.is_file(): path.unlink(); removed += 1
        elif path.is_dir(): shutil.rmtree(path); removed += 1
    return removed

def extract(archive, target):
    with zipfile.ZipFile(archive) as bundle:
        entries = bundle.infolist()
        if len(entries)>20000 or sum(i.file_size for i in entries)>MAX_EXPANDED:
            raise VerificationError('Update exceeds extraction limits')
        seen = set()
        for info in entries:
            name=info.filename
            parts=Path(name).parts
            if not parts or name.startswith('/') or '..' in parts or '\\' in name or parts[0] not in ('RetroRewind6','riivolution'):
                raise VerificationError('Unsafe update path')
            if name in seen or stat.S_ISLNK(info.external_attr>>16) or info.flag_bits & 1:
                raise VerificationError('Unsupported update ZIP entry')
            seen.add(name)
            path=target/name
            if not path.resolve().is_relative_to(target.resolve()):
                raise VerificationError('Update path escapes its staging directory')
            if info.is_dir(): path.mkdir(parents=True, exist_ok=True)
            else:
                path.parent.mkdir(parents=True, exist_ok=True)
                with bundle.open(info) as src, path.open('wb') as dst:
                    shutil.copyfileobj(src, dst)

def clone(source, target):
    """APFS clones share unchanged blocks, so staged packs and apps cost little extra space."""
    try: subprocess.run(['/bin/cp','-cpR',str(source),str(target)],check=True,capture_output=True)
    except (OSError, subprocess.CalledProcessError):
        discard(target)
        if source.is_dir() and not source.is_symlink(): shutil.copytree(source,target,symlinks=True)
        else: shutil.copy2(source,target,follow_symlinks=False)

def discard(path):
    if path.is_symlink() or path.is_file(): path.unlink()
    elif path.exists(): shutil.rmtree(path)

def move(source, target):
    """Rename; between volumes, copy and then delete."""
    try: os.replace(source,target); return
    except OSError as exc:
        if exc.errno!=errno.EXDEV: raise
    partial=target.with_name(target.name+'.partial');discard(partial)
    clone(source,partial);os.replace(partial,target)
    # Out of the way first, so an interrupted delete never leaves half a bundle at the old name.
    gone=unused(source.with_name('.'+source.name+'.moved'));os.replace(source,gone)
    shutil.rmtree(gone,ignore_errors=True)

def unused(path):
    candidate,number=path,2
    while candidate.exists() or candidate.is_symlink():
        candidate=path.with_name(f'{path.stem}-{number}{path.suffix}');number+=1
    return candidate

def updated_config(text, root):
    updated,n = re.subn(r'^retro_rewind_root\s*=.*$', 'retro_rewind_root = '+json.dumps(str(root)),text,flags=re.M)
    if n!=1: raise ValueError('Cannot locate the configured Retro Rewind data path')
    return updated

def configured_root(config):
    """The pack the game uses now; a relative path is relative to the config's folder."""
    match=re.search(r'''^retro_rewind_root\s*=\s*("(?:[^"\\]|\\.)*"|'[^']*')''',config.read_text(),flags=re.M)
    if not match: return None
    value=match.group(1)
    try: text=value[1:-1] if value.startswith("'") else json.loads(value)
    except ValueError: return None
    return (config.parent/text) if text else None

def riivolution(root):
    return Path(root).parent/'riivolution'

def same(a, b):
    return os.path.realpath(a)==os.path.realpath(b)

def newest(folder):
    """When the player last saved beside a pack (0 when there is nothing)."""
    latest=0.0
    for name in PLAYER_DATA:
        if (folder/name).is_dir():
            for path in (folder/name).rglob('*'):
                if path.is_file() and not path.is_symlink(): latest=max(latest,path.stat().st_mtime)
    return latest

def carry_plan(source, target):
    """Bring the player's saves and options from beside one pack to beside another."""
    if same(source,target): return None
    names=[name for name in PLAYER_DATA if (source/name).exists()]
    if not names: return None
    return {'source':str(source),'target':str(target),'aside':str(target/'.kartpad-replaced'),
            'names':{name:(target/name).exists() or (target/name).is_symlink() for name in names}}

def carry(plan):
    source,target,aside=Path(plan['source']),Path(plan['target']),Path(plan['aside'])
    discard(aside)  # a finished carry's leftovers; an unfinished one was undone before this
    aside.mkdir(parents=True)
    for name,existed in plan['names'].items():
        if existed: os.replace(target/name,aside/name)
        partial=target/('.'+name+'.partial');discard(partial)
        clone(source/name,partial);os.replace(partial,target/name)

def uncarry(plan):
    target,aside=Path(plan['target']),Path(plan['aside'])
    for name,existed in plan['names'].items():
        discard(target/('.'+name+'.partial'))
        if (aside/name).exists() or (aside/name).is_symlink():
            discard(target/name);os.replace(aside/name,target/name)
        elif not existed: discard(target/name)
    discard(aside)

def run(command, settings, log):
    # Rebuild work starts at background priority so it doesn't compete with the game; watching()
    # lifts it while KartPad isn't racing. Set on the process: taskpolicy -b's can't be lifted.
    process = subprocess.Popen(command, cwd=settings['repo'], env={**os.environ, **settings.get('environment',{})}, stdout=log, stderr=subprocess.STDOUT)
    with contextlib.suppress(Exception): set_background(process.pid, True)
    if process.wait(): raise subprocess.CalledProcessError(process.returncode, command)

# Landmarks in the rebuild's log and how much of the rebuild is done at each. Translating the game
# code is about a fifth of it; compiling the translated code takes most of the rest.
TRANSLATING = b'[translator] Starting translation'
TRANSLATED = b'Generated validated private Retro Rewind native graph'
PACKAGED = b'Packaged KartPad:'
TRANSLATOR_PHASES = 14  # the base and mod phases the translator reports
PHASE = re.compile(rb"^\[translator\] (?:mod )?phase '", re.M)
NINJA = re.compile(rb'^\[(\d+)/(\d+)\] (?!Re-checking|Re-running)', re.M)  # not CMake's own steps

def build_progress(text):
    """The stage a rebuild is in and how much of it is done, from its log so far."""
    if PACKAGED in text: return 'packaging', 0.97
    if TRANSLATED in text:
        steps = NINJA.findall(text[text.index(TRANSLATED):])
        done, total = (int(steps[-1][0]), int(steps[-1][1])) if steps else (0, 1)
        return 'compiling', 0.28 + 0.67*min(1, done/max(total, 1))
    if TRANSLATING in text:
        return 'translating', 0.05 + 0.23*min(1, len(PHASE.findall(text))/TRANSLATOR_PHASES)
    return 'preparing', 0.0

BUILD_POLL = 2.0  # seconds between looks at the rebuild's log
REPACE = 8  # polls between re-applying the build's priority, for processes started meanwhile

def racing(state):
    """KartPad is running a race in its active window: it keeps its process ID in state/racing then."""
    try: pid = int((state/'racing').read_text())
    except (OSError, ValueError): return False
    try: os.kill(pid, 0)
    except ProcessLookupError: return False
    except PermissionError: pass
    return True

def descendants(pid):
    """Every process started under pid: the build's shells, ninja and the compilers."""
    table = subprocess.run(['/bin/ps', '-ax', '-o', 'pid=,ppid='], capture_output=True, text=True, check=True).stdout
    children = {}
    for line in table.split('\n'):
        if line.strip(): child, parent = map(int, line.split()); children.setdefault(parent, []).append(child)
    found, todo = [], [pid]
    while todo:
        for child in children.get(todo.pop(), ()): found.append(child); todo.append(child)
    return found

def set_background(pid, background):
    """PRIO_DARWIN_BG, as taskpolicy -b sets it: efficiency cores and throttled disk use. Processes a
    build starts later inherit it from their parent."""
    ctypes.CDLL(None, use_errno=True).setpriority(4, pid, 0x1000 if background else 0)  # PRIO_DARWIN_PROCESS

def pace(slow):
    for pid in descendants(os.getpid()): set_background(pid, slow)

@contextlib.contextmanager
def watching(path, state, report):
    """While the block runs: reports build_progress of the log at path every few seconds (it never
    goes backwards), and keeps the build at background priority only while KartPad is racing."""
    done = threading.Event(); last = [None, 0.0]
    def watch():
        slow, polls = None, 0
        while not done.wait(BUILD_POLL):
            polls += 1
            now = racing(state)
            if now != slow or (now and polls % REPACE == 0):
                slow = now
                with contextlib.suppress(Exception): pace(slow)
            try: name, fraction = build_progress(path.read_bytes())
            except OSError: continue
            fraction = round(max(fraction, last[1]), 3)
            if [name, fraction] != last:
                last[:] = [name, fraction]
                with contextlib.suppress(OSError): report(name, fraction)
    thread = threading.Thread(target=watch, daemon=True); thread.start()
    try: yield
    finally: done.set(); thread.join()

def error_kind(error):
    if isinstance(error,NETWORK):return 'network'
    if isinstance(error,StorageError) or getattr(error,'errno',None)==errno.ENOSPC:return 'storage'
    if isinstance(error,OutdatedCheckout):return 'checkout'
    if isinstance(error,subprocess.CalledProcessError):return 'build'
    if isinstance(error,Unverified):return 'unverified'
    if isinstance(error,(VerificationError,zipfile.BadZipFile)):return 'verification'
    return 'configuration'

def remember(state, error, version=None, url=None, **extra):
    kind=error_kind(error)
    previous=load(state/'failure.json') or {}
    count=previous.get('count',0)+1 if previous.get('kind')==kind else 1
    atomic_json(state/'failure.json',{'kind':kind,'version':version,'url':url,'count':count,'at':time.time(),'message':str(error),**extra})

def decided(state, name, version, url):
    """A per-version choice the player made: declined.json (went back) or approved.json (install unreviewed)."""
    data=load(state/name) or {}
    return data.get('version')==version and data.get('url') in (None,url)

def snapshot(state):
    return {name:load(state/name) for name in STATE_FILES}

def transaction(state, moves, config, replacement, updates, saves=None):
    """Carry saves, move app bundles, rewrite the config and state files as one journaled step."""
    journal={'moves':[[str(a),str(b)] for a,b in moves],'config':str(config),'originalConfig':config.read_text(),'previous':snapshot(state),'saves':saves}
    atomic_json(state/'activation.json',journal)
    try:
        if saves: carry(saves)
        for source,target in moves: move(source,target)
        if replacement is not None:
            tmp=config.with_name(config.name+'.update')
            tmp.write_text(replacement);shutil.copymode(config,tmp);os.replace(tmp,config)
        for name,value in updates.items(): store(state/name,value)
        (state/'activation.json').unlink()
    except BaseException:
        undo(state,journal)
        raise
    if saves: shutil.rmtree(saves['aside'],ignore_errors=True)

def undo(state, journal):
    for source,target in reversed(journal['moves']):
        source,target=Path(source),Path(target)
        discard(target.with_name(target.name+'.partial'))
        if target.exists() and not source.exists(): move(target,source)
    Path(journal['config']).write_text(journal['originalConfig'])
    if journal.get('saves'): uncarry(journal['saves'])
    for name,value in journal['previous'].items(): store(state/name,value)
    (state/'activation.json').unlink(missing_ok=True)

def recover(state):
    journal=state/'activation.json'
    if journal.exists(): undo(state,json.loads(journal.read_text()))

def prune(state, config):
    """Keep the active, pending and one previous version; remove anything older."""
    if (state/'activation.json').exists(): return
    keep=[Path(data[key]) for name in STATE_FILES for data in [load(state/name) or {}] for key in ('root','profile','app') if data.get(key)]
    playing=configured_root(config) if config.exists() else None
    if playing: keep.append(playing)
    latest=newest(riivolution(playing)) if playing else 0.0
    for stage in state.iterdir():
        if stage.is_dir() and STAGE.fullmatch(stage.name) and not any(path.is_relative_to(stage) for path in keep):
            # Saves newer than the ones the game uses now stay with their pack.
            if newest(stage/'pack/riivolution')>latest+1: continue
            shutil.rmtree(stage,ignore_errors=True)
    previous=(load(state/'rollback.json') or {}).get('app')
    for backup in (state/BACKUPS).glob('*'):
        if str(backup)!=previous: discard(backup)

def tidy(app):
    """Leftovers beside the installed app: a rolled-back app (once it has quit) and interrupted moves."""
    for leftover in [*app.parent.glob('.'+app.stem+'.rolled-back*.app'),*app.parent.glob('.'+app.name+'*.moved'),app.with_name(app.name+'.partial')]:
        if leftover.exists(): shutil.rmtree(leftover,ignore_errors=True)

def reject(state, pending, error):
    """Drop a pending build that can't be installed so it never blocks later updates."""
    stage=Path(pending.get('app','')).parent
    if stage.parent==state and STAGE.fullmatch(stage.name): shutil.rmtree(stage,ignore_errors=True)
    (state/'pending.json').unlink(missing_ok=True)
    remember(state,error,pending.get('version'),pending.get('url'))

def other_copy(state, settings, app):
    """A backup or any other copy of KartPad: it leaves the updater's state alone."""
    expected=settings.get('app') or (load(state/'installed.json') or {}).get('app')
    return bool(expected) and not same(expected,app)

_digests={}
def identity(app, version):
    binary=app/'Contents/MacOS/KartPad';info=binary.stat()
    key=(str(binary),info.st_size,info.st_mtime_ns)
    if key not in _digests: _digests[key]=digest(binary)
    return {'app':str(app),'version':version,'runtimeSha256':_digests[key]}

def moved(state, settings, app):
    """Whether app is the installed app moved or renamed: the same build, with no app left where it
    was recorded. Not a copy in the Trash, one macOS runs from a temporary place, or a backup in the
    state folder; settings that name the app keep it where they say."""
    record=load(state/'installed.json') or {};recorded=record.get('app')
    if settings.get('app') or not recorded or same(recorded,app) or (Path(recorded)/'Contents/MacOS/KartPad').exists(): return False
    real=Path(os.path.realpath(app))
    if NOT_MOVED&set(real.parts) or real.is_relative_to(os.path.realpath(state)): return False
    return (app/'Contents/MacOS/KartPad').is_file() and identity(app,record.get('version'))['runtimeSha256']==record.get('runtimeSha256')

def follow(state, settings, app):
    """Record the installed app at its new place, so it keeps updating after a move."""
    if moved(state,settings,app): atomic_json(state/'installed.json',{**load(state/'installed.json'),'app':str(app)})

def recognised(state, app, version):
    """Whether this is the app the updater installed (or took as its starting point)."""
    record=load(state/'installed.json')
    return record is not None and record.get('version')==version and record.get('runtimeSha256')==identity(app,version)['runtimeSha256']

def staged_pack(state, version):
    """A pack of this version that an earlier update left in the state folder."""
    previous=load(state/'rollback.json') or {}
    if previous.get('version')==version and previous.get('root'): return pack(previous)
    for stage in sorted((p for p in state.iterdir() if p.is_dir() and STAGE.fullmatch(p.name)),key=lambda p:p.stat().st_mtime,reverse=True):
        root=stage/'pack/RetroRewind6'
        if not (root/'version.txt').is_file() or not (stage/'profile.json').is_file(): continue
        profile=load(stage/'profile.json').get('retroRewind',{})
        found=pack({'version':version,'root':str(root),'profile':str(stage/'profile.json'),**{k:profile[k] for k in ('packVersion',) if k in profile}})
        if profile.get('version',version)==version and (root/'version.txt').read_text().strip()==pack_version(found): return found
    return None

def adopt(state, settings, app, config, version, quiet):
    """Take an app the updater didn't install as its new starting point: the first launch with the
    updater, or a package built by hand. Returns 'deferred' when the game would need other files and
    is running (quiet is False), 'moved' when it pointed the game at other files, else 'recorded'."""
    initial=settings['initial'];active=load(state/'active.json');current=active or initial
    record=load(state/'installed.json');playing=configured_root(config)
    if version==current['version']: target=current
    else: target=initial if version==initial['version'] else staged_pack(state,version)
    # The game must use the pack of the app's own version: the original one, or an earlier update's.
    move_to=target if target is not current and target is not None and playing and not same(playing,target['root']) else None
    if move_to and not quiet: return 'deferred'
    updates={'installed.json':identity(app,version)}
    if record is not None or target is not current:
        # Another app now: the update built for the old one, and its trial, no longer apply.
        updates.update({'pending.json':None,'trial.json':None})
    if target is not current:
        updates['rollback.json']=None
        if target is not None: updates['active.json']=None if target is initial else pack(target)
    pending=load(state/'pending.json') if 'pending.json' in updates else None
    replacement=updated_config(config.read_text(),Path(move_to['root'])) if move_to else None
    transaction(state,[],config,replacement,updates,carry_plan(riivolution(playing),riivolution(move_to['root'])) if move_to else None)
    if pending and Path(pending.get('app','')).parent.parent==state: shutil.rmtree(pending['app'],ignore_errors=True)
    prune(state,config)
    return 'moved' if move_to else 'recorded'

def activate(state, app, config, verify, initial):
    pending=load(state/'pending.json')
    if pending is None: return False
    staged=app.with_name('.'+app.stem+'.update.app')
    try:
        candidate=Path(pending['app']);root=Path(pending['root'])
        if digest(candidate/'Contents/MacOS/KartPad') != pending['runtimeSha256']:
            raise VerificationError('Pending app integrity check failed')
        verify(candidate)
        if (root/'version.txt').read_text().strip()!=pack_version(pending):
            raise VerificationError('Pending pack version changed')
        profile=json.loads(Path(pending['profile']).read_text())['retroRewind']
        for key in ('codePul','riivolutionXml'):
            if digest(root/profile[key]['path'])!=profile[key]['sha256']:
                raise VerificationError('Pending pack integrity check failed')
        replacement=updated_config(config.read_text(),root)
        # A copy without a journal was never installed; it is left over from an interrupted copy.
        if staged.exists(): shutil.rmtree(staged)
        clone(candidate,staged)
        verify(staged)
    except Exception as exc:
        if staged.exists(): shutil.rmtree(staged)
        if error_kind(exc)!='storage': reject(state,pending,exc)
        raise
    previous=load(state/'active.json')
    current=previous or initial
    (state/BACKUPS).mkdir(parents=True,exist_ok=True)
    backup=unused(state/BACKUPS/(app.stem+'-'+current['version']+'.app'))
    # Saves come from where the game has been playing up to now, not from when the build began.
    saves=carry_plan(riivolution(configured_root(config) or current['root']),riivolution(root))
    try:
        transaction(state,[(app,backup),(staged,app)],config,replacement,{
            'active.json':pack(pending),
            'pending.json':None,
            'rollback.json':{**pack(current),'app':str(backup),
                             'replaces':pending['version'],'active':previous,'installed':load(state/'installed.json')},
            'trial.json':{'version':pending['version'],'launches':0},
            'installed.json':{'app':str(app),'version':pending['version'],'runtimeSha256':pending['runtimeSha256']}},saves)
    except Exception as exc:
        # The transaction restored the previous app; keep the build only if space ran out,
        # and leave everything alone while an unfinished undo still needs it.
        if error_kind(exc)!='storage' and not (state/'activation.json').exists(): reject(state,pending,exc)
        raise
    shutil.rmtree(candidate,ignore_errors=True)
    for name in ('failure.json','approved.json'): (state/name).unlink(missing_ok=True)
    if (load(state/'declined.json') or {}).get('version')==pending['version']: (state/'declined.json').unlink()
    prune(state,config)
    return True

def rollback(state, app, config, verify, reason):
    target=load(state/'rollback.json')
    if target is None: raise ValueError('No previous version is available to restore')
    backup=Path(target['app']);root=Path(target['root'])
    verify(backup)
    if (root/'version.txt').read_text().strip()!=pack_version(target):
        raise VerificationError('The previous game files changed')
    replacement=updated_config(config.read_text(),root)
    discarded=unused(app.with_name('.'+app.stem+'.rolled-back.app'))
    restored=target.get('installed') or {'version':target['version'],'runtimeSha256':digest(backup/'Contents/MacOS/KartPad')}
    playing=configured_root(config) or Path((load(state/'active.json') or {}).get('root') or root)
    # Progress made on the newer version goes back with the player.
    transaction(state,[(app,discarded),(backup,app)],config,replacement,
                {'active.json':target.get('active'),'rollback.json':None,'trial.json':None,'installed.json':{**restored,'app':str(app)}},
                carry_plan(riivolution(playing),riivolution(root)))
    # The discarded app may be the running process; the next check removes it.
    atomic_json(state/'declined.json',{'version':target['replaces'],'url':None,'at':time.time()})
    atomic_json(state/'status.json',{'phase':'rolledBack','version':target['version'],'from':target['replaces'],'reason':reason,'checkedAt':time.time()})
    prune(state,config)
    return True

def trial(state, app, config, verify, installed):
    """Count launches of a newly installed app until it shows it can run."""
    data=load(state/'trial.json')
    if data is None: return False
    if data.get('version')!=installed:
        (state/'trial.json').unlink();return False
    if data.get('launches',0)>=TRIAL_LAUNCHES:
        try: return rollback(state,app,config,verify,'unstable')
        except Exception:
            (state/'trial.json').unlink(missing_ok=True)  # report once rather than on every launch
            raise
    atomic_json(state/'trial.json',{**data,'launches':data.get('launches',0)+1})
    return False

@contextlib.contextmanager
def locked(state, wait=0.0):
    state.mkdir(parents=True,exist_ok=True)
    deadline=time.monotonic()+wait
    with (state/'lock').open('w') as file:
        while True:
            try: fcntl.flock(file,fcntl.LOCK_EX|fcntl.LOCK_NB);break
            except BlockingIOError:
                if time.monotonic()>=deadline: yield False;return
                time.sleep(.2)
        yield True

def backoff(failure):
    return min(600*2**(failure.get('count',1)-1),21600)

def pinned(item, path=False):
    if not isinstance(item,dict) or not isinstance(item.get('bytes'),int) or item['bytes']<=0 or not re.fullmatch(r'[0-9a-f]{64}',str(item.get('sha256'))):
        raise ValueError('incomplete pin')
    if path and (not isinstance(item.get('path'),str) or PurePosixPath(item['path']).is_absolute() or '..' in PurePosixPath(item['path']).parts):
        raise ValueError('unsafe pinned path')
    if not path and not str(item.get('url','')).startswith(CDN): raise ValueError('unofficial pinned archive')

def reviewed(settings):
    """The maintainers' reviewed pin: the Retro Rewind version KartPad supports and the hashes it has."""
    url=settings.get('reviewedProfile',REVIEWED)
    if not isinstance(url,str) or urlparse(url).scheme!='https' or urlparse(url).netloc!=REVIEW_HOST:
        raise VerificationError('The reviewed profile must come from '+REVIEW_HOST)
    try:
        pin=json.loads(manifest(url))['retroRewind'];version(pin['version'])
        for key in ('codePul','riivolutionXml'): pinned(pin[key],path=True)
        for key in ('archive','updateArchive'):
            if key in pin: pinned(pin[key])
    except (KeyError,TypeError,ValueError) as exc:
        raise VerificationError('The reviewed Retro Rewind profile is invalid') from exc
    return pin

def fingerprint(pin):
    return hashlib.sha256(json.dumps(pin,sort_keys=True).encode()).hexdigest() if pin else None

def checkout(settings):
    """The Retro Rewind version the checkout's own profile supports, and that profile's digest."""
    path=Path(settings.get('repo',''))/CHECKOUT_PROFILE
    try: return json.loads(path.read_text())['retroRewind']['version'],digest(path)
    except (OSError,ValueError,KeyError,TypeError): return None,None

def unverified(state, version, reason, pin, message=''):
    atomic_json(state/'status.json',{'phase':'unverified','version':version,'reason':reason,'reviewed':pin and pin['version'],'message':message,'checkedAt':time.time()})

def check(settings, installed, state, app, force=False, allow_declined=False, allow_unverified=None):
    target={}
    try: build(settings,installed,state,app,force,allow_declined,allow_unverified,target)
    except Unverified as exc:
        # Remembered against this review: a new pin from the maintainers is worth another try.
        remember(state,exc,target.get('version'),target.get('url'),pin=fingerprint(target.get('pin')))
        unverified(state,target.get('version'),exc.reason,target.get('pin'),str(exc))
    except Exception as exc:
        # Remembered against this checkout too: pulling a new profile is worth another try.
        remember(state,exc,target.get('version'),target.get('url'),checkout=checkout(settings)[1])
        raise

def build(settings, installed, state, app, force, allow_declined, allow_unverified, target):
    if (state/'pending.json').exists() or (state/'activation.json').exists(): return
    config=Path(settings['config'])
    prune(state,config)
    tidy(app)
    failure=load(state/'failure.json') or {}
    if not force and failure.get('kind')=='network' and time.time()<failure.get('at',0)+backoff(failure): return
    active=load(state/'active.json') or settings['initial']
    if active['version']!=installed: raise ValueError('Updater settings do not match this app version')
    source=Path(active['root'])
    if (source/'version.txt').read_text().strip()!=pack_version(active): raise ValueError('Installed pack does not match this app')
    profile=json.loads(Path(active['profile']).read_text())
    for key in ('codePul','riivolutionXml'):
        item=profile['retroRewind'][key]
        if digest(source/item['path'])!=item['sha256']:raise VerificationError('Installed pack integrity check failed')
    updates=releases(manifest(FEED),installed)
    if not updates:
        (state/'failure.json').unlink(missing_ok=True)
        atomic_json(state/'status.json',{'phase':'current','version':installed,'checkedAt':time.time()});return
    latest,latest_url=updates[-1];target.update(version=latest,url=latest_url)
    if decided(state,'declined.json',latest,latest_url):
        if not allow_declined:
            if force: atomic_json(state/'status.json',{'phase':'declined','version':latest,'checkedAt':time.time()})
            return
        (state/'declined.json').unlink()  # the player changed their mind
    sticky=not force and failure.get('kind') in STICKY and failure.get('version')==latest and failure.get('url') in (None,latest_url)
    if sticky and failure['kind']!='unverified' and failure.get('checkout') in (None,checkout(settings)[1]): return
    if allow_unverified==latest: atomic_json(state/'approved.json',{'version':latest,'url':latest_url,'at':time.time()})
    approved=decided(state,'approved.json',latest,latest_url)
    # It installs only as the maintainers reviewed it, unless the player approved this version.
    pin=reviewed(settings);target['pin']=pin
    if pin['version']!=latest:
        if not approved: unverified(state,latest,'unreviewed',pin);return
        pin=None
    # A mismatch is tried again when the maintainers publish a new review, or when asked to.
    if sticky and not approved and failure.get('pin')==fingerprint(pin): return
    def mismatch(message):
        if not approved: raise Unverified('mismatch',message)
    def status(**fields):
        atomic_json(state/'status.json',{'phase':'building','version':latest,'pid':os.getpid(),'checkedAt':time.time(),**fields})
    status(step='preparing')
    if shutil.disk_usage(state).free<MIN_FREE:raise StorageError('At least 8 GB of free disk space is needed to rebuild')
    removals=deletions(manifest(DELETIONS),installed,latest)
    archives={item['url']:item for item in (pin.get('archive'),pin.get('updateArchive')) if item} if pin else {}
    stage=Path(tempfile.mkdtemp(prefix=latest+'-',dir=state))
    try:
        pack=stage/'pack';pack.mkdir()
        # Refuse links in source data before copying into the writable extraction tree.
        if any(p.is_symlink() for p in source.rglob('*')):raise VerificationError('Pack contains symbolic links')
        root=pack/'RetroRewind6';clone(source,root)
        records=[]
        for number,(patch_version,url) in enumerate(updates):
            progress={'step':'downloading','patchIndex':number+1,'patchCount':len(updates)}
            status(**progress)
            archive=stage/f'patch-{number}.zip'
            download(url,archive,lambda done,size:status(**progress,downloadedBytes=done,totalBytes=size))
            status(**{**progress,'step':'extracting'})
            records.append({'version':patch_version,'url':url,'bytes':archive.stat().st_size,'sha256':digest(archive)})
            if url in archives:
                records[-1]['reviewed']=(records[-1]['bytes'],records[-1]['sha256'])==(archives[url]['bytes'],archives[url]['sha256'])
                if not records[-1]['reviewed']: mismatch(Path(urlparse(url).path).name+' differs from the reviewed download')
            extract(archive,pack)
            archive.unlink()
            records[-1]['deleted']=remove(root,removals.pop(patch_version,[]))
        # Deletions listed for a version without its own patch still apply, in version order.
        for patch_version in sorted(removals,key=version):remove(root,removals[patch_version])
        expected=pin.get('packVersion',latest) if pin else latest
        if (root/'version.txt').read_text().strip()!=expected:raise VerificationError('Updated pack version does not match the manifest')
        matched=pin is not None
        if pin is not None:
            # The program code and patch list decide what gets translated: both must be the reviewed ones.
            for key in ('codePul','riivolutionXml'):
                item=pin[key];file=root/item['path']
                if item['path']!=profile['retroRewind'][key]['path'] or not file.is_file() or (file.stat().st_size,digest(file))!=(item['bytes'],item['sha256']):
                    matched=False;mismatch(item['path']+' differs from the reviewed Retro Rewind '+latest)
        if matched:
            for key in ('archive','updateArchive'):
                if key in pin: profile['retroRewind'][key]=pin[key]
                else: profile['retroRewind'].pop(key,None)
        profile['retroRewind']['version']=latest
        if expected!=latest: profile['retroRewind']['packVersion']=expected
        else: profile['retroRewind'].pop('packVersion',None)
        for key in ('codePul','riivolutionXml'):
            item=profile['retroRewind'][key];file=root/item['path']
            item.update(bytes=file.stat().st_size,sha256=digest(file))
        profile['localBuildUpdates']=profile.get('localBuildUpdates',[])+[{**record,'packReviewed':matched} for record in records]
        local_profile=stage/'profile.json';atomic_json(local_profile,profile)
        candidate=stage/'KartPad.app'
        command=[arg.replace('{root}',str(root)).replace('{profile}',str(local_profile)).replace('{app}',str(candidate)) for arg in settings['buildCommand']]
        status(step='compiling',buildStage='preparing',progress=0.0)
        with (stage/'build.log').open('w') as log:
            try:
                with watching(stage/'build.log',state,lambda name,done:status(step='compiling',buildStage=name,progress=done)):
                    run(command,settings,log)
            except subprocess.CalledProcessError as exc:
                # A version newer than the checkout's own profile usually needs the maintainers' changes too.
                supported=checkout(settings)[0]
                if supported and version(supported)<version(latest):
                    raise OutdatedCheckout(f'Retro Rewind {latest} needs a newer KartPad checkout (it has {supported})') from exc
                raise
        status(step='verifying',progress=0.98)
        binary=(candidate/'Contents/MacOS/KartPad').read_bytes()
        if any(profile['retroRewind'][key]['sha256'].encode() not in binary for key in ('codePul','riivolutionXml')):
            raise VerificationError('Rebuilt app does not validate the new pack fingerprint')
        # Without the helper the new app would quietly stop updating (the audit checks it is current).
        if not (candidate/'Contents/Resources/LocalUpdater/updater.py').is_file():
            raise VerificationError('Rebuilt app lacks the local updater; the build must set KARTPAD_LOCAL_UPDATER_SETTINGS')
        with (stage/'build.log').open('a') as log:
            run(['/usr/bin/codesign','--force','--deep','--sign','-','--entitlements',settings['repo']+'/apple/macos/KartPad.entitlements',str(candidate)],settings,log)
            run([settings['repo']+'/scripts/audit-macos-package.sh',str(candidate),'dual'],settings,log)
        atomic_json(state/'pending.json',{'version':latest,'url':latest_url,'root':str(root),'profile':str(local_profile),'app':str(candidate),'runtimeSha256':digest(candidate/'Contents/MacOS/KartPad'),'reviewed':matched,**({'packVersion':expected} if expected!=latest else {})})
        (state/'failure.json').unlink(missing_ok=True)
        atomic_json(state/'status.json',{'phase':'ready','version':latest,'checkedAt':time.time()})
    except Exception:
        if (stage/'build.log').exists(): shutil.copy2(stage/'build.log',state/'last-build.log')
        shutil.rmtree(stage)
        raise

def exited(pid):
    for _ in range(1200):
        try:os.kill(pid,0)
        except ProcessLookupError:return True
        time.sleep(.1)
    return False

def relaunch(app, version, pid):
    """Reopen the app at this path once the current process exits."""
    script=app/'Contents/Resources/LocalUpdater/updater.py'
    subprocess.Popen([sys.executable,'-I','-B',str(script),'relaunch','--settings',str(app/'Contents/Resources/LocalUpdater/settings.json'),'--app',str(app),'--version',version,'--pid',str(pid)],start_new_session=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)

def failed(state, exc):
    atomic_json(state/'status.json',{'phase':'error','errorKind':error_kind(exc),'message':str(exc),'checkedAt':time.time()})

def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('action',choices=('check','activate','finish','relaunch'))
    parser.add_argument('--settings',type=Path,required=True)
    parser.add_argument('--app',type=Path,required=True)
    parser.add_argument('--version',required=True)
    parser.add_argument('--pid',type=int)
    parser.add_argument('--then',choices=('activate','rollback','none'),default='none')
    parser.add_argument('--force',action='store_true')
    parser.add_argument('--allow-declined',action='store_true')
    parser.add_argument('--allow-unverified',metavar='VERSION')
    args=parser.parse_args();settings=json.loads(args.settings.read_text());state=Path(settings['state'])
    config=Path(settings['config'])
    verify=lambda path:subprocess.run(['/usr/bin/codesign','--verify','--deep','--strict',str(path)],check=True,capture_output=True)
    if args.action in ('finish','relaunch'):
        if not exited(args.pid):return 1
        # Installing after the old process exits means only one relaunch, and no running bundle is replaced.
        if args.then!='none':
            with locked(state,wait=15) as acquired:
                try:
                    if not acquired:raise ValueError('Another update task is still running')
                    follow(state,settings,args.app)
                    if not other_copy(state,settings,args.app):
                        recover(state)
                        if not recognised(state,args.app,args.version):adopt(state,settings,args.app,config,args.version,True)
                        if args.then=='activate' and activate(state,args.app,config,verify,settings['initial']):
                            atomic_json(state/'status.json',{'phase':'installed','version':load(state/'active.json')['version'],'checkedAt':time.time()})
                        elif args.then=='rollback':rollback(state,args.app,config,verify,'manual')
                except Exception as exc:
                    failed(state,exc)
        subprocess.run(['/usr/bin/open','-n',str(args.app)],check=True);return 0
    with locked(state) as acquired:
        if not acquired:return 0
        try:
            # Only the installed app acts, wherever it was moved; a backup or other copy that opens
            # leaves everything alone.
            follow(state,settings,args.app)
            if other_copy(state,settings,args.app):return 0
            if args.action=='activate':
                recover(state)
                if not recognised(state,args.app,args.version) and adopt(state,settings,args.app,config,args.version,True)=='moved':
                    relaunch(args.app,args.version,args.pid);return 10
                if activate(state,args.app,config,verify,settings['initial']):
                    atomic_json(state/'status.json',{'phase':'installed','version':load(state/'active.json')['version'],'checkedAt':time.time()})
                    relaunch(args.app,args.version,args.pid);return 10
                if trial(state,args.app,config,verify,args.version):
                    relaunch(args.app,args.version,args.pid);return 10
            else:
                if (state/'activation.json').exists():return 0
                # Pointing the game at other files waits for the next launch, before they open.
                if not recognised(state,args.app,args.version) and adopt(state,settings,args.app,config,args.version,False)=='deferred':return 0
                check(settings,args.version,state,args.app,args.force,args.allow_declined,args.allow_unverified)
        except Exception as exc:
            failed(state,exc)
            return 1
    return 0

if __name__=='__main__':sys.exit(main())
