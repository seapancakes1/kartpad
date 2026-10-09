#!/usr/bin/env python3
"""Opt-in local Mac updater: rebuild off to the side, activate at next launch."""
from __future__ import annotations
import argparse, contextlib, errno, fcntl, hashlib, http.client, json, os, re, shutil, stat
import subprocess, sys, tempfile, time, urllib.error, urllib.request, zipfile
from pathlib import Path, PurePosixPath
from urllib.parse import urlparse

FEED = 'https://update.rwfc.net/RetroRewind/RetroRewindVersion.txt'
DELETIONS = 'https://update.rwfc.net/RetroRewind/RetroRewindDelete.txt'
CDN = 'https://cdn.update.rwfc.net/RetroRewind/zip/'
MAX_ARCHIVE = 3_000_000_000
MAX_EXPANDED = 4_000_000_000
MIN_FREE = 8_000_000_000
TRIAL_LAUNCHES = 2  # unconfirmed launches a new app gets before it is rolled back
RETRYABLE_HTTP = {408, 425, 429, 500, 502, 503, 504}
# Failures that would only repeat until something changes; automatic checks skip them.
STICKY = ('build', 'verification', 'configuration', 'declined')
STATE_FILES = ('active.json', 'pending.json', 'rollback.json', 'trial.json')
STAGE = re.compile(r'\d+(?:\.\d+){1,3}-\w+')
NETWORK = (urllib.error.URLError, http.client.HTTPException, TimeoutError, ConnectionError)

class VerificationError(ValueError): pass
class StorageError(Exception): pass

def version(value):
    if not re.fullmatch(r'\d+(?:\.\d+){1,3}', value):
        raise VerificationError('Invalid pack version')
    return tuple(map(int, value.split('.')))

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
    with path.open('rb') as file:
        return hashlib.file_digest(file, 'sha256').hexdigest()

def length(response):
    headers = getattr(response, 'headers', None)
    return int(headers.get('Content-Length', '0')) if headers else 0

def fetch(url, maximum, offset=0):
    expected = 'update.rwfc.net' if url in (FEED, DELETIONS) else 'cdn.update.rwfc.net'
    if urlparse(url).scheme != 'https' or urlparse(url).netloc != expected:
        raise VerificationError('Update URL is outside the official feed')
    headers = {'User-Agent':'KartPad-Local-Updater/1'}
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
        if target.exists(): shutil.rmtree(target)
        shutil.copytree(source,target,symlinks=True)

def unused(path):
    candidate,number=path,2
    while candidate.exists() or candidate.is_symlink():
        candidate=path.with_name(f'{path.stem}-{number}{path.suffix}');number+=1
    return candidate

def updated_config(text, root):
    updated,n = re.subn(r'^retro_rewind_root\s*=.*$', 'retro_rewind_root = '+json.dumps(str(root)),text,flags=re.M)
    if n!=1: raise ValueError('Cannot locate the configured Retro Rewind data path')
    return updated

def run(command, settings, log):
    # Rebuild work runs at background priority so it doesn't compete with the game.
    subprocess.run(['/usr/sbin/taskpolicy','-b',*command], cwd=settings['repo'], env={**os.environ, **settings.get('environment',{})}, stdout=log, stderr=subprocess.STDOUT, check=True)

def error_kind(error):
    if isinstance(error,NETWORK):return 'network'
    if isinstance(error,StorageError) or getattr(error,'errno',None)==errno.ENOSPC:return 'storage'
    if isinstance(error,subprocess.CalledProcessError):return 'build'
    if isinstance(error,(VerificationError,zipfile.BadZipFile)):return 'verification'
    return 'configuration'

def remember(state, error, version=None, url=None):
    kind=error if isinstance(error,str) else error_kind(error)
    previous=load(state/'failure.json') or {}
    count=previous.get('count',0)+1 if previous.get('kind')==kind else 1
    atomic_json(state/'failure.json',{'kind':kind,'version':version,'url':url,'count':count,'at':time.time(),'message':str(error)})

