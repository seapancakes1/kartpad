#!/usr/bin/env python3
"""Opt-in local Mac updater: rebuild off to the side, activate at next launch."""
from __future__ import annotations
import argparse, contextlib, errno, fcntl, hashlib, json, os, re, shutil, stat
import subprocess, sys, tempfile, time, urllib.error, urllib.request, zipfile
from pathlib import Path
from urllib.parse import urlparse

FEED = 'https://update.rwfc.net/RetroRewind/RetroRewindVersion.txt'
CDN = 'https://cdn.update.rwfc.net/RetroRewind/zip/'
MAX_ARCHIVE = 3_000_000_000
MAX_EXPANDED = 4_000_000_000

def version(value):
    if not re.fullmatch(r'\d+(?:\.\d+){1,3}', value):
        raise ValueError('Invalid pack version')
    return tuple(map(int, value.split('.')))

def atomic_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix('.tmp')
    tmp.write_text(json.dumps(value, indent=2)+'\n')
    os.replace(tmp, path)

def digest(path):
    with path.open('rb') as file:
        return hashlib.file_digest(file, 'sha256').hexdigest()

def fetch(url, maximum):
    expected = 'update.rwfc.net' if url == FEED else 'cdn.update.rwfc.net'
    if urlparse(url).scheme != 'https' or urlparse(url).netloc != expected:
        raise ValueError('Update URL is outside the official feed')
    response = urllib.request.urlopen(urllib.request.Request(url, headers={'User-Agent':'KartPad-Local-Updater/1'}), timeout=30)
    if urlparse(response.url).scheme != 'https' or urlparse(response.url).netloc != expected:
        response.close()
        raise ValueError('Update redirected outside the official source')
    if int(response.headers.get('Content-Length', '0')) > maximum:
        response.close()
        raise ValueError('Update exceeds the download limit')
    return response

def releases(text, installed):
    result = []
    for line in text.splitlines():
        parts = line.split()
        if not parts: continue
        key = version(parts[0])
        if len(parts) < 2 or not parts[1].startswith(CDN) or urlparse(parts[1]).netloc != 'cdn.update.rwfc.net':
            raise ValueError('Invalid official update manifest')
        if key > version(installed): result.append((parts[0], parts[1]))
    return sorted(result, key=lambda item:version(item[0]))

def extract(archive, target):
    with zipfile.ZipFile(archive) as bundle:
        entries = bundle.infolist()
        if len(entries)>20000 or sum(i.file_size for i in entries)>MAX_EXPANDED:
            raise ValueError('Update exceeds extraction limits')
        seen = set()
        for info in entries:
            name=info.filename
            parts=Path(name).parts
            if not parts or name.startswith('/') or '..' in parts or '\\' in name or parts[0] not in ('RetroRewind6','riivolution'):
                raise ValueError('Unsafe update path')
            if name in seen or stat.S_ISLNK(info.external_attr>>16) or info.flag_bits & 1:
                raise ValueError('Unsupported update ZIP entry')
            seen.add(name)
            path=target/name
            if not path.resolve().is_relative_to(target.resolve()):
                raise ValueError('Update path escapes its staging directory')
            if info.is_dir(): path.mkdir(parents=True, exist_ok=True)
            else:
                path.parent.mkdir(parents=True, exist_ok=True)
                with bundle.open(info) as src, path.open('wb') as dst:
                    shutil.copyfileobj(src, dst)

def updated_config(text, root):
    updated,n = re.subn(r'^retro_rewind_root\s*=.*$', 'retro_rewind_root = '+json.dumps(str(root)),text,flags=re.M)
    if n!=1: raise ValueError('Cannot locate the configured Retro Rewind data path')
    return updated

def run(command, settings, log):
    subprocess.run(command, cwd=settings['repo'], env={**os.environ, **settings.get('environment',{})}, stdout=log, stderr=subprocess.STDOUT, check=True)

def activate(state, app, config, verify):
    pending_file=state/'pending.json'
    if not pending_file.exists(): return False
    pending=json.loads(pending_file.read_text())
    candidate=Path(pending['app'])
    if digest(candidate/'Contents/MacOS/KartPad') != pending['runtimeSha256']:
        raise ValueError('Pending app integrity check failed')
    verify(candidate)
    root=Path(pending['root'])
    if (root/'version.txt').read_text().strip()!=pending['version']:
        raise ValueError('Pending pack version changed')
    profile=json.loads(Path(pending['profile']).read_text())['retroRewind']
    for key in ('codePul','riivolutionXml'):
        if digest(root/profile[key]['path'])!=profile[key]['sha256']:
            raise ValueError('Pending pack integrity check failed')
    original=config.read_text()
    replacement=updated_config(original,root)
    backup=app.with_name(app.stem+'.before-'+pending['version']+'.app')
    if backup.exists(): raise ValueError('Rollback app already exists')
    staged=app.with_name('.'+app.stem+'.update.app')
    if staged.exists(): raise ValueError('An unfinished app installation exists')
    try:
        shutil.copytree(candidate,staged,symlinks=True)
        verify(staged)
    except BaseException:
        if staged.exists(): shutil.rmtree(staged)
        raise
    active_file=state/'active.json'
    previous_active=json.loads(active_file.read_text()) if active_file.exists() else None
    atomic_json(state/'activation.json',{'app':str(app),'backup':str(backup),'config':str(config),'originalConfig':original,'previousActive':previous_active,'pending':pending,'staged':str(staged)})
    moved=False
    try:
        os.replace(app,backup); moved=True
        os.replace(staged,app)
        tmp=config.with_name(config.name+'.update')
        tmp.write_text(replacement);shutil.copymode(config,tmp);os.replace(tmp,config)
        atomic_json(state/'active.json',{'version':pending['version'],'root':pending['root'],'profile':pending['profile']})
        pending_file.unlink()
        (state/'activation.json').unlink()
    except BaseException:
        if moved:
            if app.exists(): shutil.rmtree(app)
            os.replace(backup,app)
        config.write_text(original)
        if previous_active is None:
            active_file.unlink(missing_ok=True)
        else: atomic_json(active_file,previous_active)
        if staged.exists(): shutil.rmtree(staged)
        (state/'activation.json').unlink(missing_ok=True)
        raise
    return True

def recover(state):
    journal=state/'activation.json'
    if not journal.exists(): return
    data=json.loads(journal.read_text());app=Path(data['app']);backup=Path(data['backup'])
    if backup.exists():
        if app.exists(): shutil.rmtree(app)
        os.replace(backup,app)
    Path(data['config']).write_text(data['originalConfig'])
    previous=data.get('previousActive')
    if previous is None: (state/'active.json').unlink(missing_ok=True)
    else: atomic_json(state/'active.json',previous)
    atomic_json(state/'pending.json',data['pending'])
    staged=Path(data['staged'])
    if staged.exists(): shutil.rmtree(staged)
    journal.unlink()

@contextlib.contextmanager
def locked(state):
    state.mkdir(parents=True,exist_ok=True)
    with (state/'lock').open('w') as file:
        try: fcntl.flock(file,fcntl.LOCK_EX|fcntl.LOCK_NB)
        except BlockingIOError: yield False;return
        yield True