def snapshot(state):
    return {name:load(state/name) for name in STATE_FILES}

def transaction(state, moves, config, replacement, updates):
    """Move app bundles, rewrite the config and state files as one journaled step."""
    journal={'moves':[[str(a),str(b)] for a,b in moves],'config':str(config),'originalConfig':config.read_text(),'previous':snapshot(state)}
    atomic_json(state/'activation.json',journal)
    try:
        for source,target in moves: os.replace(source,target)
        tmp=config.with_name(config.name+'.update')
        tmp.write_text(replacement);shutil.copymode(config,tmp);os.replace(tmp,config)
        for name,value in updates.items(): store(state/name,value)
        (state/'activation.json').unlink()
    except BaseException:
        undo(state,journal)
        raise

def undo(state, journal):
    if 'moves' not in journal:  # journal written by the first updater release
        journal={'moves':[[journal['app'],journal['backup']],[journal['staged'],journal['app']]],'config':journal['config'],
                 'originalConfig':journal['originalConfig'],'previous':{'active.json':journal.get('previousActive'),'pending.json':journal['pending']}}
    for source,target in reversed(journal['moves']):
        source,target=Path(source),Path(target)
        if target.exists() and not source.exists(): os.replace(target,source)
    Path(journal['config']).write_text(journal['originalConfig'])
    for name,value in journal['previous'].items(): store(state/name,value)
    (state/'activation.json').unlink(missing_ok=True)

def recover(state):
    journal=state/'activation.json'
    if journal.exists(): undo(state,json.loads(journal.read_text()))

def prune(state, app):
    """Keep the active, pending and one previous version; remove anything older."""
    if (state/'activation.json').exists(): return
    keep=[Path(data[key]) for name in STATE_FILES for data in [load(state/name) or {}] for key in ('root','profile','app') if data.get(key)]
    for stage in state.iterdir():
        if stage.is_dir() and STAGE.fullmatch(stage.name) and not any(path.is_relative_to(stage) for path in keep):
            shutil.rmtree(stage,ignore_errors=True)
    previous=(load(state/'rollback.json') or {}).get('app')
    for backup in app.parent.glob(app.stem+'.before-*.app'):
        if str(backup)!=previous: shutil.rmtree(backup,ignore_errors=True)

def reject(state, pending, error):
    """Drop a pending build that can't be installed so it never blocks later updates."""
    stage=Path(pending.get('app','')).parent
    if stage.parent==state and STAGE.fullmatch(stage.name): shutil.rmtree(stage,ignore_errors=True)
    (state/'pending.json').unlink(missing_ok=True)
    remember(state,error,pending.get('version'),pending.get('url'))

def activate(state, app, config, verify, initial):
    pending=load(state/'pending.json')
    if pending is None: return False
    staged=app.with_name('.'+app.stem+'.update.app')
    try:
        candidate=Path(pending['app']);root=Path(pending['root'])
        if digest(candidate/'Contents/MacOS/KartPad') != pending['runtimeSha256']:
            raise VerificationError('Pending app integrity check failed')
        verify(candidate)
        if (root/'version.txt').read_text().strip()!=pending['version']:
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
    backup=unused(app.with_name(app.stem+'.before-'+pending['version']+'.app'))
    try:
        transaction(state,[(app,backup),(staged,app)],config,replacement,{
            'active.json':{'version':pending['version'],'root':pending['root'],'profile':pending['profile']},
            'pending.json':None,
            'rollback.json':{'version':current['version'],'root':current['root'],'profile':current['profile'],'app':str(backup),'replaces':pending['version'],'active':previous},
            'trial.json':{'version':pending['version'],'launches':0}})
    except Exception as exc:
        # The transaction restored the previous app; keep the build only if space ran out,
        # and leave everything alone while an unfinished undo still needs it.
        if error_kind(exc)!='storage' and not (state/'activation.json').exists(): reject(state,pending,exc)
        raise
    shutil.rmtree(candidate,ignore_errors=True)
    (state/'failure.json').unlink(missing_ok=True)
    prune(state,app)
    return True