def check(settings, installed, state, app):
    if (state/'pending.json').exists(): return
    active=json.loads((state/'active.json').read_text()) if (state/'active.json').exists() else settings['initial']
    if active['version']!=installed: raise ValueError('Updater settings do not match this app version')
    source=Path(active['root'])
    if (source/'version.txt').read_text().strip()!=installed: raise ValueError('Installed pack does not match this app')
    profile=json.loads(Path(active['profile']).read_text())
    for key in ('codePul','riivolutionXml'):
        item=profile['retroRewind'][key]
        if digest(source/item['path'])!=item['sha256']:raise ValueError('Installed pack integrity check failed')
    with fetch(FEED,1_000_000) as response:
        text=response.read(1_000_001)
    if len(text)>1_000_000: raise ValueError('Manifest exceeds download limit')
    updates=releases(text.decode(),installed)
    if not updates:
        atomic_json(state/'status.json',{'phase':'current','version':installed,'checkedAt':time.time()});return
    latest=updates[-1][0]
    atomic_json(state/'status.json',{'phase':'building','step':'preparing','version':latest,'checkedAt':time.time()})
    if shutil.disk_usage(state).free<8_000_000_000:raise ValueError('At least 8 GB of free disk space is needed to rebuild')
    stage=Path(tempfile.mkdtemp(prefix=latest+'-',dir=state))
    try:
        target=stage/'pack';target.mkdir()
        # Refuse links in source data before copying into the writable extraction tree.
        if any(p.is_symlink() for p in source.rglob('*')):raise ValueError('Pack contains symbolic links')
        root=target/'RetroRewind6';shutil.copytree(source,root)
        records=[]
        for number,(pack_version,url) in enumerate(updates):
            progress={'phase':'building','step':'downloading','version':latest,'patchIndex':number+1,'patchCount':len(updates),'checkedAt':time.time()}
            atomic_json(state/'status.json',progress)
            archive=stage/f'patch-{number}.zip'
            with fetch(url,MAX_ARCHIVE) as response, archive.open('wb') as out:
                total=0
                size=int(response.headers.get('Content-Length','0')) if hasattr(response,'headers') else 0
                last_report=0.0
                while chunk:=response.read(1024*1024):
                    total+=len(chunk)
                    if total>MAX_ARCHIVE:raise ValueError('Update exceeds download limit')
                    out.write(chunk)
                    if time.monotonic()-last_report>=0.5:
                        atomic_json(state/'status.json',{**progress,'downloadedBytes':total,'totalBytes':size})
                        last_report=time.monotonic()
            atomic_json(state/'status.json',{**progress,'step':'extracting'})
            records.append({'version':pack_version,'url':url,'bytes':archive.stat().st_size,'sha256':digest(archive)})
            extract(archive,target)
        if (root/'version.txt').read_text().strip()!=latest:raise ValueError('Updated pack version does not match the manifest')
        profile['retroRewind']['version']=latest
        for key in ('codePul','riivolutionXml'):
            item=profile['retroRewind'][key];file=root/item['path']
            item.update(bytes=file.stat().st_size,sha256=digest(file))
        profile['localBuildUpdates']=profile.get('localBuildUpdates',[])+records
        local_profile=stage/'profile.json';atomic_json(local_profile,profile)
        candidate=stage/'KartPad.app'
        command=[arg.replace('{root}',str(root)).replace('{profile}',str(local_profile)).replace('{app}',str(candidate)) for arg in settings['buildCommand']]
        atomic_json(state/'status.json',{'phase':'building','step':'compiling','version':latest,'checkedAt':time.time()})
        with (stage/'build.log').open('w') as log:run(command,settings,log)
        atomic_json(state/'status.json',{'phase':'building','step':'verifying','version':latest,'checkedAt':time.time()})
        binary=(candidate/'Contents/MacOS/KartPad').read_bytes()
        if any(profile['retroRewind'][key]['sha256'].encode() not in binary for key in ('codePul','riivolutionXml')):
            raise ValueError('Rebuilt app does not validate the new pack fingerprint')
        resources=candidate/'Contents/Resources/LocalUpdater';resources.mkdir(parents=True)
        shutil.copy2(Path(__file__),resources/'updater.py')
        atomic_json(resources/'settings.json',settings)
        with (stage/'build.log').open('a') as log:
            run(['/usr/bin/codesign','--force','--deep','--sign','-','--entitlements',settings['repo']+'/apple/macos/KartPad.entitlements',str(candidate)],settings,log)
            run([settings['repo']+'/scripts/audit-macos-package.sh',str(candidate),'dual'],settings,log)
        atomic_json(state/'pending.json',{'version':latest,'root':str(root),'profile':str(local_profile),'app':str(candidate),'runtimeSha256':digest(candidate/'Contents/MacOS/KartPad')})
        atomic_json(state/'status.json',{'phase':'ready','version':latest,'checkedAt':time.time()})
    except Exception:
        if (stage/'build.log').exists(): shutil.copy2(stage/'build.log',state/'last-build.log')
        shutil.rmtree(stage)
        raise

def error_kind(error):
    if isinstance(error,urllib.error.URLError):return 'network'
    if getattr(error,'errno',None)==errno.ENOSPC or 'free disk space' in str(error):return 'storage'
    if isinstance(error,subprocess.CalledProcessError):return 'build'
    if isinstance(error,(zipfile.BadZipFile,ValueError)):
        return 'verification' if any(word in str(error).lower() for word in ('integrity','fingerprint','unsafe','escapes','zip','manifest','redirect','version','official')) else 'configuration'
    return 'configuration'

def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('action',choices=('check','activate','relaunch'))
    parser.add_argument('--settings',type=Path,required=True)
    parser.add_argument('--app',type=Path,required=True)
    parser.add_argument('--version',required=True)
    parser.add_argument('--pid',type=int)
    args=parser.parse_args();settings=json.loads(args.settings.read_text());state=Path(settings['state'])
    if args.action=='relaunch':
        for _ in range(300):
            try:os.kill(args.pid,0)
            except ProcessLookupError:subprocess.run(['/usr/bin/open','-n',str(args.app)],check=True);return 0
            time.sleep(.1)
        return 1
    with locked(state) as acquired:
        if not acquired:return 0
        try:
            if args.action=='activate':
                recover(state)
                verify=lambda path:subprocess.run(['/usr/bin/codesign','--verify','--deep','--strict',str(path)],check=True,capture_output=True)
                if activate(state,args.app,Path(settings['config']),verify):
                    atomic_json(state/'status.json',{'phase':'installed','version':json.loads((state/'active.json').read_text())['version']})
                    script=args.app/'Contents/Resources/LocalUpdater/updater.py'
                    subprocess.Popen([sys.executable,str(script),'relaunch','--settings',str(args.app/'Contents/Resources/LocalUpdater/settings.json'),'--app',str(args.app),'--version',args.version,'--pid',str(args.pid)],start_new_session=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
                    return 10
            else:check(settings,args.version,state,args.app)
        except Exception as exc:
            atomic_json(state/'status.json',{'phase':'error','errorKind':error_kind(exc),'message':str(exc),'checkedAt':time.time()})
            return 1
    return 0

if __name__=='__main__':sys.exit(main())