def rollback(state, app, config, verify, reason):
    target=load(state/'rollback.json')
    if target is None: raise ValueError('No previous version is available to restore')
    backup=Path(target['app']);root=Path(target['root'])
    verify(backup)
    if (root/'version.txt').read_text().strip()!=target['version']:
        raise VerificationError('The previous game files changed')
    replacement=updated_config(config.read_text(),root)
    discard=unused(app.with_name('.'+app.stem+'.rolled-back.app'))
    transaction(state,[(app,discard),(backup,app)],config,replacement,
                {'active.json':target.get('active'),'rollback.json':None,'trial.json':None})
    # The discarded app may be the running process; the next check removes it.
    remember(state,'declined',target['replaces'])
    atomic_json(state/'status.json',{'phase':'rolledBack','version':target['version'],'from':target['replaces'],'reason':reason,'checkedAt':time.time()})
    prune(state,app)
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

def check(settings, installed, state, app, force=False, allow_declined=False):
    target={}
    try: build(settings,installed,state,app,force,allow_declined,target)
    except Exception as exc:
        remember(state,exc,target.get('version'),target.get('url'))
        raise

def build(settings, installed, state, app, force, allow_declined, target):
    if (state/'pending.json').exists() or (state/'activation.json').exists(): return
    prune(state,app)
    for leftover in app.parent.glob('.'+app.stem+'.rolled-back*.app'): shutil.rmtree(leftover,ignore_errors=True)
    failure=load(state/'failure.json') or {}
    if not force and failure.get('kind')=='network' and time.time()<failure.get('at',0)+backoff(failure): return
    active=load(state/'active.json') or settings['initial']
    if active['version']!=installed: raise ValueError('Updater settings do not match this app version')
    source=Path(active['root'])
    if (source/'version.txt').read_text().strip()!=installed: raise ValueError('Installed pack does not match this app')
    profile=json.loads(Path(active['profile']).read_text())
    for key in ('codePul','riivolutionXml'):
        item=profile['retroRewind'][key]
        if digest(source/item['path'])!=item['sha256']:raise VerificationError('Installed pack integrity check failed')
    updates=releases(manifest(FEED),installed)
    if not updates:
        (state/'failure.json').unlink(missing_ok=True)
        atomic_json(state/'status.json',{'phase':'current','version':installed,'checkedAt':time.time()});return
    latest,latest_url=updates[-1];target.update(version=latest,url=latest_url)
    if failure.get('kind') in STICKY and failure.get('version')==latest and failure.get('url') in (None,latest_url):
        if failure['kind']=='declined' and force and not allow_declined:
            atomic_json(state/'status.json',{'phase':'declined','version':latest,'checkedAt':time.time()});return
        if not force: return
    def status(**fields):
        atomic_json(state/'status.json',{'phase':'building','version':latest,'pid':os.getpid(),'checkedAt':time.time(),**fields})
    status(step='preparing')
    if shutil.disk_usage(state).free<MIN_FREE:raise StorageError('At least 8 GB of free disk space is needed to rebuild')
    removals=deletions(manifest(DELETIONS),installed,latest)
    stage=Path(tempfile.mkdtemp(prefix=latest+'-',dir=state))
    try:
        pack=stage/'pack';pack.mkdir()
        # Refuse links in source data before copying into the writable extraction tree.
        if any(p.is_symlink() for p in source.rglob('*')):raise VerificationError('Pack contains symbolic links')
        root=pack/'RetroRewind6';clone(source,root)
        records=[]
        for number,(pack_version,url) in enumerate(updates):
            progress={'step':'downloading','patchIndex':number+1,'patchCount':len(updates)}
            status(**progress)
            archive=stage/f'patch-{number}.zip'
            download(url,archive,lambda done,size:status(**progress,downloadedBytes=done,totalBytes=size))
            status(**{**progress,'step':'extracting'})
            records.append({'version':pack_version,'url':url,'bytes':archive.stat().st_size,'sha256':digest(archive)})
            extract(archive,pack)
            archive.unlink()
            records[-1]['deleted']=remove(root,removals.pop(pack_version,[]))
        # Deletions listed for a version without its own patch still apply, in version order.
        for pack_version in sorted(removals,key=version):remove(root,removals[pack_version])
        if (root/'version.txt').read_text().strip()!=latest:raise VerificationError('Updated pack version does not match the manifest')
        profile['retroRewind']['version']=latest
        for key in ('codePul','riivolutionXml'):
            item=profile['retroRewind'][key];file=root/item['path']
            item.update(bytes=file.stat().st_size,sha256=digest(file))
        profile['localBuildUpdates']=profile.get('localBuildUpdates',[])+records
        local_profile=stage/'profile.json';atomic_json(local_profile,profile)
        candidate=stage/'KartPad.app'
        command=[arg.replace('{root}',str(root)).replace('{profile}',str(local_profile)).replace('{app}',str(candidate)) for arg in settings['buildCommand']]
        status(step='compiling')
        with (stage/'build.log').open('w') as log:run(command,settings,log)
        status(step='verifying')
        binary=(candidate/'Contents/MacOS/KartPad').read_bytes()
        if any(profile['retroRewind'][key]['sha256'].encode() not in binary for key in ('codePul','riivolutionXml')):
            raise VerificationError('Rebuilt app does not validate the new pack fingerprint')
        resources=candidate/'Contents/Resources/LocalUpdater'
        if not (resources/'updater.py').exists():  # the package script bundles these when asked
            resources.mkdir(parents=True,exist_ok=True)
            shutil.copy2(Path(__file__),resources/'updater.py')
            atomic_json(resources/'settings.json',settings)
        with (stage/'build.log').open('a') as log:
            run(['/usr/bin/codesign','--force','--deep','--sign','-','--entitlements',settings['repo']+'/apple/macos/KartPad.entitlements',str(candidate)],settings,log)
            run([settings['repo']+'/scripts/audit-macos-package.sh',str(candidate),'dual'],settings,log)
        atomic_json(state/'pending.json',{'version':latest,'url':latest_url,'root':str(root),'profile':str(local_profile),'app':str(candidate),'runtimeSha256':digest(candidate/'Contents/MacOS/KartPad')})
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
    subprocess.Popen([sys.executable,str(script),'relaunch','--settings',str(app/'Contents/Resources/LocalUpdater/settings.json'),'--app',str(app),'--version',version,'--pid',str(pid)],start_new_session=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)

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
                    recover(state)
                    if args.then=='activate' and activate(state,args.app,config,verify,settings['initial']):
                        atomic_json(state/'status.json',{'phase':'installed','version':load(state/'active.json')['version'],'checkedAt':time.time()})
                    elif args.then=='rollback':rollback(state,args.app,config,verify,'manual')
                except Exception as exc:
                    atomic_json(state/'status.json',{'phase':'error','errorKind':error_kind(exc),'message':str(exc),'checkedAt':time.time()})
        subprocess.run(['/usr/bin/open','-n',str(args.app)],check=True);return 0
    with locked(state) as acquired:
        if not acquired:return 0
        try:
            if args.action=='activate':
                recover(state)
                if activate(state,args.app,config,verify,settings['initial']):
                    atomic_json(state/'status.json',{'phase':'installed','version':load(state/'active.json')['version'],'checkedAt':time.time()})
                    relaunch(args.app,args.version,args.pid);return 10
                if trial(state,args.app,config,verify,args.version):
                    relaunch(args.app,args.version,args.pid);return 10
            else:check(settings,args.version,state,args.app,args.force,args.allow_declined)
        except Exception as exc:
            atomic_json(state/'status.json',{'phase':'error','errorKind':error_kind(exc),'message':str(exc),'checkedAt':time.time()})
            return 1
    return 0

if __name__=='__main__':sys.exit(main())
