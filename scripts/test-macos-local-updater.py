#!/usr/bin/env python3
"""Local Mac updater tests: temporary folders and fake downloads only (no network, app or real state).
Runs on the stock macOS python3 (3.9) and newer."""
import errno,hashlib,importlib.util,io,json,os,shutil,subprocess,sys,tempfile,time,unittest,urllib.error,zipfile
from pathlib import Path,PurePosixPath
from unittest.mock import patch
REAL_RUN=subprocess.run
spec=importlib.util.spec_from_file_location('updater',Path(__file__).with_name('macos-local-updater.py'))
u=importlib.util.module_from_spec(spec);spec.loader.exec_module(u)
ROOMY=type('Disk',(),{'free':20_000_000_000})()
SAVE='save/RetroWFC/RMCP/rksys.dat'

def sha(data):return hashlib.sha256(data if isinstance(data,bytes) else data.encode()).hexdigest()

def zip_bytes(files):
    data=io.BytesIO()
    with zipfile.ZipFile(data,'w') as z:
        for name,text in files.items():z.writestr(name,text)
    return data.getvalue()

class Response(io.BytesIO):
    def __init__(self,data,status=200):
        super().__init__(data);self.status=status;self.headers={'Content-Length':str(len(data))}

PATCH=zip_bytes({'RetroRewind6/version.txt':'6.13.2','RetroRewind6/code':'new code','RetroRewind6/xml':'new xml'})

def review(version='6.13.2',code='new code',xml='new xml',archive=PATCH):
    """A maintainers' profile as upstream publishes it, pinning the 6.13.2 update."""
    return {'retroRewind':{'version':version,'root':'RetroRewind6',
        'archive':{'url':u.CDN+'6.13.0-full.zip','bytes':1938862721,'sha256':'2d'*32,'maximumExpandedBytes':2200000000},
        'updateArchive':{'url':u.CDN+'6.13.2.zip','bytes':len(archive),'sha256':sha(archive),'maximumExpandedBytes':36000000},
        'codePul':{'path':'code','bytes':len(code),'sha256':sha(code)},
        'riivolutionXml':{'path':'xml','bytes':len(xml),'sha256':sha(xml)}}}

class Updates(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.addCleanup(self.tmp.cleanup)
        self.root=Path(self.tmp.name).resolve();self.clock=1_700_000_000
        # No network, no app launches or signing: only file copies run for real.
        run=u.subprocess.run
        def copies_only(command,*args,**kwargs):
            if command[0]!='/bin/cp':raise AssertionError(command[0]+' not expected')
            return run(command,*args,**kwargs)
        for target,name,fake in ((u.urllib.request,'urlopen',AssertionError('network not expected')),(u.subprocess,'run',copies_only),(u,'relaunch',AssertionError('relaunch not expected'))):
            guard=patch.object(target,name,side_effect=fake);guard.start();self.addCleanup(guard.stop)
    # A KartPad install: the app, its original pack with saves beside it, the config and state folder.
    def world(self):
        self.state=state=self.root/'state';state.mkdir()
        self.app=app=self.root/'Apps/KartPad.app';(app/'Contents/MacOS').mkdir(parents=True)
        (app/'Contents/MacOS/KartPad').write_text('old')
        self.old=old=self.root/'Old/RetroRewind6';(old/'Tracks').mkdir(parents=True)
        (old/'version.txt').write_text('6.13.1');(old/'code').write_text('old code');(old/'xml').write_text('old xml')
        (old/'Tracks/gone.szs').write_text('removed in 6.13.2')
        profile=self.root/'old-profile.json'
        profile.write_text(json.dumps({'retroRewind':{'version':'6.13.1',**{key:{'path':name,'bytes':(old/name).stat().st_size,'sha256':u.digest(old/name)} for key,name in [('codePul','code'),('riivolutionXml','xml')]}}}))
        self.initial={'version':'6.13.1','root':str(old),'profile':str(profile)}
        self.config=config=self.root/'Config.toml'
        config.write_text('[paths]\nretro_rewind_root = '+json.dumps(str(old))+'\nkeep = true\n')
        self.play(old,'progress on 6.13.1')
        self.settings={'initial':self.initial,'repo':str(self.root),'state':str(state),'config':str(config),'buildCommand':['fake-build','{profile}','{app}']}
        return state,app,config
    def play(self,root,text):
        """The game saves beside the pack it runs from; each save is later than the one before."""
        path=u.riivolution(root)/SAVE;path.parent.mkdir(parents=True,exist_ok=True);path.write_text(text)
        self.clock+=60;os.utime(path,(self.clock,self.clock))
    def saved(self,root):
        path=u.riivolution(root)/SAVE
        return path.read_text() if path.exists() else None
    def pending(self,version='6.13.2',runtime='new'):
        """A finished build of version, as check() leaves it."""
        stage=self.state/(version+'-abc');candidate=stage/'KartPad.app';(candidate/'Contents/MacOS').mkdir(parents=True)
        (candidate/'Contents/MacOS/KartPad').write_text(runtime)
        root=stage/'pack/RetroRewind6';root.mkdir(parents=True);(root/'version.txt').write_text(version)
        (root/'code').write_text('code '+version);(root/'xml').write_text('xml '+version)
        profile=stage/'profile.json';profile.write_text(json.dumps({'retroRewind':{k:{'path':name,'sha256':u.digest(root/name)} for k,name in [('codePul','code'),('riivolutionXml','xml')]}}))
        u.atomic_json(self.state/'pending.json',{'version':version,'url':u.CDN+version+'.zip','root':str(root),'profile':str(profile),'app':str(candidate),'runtimeSha256':u.digest(candidate/'Contents/MacOS/KartPad')})
        return root
    def activate(self):
        return u.activate(self.state,self.app,self.config,lambda p:None,self.initial)
    def backups(self):
        return sorted(p.name for p in (self.state/u.BACKUPS).iterdir())

    def test_error_messages_can_offer_specific_recovery(self):
        self.assertEqual(u.error_kind(urllib.error.URLError('offline')),'network')
        self.assertEqual(u.error_kind(TimeoutError('slow')),'network')
        self.assertEqual(u.error_kind(OSError(errno.ENOSPC,'disk full')),'storage')
        self.assertEqual(u.error_kind(u.StorageError('At least 8 GB of free disk space is needed to rebuild')),'storage')
        self.assertEqual(u.error_kind(u.VerificationError('Pending pack integrity check failed')),'verification')
        self.assertEqual(u.error_kind(u.Unverified('mismatch','code differs')),'unverified')
        # Wording no longer decides the kind: a settings mismatch is configuration.
        self.assertEqual(u.error_kind(ValueError('Updater settings do not match this app version')),'configuration')

    def test_bundled_helper_writes_nothing_into_the_signed_app(self):
        bundle=self.root/'LocalUpdater';bundle.mkdir()
        for name,bundled in (('macos-local-updater.py','updater.py'),('update-retro-rewind-profile.py','update-retro-rewind-profile.py')):
            shutil.copy2(Path(__file__).with_name(name),bundle/bundled)
        REAL_RUN([sys.executable,'-I',str(bundle/'updater.py'),'--help'],check=True,capture_output=True)
        self.assertEqual(sorted(p.name for p in bundle.iterdir()),['update-retro-rewind-profile.py','updater.py'])
    def test_feed_parsing_shares_upstreams_version_order(self):
        self.assertEqual(u.FEED,u.pins.VERSION_FEED);self.assertTrue(u.DELETIONS.endswith('/RetroRewindDelete.txt'))
        self.assertEqual(u.version('6.13.10'),u.pins.version_key('6.13.10'))
        with self.assertRaises(u.VerificationError):u.version('6.13.2b')
    def test_feed_orders_all_intermediate_patches(self):
        text='6.13.2 '+u.CDN+'6.13.2.zip\n6.13.0 '+u.CDN+'6.13.0.zip\n6.13.1 '+u.CDN+'6.13.1.zip'
        self.assertEqual([v for v,url in u.releases(text,'6.12.8')],['6.13.0','6.13.1','6.13.2'])
    def test_feed_accepts_the_live_four_column_format(self):
        text='6.13.1 '+u.CDN+'6.13.1.zip /6.13.1.zip Assets\n6.13.2 '+u.CDN+'6.13.2.zip /6.13.2.zip Assets\n'
        self.assertEqual(u.releases(text,'6.13.1'),[('6.13.2',u.CDN+'6.13.2.zip')])
    def test_feed_rejects_unofficial_url(self):
        with self.assertRaises(ValueError):u.releases('6.13.2 https://evil.example/pack.zip','6.13.1')

    def test_delete_list_selects_pack_files_for_skipped_versions(self):
        text=('6.6.9 /RetroRewind6/Tracks/old.szs\n6.13.2 /RetroRewind6/Tracks/gone.szs\n'
              '6.13.2 /6.13.2.zip\n6.13.3 /RetroRewind6/strm/gone.brstm\n6.13.4 /RetroRewind6/later.szs\n')
        self.assertEqual(u.deletions(text,'6.13.1','6.13.3'),
                         {'6.13.2':[PurePosixPath('Tracks/gone.szs')],'6.13.3':[PurePosixPath('strm/gone.brstm')]})
    def test_delete_list_rejects_unsafe_and_whole_pack_entries(self):
        for line in ('6.13.2 /RetroRewind6/../escape','6.13.2 /RetroRewind6','6.13.2 /RetroRewind6/'):
            with self.assertRaises(u.VerificationError):u.deletions(line,'6.13.1','6.13.2')

    def test_zip_rejects_traversal(self):
        archive=self.root/'bad.zip'
        with zipfile.ZipFile(archive,'w') as z:z.writestr('RetroRewind6/../../escape','bad')
        with self.assertRaises(ValueError):u.extract(archive,self.root/'stage')
        self.assertFalse((self.root/'escape').exists())
    def test_patch_overwrites_without_removing_other_assets(self):
        stage=self.root/'stage';(stage/'RetroRewind6').mkdir(parents=True)
        (stage/'RetroRewind6/keep').write_text('keep')
        archive=self.root/'update.zip'
        with zipfile.ZipFile(archive,'w') as z:z.writestr('RetroRewind6/version.txt','6.13.2')
        u.extract(archive,stage)
        self.assertEqual((stage/'RetroRewind6/keep').read_text(),'keep')

    def test_clone_leaves_the_source_untouched(self):
        source=self.root/'source';(source/'sub').mkdir(parents=True);(source/'sub/file').write_text('original')
        u.clone(source,self.root/'copy')
        (self.root/'copy/sub/file').write_text('patched')
        self.assertEqual((source/'sub/file').read_text(),'original')
    def test_move_between_volumes_copies_then_deletes(self):
        source=self.root/'a/KartPad.app';(source/'Contents').mkdir(parents=True);(source/'Contents/file').write_text('app')
        target=self.root/'b/KartPad-6.13.1.app';target.parent.mkdir();replace=os.replace
        def cross(a,b):
            if Path(a).parent!=Path(b).parent:raise OSError(errno.EXDEV,'cross-device link')
            replace(a,b)
        with patch.object(u.os,'replace',side_effect=cross):u.move(source,target)
        self.assertEqual((target/'Contents/file').read_text(),'app')
        self.assertEqual(list((self.root/'a').iterdir()),[]);self.assertEqual(list((self.root/'b').iterdir()),[target])

    def test_download_resumes_after_an_interrupted_transfer(self):
        data=b'x'*3000;calls=[]
        class Broken(Response):
            def read(self,size=-1):
                if self.tell()>=1000:raise ConnectionError('reset')
                return super().read(1000)
        def fetch(url,limit,offset=0):
            calls.append(offset)
            return Broken(data) if not offset else Response(data[offset:],206)
        with patch.object(u,'fetch',side_effect=fetch),patch.object(u.time,'sleep'):
            u.download(u.CDN+'6.13.2.zip',self.root/'patch.zip',lambda done,size:None)
        self.assertEqual((self.root/'patch.zip').read_bytes(),data)
        self.assertEqual(calls,[0,1000])
    def test_reviewed_profile_must_come_from_the_repository_host(self):
        for url in ('https://evil.example/profile.json','http://raw.githubusercontent.com/x.json'):
            with self.assertRaises(u.VerificationError):u.reviewed({'reviewedProfile':url})
        self.assertEqual(u.source_host(u.REVIEWED),'raw.githubusercontent.com')
        class Redirected(Response):url='https://evil.example/profile.json'
        with patch.object(u.urllib.request,'urlopen',return_value=Redirected(b'{}')):
            with self.assertRaises(u.VerificationError):u.fetch(u.REVIEWED,1000)
        with patch.object(u,'manifest',return_value='{"retroRewind":{"version":"6.13.2"}}'):
            with self.assertRaises(u.VerificationError):u.reviewed({})

    def test_activate_app_and_pack_together_keeps_backup_out_of_applications(self):
        state,app,config=self.world();root=self.pending()
        self.assertTrue(self.activate())
        self.assertEqual((app/'Contents/MacOS/KartPad').read_text(),'new')
        self.assertEqual(sorted(p.name for p in app.parent.iterdir()),['KartPad.app'])
        self.assertEqual(self.backups(),['KartPad-6.13.1.app'])
        self.assertEqual((state/u.BACKUPS/'KartPad-6.13.1.app/Contents/MacOS/KartPad').read_text(),'old')
        self.assertIn('keep = true',config.read_text());self.assertIn(str(root),config.read_text())
        self.assertFalse((state/'pending.json').exists())
        self.assertEqual(u.load(state/'trial.json'),{'version':'6.13.2','launches':0})
        self.assertEqual(u.load(state/'rollback.json')['version'],'6.13.1')
        self.assertEqual(u.load(state/'installed.json'),{'app':str(app),'version':'6.13.2','runtimeSha256':u.digest(app/'Contents/MacOS/KartPad')})
    def test_activation_removes_the_spare_candidate_and_older_versions(self):
        state,app,config=self.world();self.pending()
        older=state/'6.12.8-old';(older/'pack').mkdir(parents=True)
        stale=state/u.BACKUPS/'KartPad-6.12.8.app';stale.mkdir(parents=True)
        self.activate()
        self.assertFalse((state/'6.13.2-abc/KartPad.app').exists())
        self.assertTrue((state/'6.13.2-abc/pack/RetroRewind6/code').exists())
        self.assertFalse(older.exists());self.assertFalse(stale.exists())
        self.assertEqual(self.backups(),['KartPad-6.13.1.app'])
    def test_existing_backup_name_does_not_block_activation(self):
        state,app,config=self.world();self.pending()
        (state/u.BACKUPS/'KartPad-6.13.1.app').mkdir(parents=True)
        self.assertTrue(self.activate())
        self.assertEqual(Path(u.load(state/'rollback.json')['app']).name,'KartPad-6.13.1-2.app')
    def test_leftover_unjournaled_copy_does_not_block_activation(self):
        state,app,config=self.world();self.pending()
        (app.with_name('.KartPad.update.app')/'partial').mkdir(parents=True)
        self.assertTrue(self.activate())
        self.assertFalse(app.with_name('.KartPad.update.app').exists())
    def test_bad_runtime_cannot_replace_working_app(self):
        state,app,config=self.world();self.pending();original=config.read_text()
        (state/'6.13.2-abc/KartPad.app/Contents/MacOS/KartPad').write_text('tampered')
        with self.assertRaises(ValueError):self.activate()
        self.assertEqual((app/'Contents/MacOS/KartPad').read_text(),'old');self.assertEqual(config.read_text(),original)
    def test_rejected_build_is_discarded_so_updates_continue(self):
        state,app,config=self.world();self.pending();(state/'6.13.2-abc/pack/RetroRewind6/code').write_text('tampered')
        with self.assertRaises(ValueError):self.activate()
        self.assertEqual((app/'Contents/MacOS/KartPad').read_text(),'old')
        self.assertFalse((state/'pending.json').exists());self.assertFalse((state/'6.13.2-abc').exists())
        failure=u.load(state/'failure.json')
        self.assertEqual((failure['kind'],failure['version']),('verification','6.13.2'))
    def test_activation_failure_restores_app_config_state_and_saves(self):
        state,app,config=self.world();root=self.pending();original=config.read_text();atomic=u.atomic_json
        def fail(path,value):
            if path.name=='active.json':raise OSError(errno.ENOSPC,'disk full')
            atomic(path,value)
        with patch.object(u,'atomic_json',side_effect=fail):
            with self.assertRaises(OSError):self.activate()
        self.assertEqual((app/'Contents/MacOS/KartPad').read_text(),'old');self.assertEqual(config.read_text(),original)
        # Out of space is worth retrying, so the build stays pending.
        self.assertTrue((state/'pending.json').exists());self.assertFalse((state/'activation.json').exists())
        self.assertFalse((state/'trial.json').exists());self.assertFalse((state/'rollback.json').exists())
        self.assertIsNone(self.saved(root));self.assertEqual(self.saved(self.old),'progress on 6.13.1')
    def test_duplicate_worker_cannot_acquire_lock(self):
        with u.locked(self.root/'state') as first:
            with u.locked(self.root/'state') as second:
                self.assertTrue(first);self.assertFalse(second)
    def test_config_changes_only_pack_path(self):
        original='[paths]\nretro_rewind_root = "old"\n[video]\nvsync = true\n'
        self.assertEqual(u.updated_config(original,Path('/new')),original.replace('"old"','"/new"'))
    def test_configured_root_reads_the_games_setting(self):
        config=self.root/'Config.toml'
        for text,expected in (('# retro_rewind_root = "x"\nretro_rewind_root = "/a/b"\n','/a/b'),('retro_rewind_root = "rel/RetroRewind6"\n',str(self.root/'rel/RetroRewind6')),
                              ("retro_rewind_root = '/lit/x' # note\n",'/lit/x'),('[paths]\n',None)):
            config.write_text(text);self.assertEqual(u.configured_root(config) and str(u.configured_root(config)),expected)

    # Saves (riivolution/ beside each pack) follow the player through updates and going back.
    def test_update_carries_saves_made_after_the_build(self):
        state,app,config=self.world();root=self.pending()
        self.play(self.old,'raced after the update was built')
        self.activate()
        self.assertEqual(self.saved(root),'raced after the update was built')
        self.assertEqual(self.saved(self.old),'raced after the update was built')  # copied, never moved
        self.assertFalse((u.riivolution(root)/'.kartpad-replaced').exists())
    def test_progress_survives_two_updates_and_pruning(self):
        state,app,config=self.world()
        second=self.pending('6.13.2');self.activate();self.play(second,'progress on 6.13.2')
        third=self.pending('6.13.3');self.activate()
        self.assertEqual(self.saved(third),'progress on 6.13.2');self.play(third,'progress on 6.13.3')
        fourth=self.pending('6.13.4');self.activate()
        self.assertEqual(self.saved(fourth),'progress on 6.13.3')
        self.assertFalse((state/'6.13.2-abc').exists())  # its progress lives on in 6.13.4
        self.assertTrue((state/'6.13.3-abc').exists())  # the version to go back to
        self.assertEqual(self.saved(self.old),'progress on 6.13.1')
        self.assertEqual(self.backups(),['KartPad-6.13.3.app'])
    def test_pruning_keeps_a_pack_with_newer_saves(self):
        state,app,config=self.world()
        second=self.pending('6.13.2');self.activate();self.pending('6.13.3');self.activate()
        self.play(second,'newer than anything the game uses now')
        self.pending('6.13.4');self.activate()
        self.assertEqual(self.saved(second),'newer than anything the game uses now')
    def test_going_back_brings_progress_along(self):
        state,app,config=self.world();root=self.pending();self.activate()
        self.play(root,'progress on 6.13.2')
        u.rollback(state,app,config,lambda p:None,'manual')
        self.assertEqual(self.saved(self.old),'progress on 6.13.2')
        self.assertEqual(u.configured_root(config),self.old)
    def test_interrupted_going_back_keeps_the_older_saves(self):
        state,app,config=self.world();root=self.pending();self.activate();self.play(root,'progress on 6.13.2')
        move=u.move
        def fail(source,target):
            if Path(source)==Path(u.load(state/'rollback.json')['app']):raise OSError(errno.EIO,'disk error')
            move(source,target)
        with patch.object(u,'move',side_effect=fail):
            with self.assertRaises(OSError):u.rollback(state,app,config,lambda p:None,'manual')
        self.assertEqual(self.saved(self.old),'progress on 6.13.1');self.assertEqual(self.saved(root),'progress on 6.13.2')
        self.assertEqual((app/'Contents/MacOS/KartPad').read_text(),'new');self.assertEqual(u.configured_root(config),root)

    def test_rollback_restores_previous_app_pack_and_later_settings(self):
        state,app,config=self.world();self.pending();self.activate()
        config.write_text(config.read_text()+'changed_after_update = true\n')
        u.rollback(state,app,config,lambda p:None,'manual')
        self.assertEqual((app/'Contents/MacOS/KartPad').read_text(),'old')
        self.assertIn('retro_rewind_root = '+json.dumps(self.initial['root']),config.read_text())
        self.assertIn('changed_after_update = true',config.read_text())
        self.assertFalse((state/'active.json').exists());self.assertFalse((state/'rollback.json').exists())
        self.assertEqual(u.load(state/'declined.json')['version'],'6.13.2')
        self.assertEqual(u.load(state/'status.json')['phase'],'rolledBack')
        self.assertEqual(u.load(state/'installed.json'),{'app':str(app),'version':'6.13.1','runtimeSha256':u.digest(app/'Contents/MacOS/KartPad')})
        self.assertEqual(self.backups(),[])
    def test_new_app_that_keeps_failing_is_rolled_back(self):
        state,app,config=self.world();self.pending();self.activate()
        verify=lambda p:None
        for launch in range(u.TRIAL_LAUNCHES):
            self.assertFalse(u.trial(state,app,config,verify,'6.13.2'))
        self.assertEqual(u.load(state/'trial.json')['launches'],u.TRIAL_LAUNCHES)
        self.assertTrue(u.trial(state,app,config,verify,'6.13.2'))
        self.assertEqual((app/'Contents/MacOS/KartPad').read_text(),'old')
        self.assertEqual(u.load(state/'status.json')['reason'],'unstable')
    def test_failed_automatic_rollback_is_reported_once(self):
        state,app,config=self.world();self.pending();self.activate()
        u.atomic_json(state/'trial.json',{'version':'6.13.2','launches':u.TRIAL_LAUNCHES})
        def missing(path):raise u.subprocess.CalledProcessError(1,['codesign'])
        with self.assertRaises(u.subprocess.CalledProcessError):u.trial(state,app,config,missing,'6.13.2')
        self.assertFalse((state/'trial.json').exists())
        self.assertEqual((app/'Contents/MacOS/KartPad').read_text(),'new')
    def test_confirmed_app_is_not_rolled_back(self):
        state,app,config=self.world();self.pending();self.activate()
        (state/'trial.json').unlink()  # the app removes it once it has run long enough
        self.assertFalse(u.trial(state,app,config,lambda p:None,'6.13.2'))
        self.assertEqual((app/'Contents/MacOS/KartPad').read_text(),'new')

    def test_interrupted_transaction_is_undone_at_every_step(self):
        steps=('journal','aside','carried','backed up','replaced','written')
        for completed in range(len(steps)):
            with self.subTest(step=steps[completed]):
                self.root=Path(self.tmp.name).resolve()/f'run{completed}';self.root.mkdir()
                state,app,config=self.world();original=config.read_text();before=u.snapshot(state)
                target=self.root/'Target/RetroRewind6';target.mkdir(parents=True);self.play(target,'older saves')
                staged=app.with_name('.KartPad.update.app');(staged/'Contents/MacOS').mkdir(parents=True);(staged/'Contents/MacOS/KartPad').write_text('new')
                backup=state/u.BACKUPS/'KartPad-6.13.1.app';backup.parent.mkdir(parents=True);moves=[(app,backup),(staged,app)]
                saves=u.carry_plan(u.riivolution(self.old),u.riivolution(target))
                u.atomic_json(state/'activation.json',{'moves':[[str(a),str(b)] for a,b in moves],'config':str(config),'originalConfig':original,'previous':before,'saves':saves})
                if completed>=1:
                    aside=Path(saves['aside']);aside.mkdir();os.replace(u.riivolution(target)/'save',aside/'save')
                if completed>=2:u.clone(u.riivolution(self.old)/'save',u.riivolution(target)/'save')
                for source,dest in moves[:max(0,completed-2)]:os.replace(source,dest)
                if completed==5:config.write_text('half written');u.atomic_json(state/'active.json',{'version':'6.13.2'})
                u.recover(state)
                self.assertEqual((app/'Contents/MacOS/KartPad').read_text(),'old')
                self.assertEqual(config.read_text(),original);self.assertEqual(u.snapshot(state),before)
                self.assertFalse(backup.exists());self.assertFalse((state/'activation.json').exists())
                self.assertEqual(self.saved(target),'older saves');self.assertEqual(self.saved(self.old),'progress on 6.13.1')
                self.assertEqual(sorted(p.name for p in u.riivolution(target).iterdir()),['save'])

    # Only the installed app acts; a backup or another copy leaves everything alone.
    def main(self,app,action='activate',*options):
        settings=self.root/'settings.json';settings.write_text(json.dumps(self.settings))
        argv=['updater',action,'--settings',str(settings),'--app',str(app),'--version',options[0] if options else '6.13.1','--pid','1',*options[1:]]
        with patch.object(sys,'argv',argv),patch.object(u,'relaunch') as relaunch:
            return u.main(),relaunch.called
    def test_backup_or_other_copy_leaves_state_alone(self):
        state,app,config=self.world();root=self.pending();self.activate();self.pending('6.13.3')
        before,original=u.snapshot(state),config.read_text()
        backup=state/u.BACKUPS/'KartPad-6.13.1.app'
        with patch.object(u,'fetch',side_effect=AssertionError('network not expected')):
            self.assertEqual(self.main(backup),(0,False))
            self.assertEqual(self.main(backup,'check','6.13.1','--force'),(0,False))
        self.assertEqual(u.snapshot(state),before);self.assertEqual(config.read_text(),original)
        self.assertEqual(u.load(state/'trial.json'),{'version':'6.13.2','launches':0})
        self.assertEqual((app/'Contents/MacOS/KartPad').read_text(),'new');self.assertTrue(backup.exists())
    def test_settings_can_name_the_installed_app(self):
        state,app,config=self.world();self.settings['app']=str(app)
        copy=self.root/'QA/KartPad.app';u.clone(app,copy)
        self.assertEqual(self.main(copy),(0,False));self.assertFalse((state/'installed.json').exists())
        self.assertEqual(self.main(app),(0,False))
        self.assertEqual(u.load(state/'installed.json')['app'],str(app))
    def test_moved_app_keeps_updating(self):
        state,app,config=self.world();self.assertEqual(self.main(app),(0,False))
        moved=self.root/'Apps/Games/KartPad 2.app';moved.parent.mkdir();os.replace(app,moved)
        self.assertTrue(u.other_copy(state,self.settings,moved))
        self.assertEqual(self.main(moved),(0,False))
        self.assertEqual(u.load(state/'installed.json')['app'],str(moved))
        self.assertFalse(u.other_copy(state,self.settings,moved));self.assertTrue(u.recognised(state,moved,'6.13.1'))
        self.app=moved;self.pending();self.assertTrue(self.activate())  # an update installs where it now is
        self.assertEqual((moved/'Contents/MacOS/KartPad').read_text(),'new');self.assertFalse(app.exists())
        self.assertEqual(u.load(state/'installed.json')['app'],str(moved))
    def test_copies_the_trash_and_other_builds_are_not_followed(self):
        state,app,config=self.world();self.main(app);record=u.load(state/'installed.json')
        copy=self.root/'Games/KartPad.app';copy.parent.mkdir();u.clone(app,copy)
        self.assertEqual(self.main(copy),(0,False))  # the installed app is still where it was
        trash=self.root/'.Trash/KartPad.app';trash.parent.mkdir();os.replace(app,trash)
        self.assertEqual(self.main(trash),(0,False))
        (copy/'Contents/MacOS/KartPad').write_text('another build');self.main(copy)
        self.assertEqual(u.load(state/'installed.json'),record)
        (copy/'Contents/MacOS/KartPad').write_text('old');self.settings['app']=str(app)
        self.main(copy);self.assertEqual(u.load(state/'installed.json'),record)  # settings pin the place
        del self.settings['app'];self.main(copy);self.assertEqual(u.load(state/'installed.json')['app'],str(copy))
    def test_first_launch_records_the_installed_app(self):
        state,app,config=self.world();self.pending();original=config.read_text()
        self.assertTrue(u.other_copy(state,self.settings,app) is False)
        u.adopt(state,self.settings,app,config,'6.13.1',False)
        self.assertEqual(u.load(state/'installed.json')['runtimeSha256'],u.digest(app/'Contents/MacOS/KartPad'))
        self.assertTrue((state/'pending.json').exists());self.assertEqual(config.read_text(),original)
        self.assertTrue(u.recognised(state,app,'6.13.1'))

    # A package built by hand after an update becomes the new starting point.
    def test_hand_built_app_after_an_update_is_adopted(self):
        state,app,config=self.world();root=self.pending();self.activate();self.play(root,'progress on 6.13.2')
        self.pending('6.13.3')
        (app/'Contents/MacOS/KartPad').write_text('hand-built 6.13.1')
        self.assertFalse(u.recognised(state,app,'6.13.1'))
        self.assertEqual(u.adopt(state,self.settings,app,config,'6.13.1',False),'deferred')
        self.assertEqual(u.configured_root(config),root)
        self.assertEqual(u.adopt(state,self.settings,app,config,'6.13.1',True),'moved')
        self.assertEqual(u.configured_root(config),self.old);self.assertIn('keep = true',config.read_text())
        self.assertEqual(self.saved(self.old),'progress on 6.13.2')
        for name in ('active.json','pending.json','trial.json','rollback.json','activation.json'):self.assertFalse((state/name).exists(),name)
        self.assertFalse((state/'6.13.3-abc/KartPad.app').exists())
        self.assertTrue(u.recognised(state,app,'6.13.1'))
        with patch.object(u,'fetch',side_effect=self.feed(review('6.13.1'))),patch.object(u.shutil,'disk_usage',return_value=ROOMY):
            u.check(self.settings,'6.13.1',state,app)
        self.assertEqual(u.load(state/'status.json')['phase'],'unverified')  # checks run again, from 6.13.1
    def test_hand_built_app_finds_an_earlier_updates_pack(self):
        state,app,config=self.world();second=self.pending('6.13.2');self.activate()
        third=self.pending('6.13.3');self.activate()
        (app/'Contents/MacOS/KartPad').write_text('hand-built 6.13.2')
        self.assertEqual(self.main(app,'activate','6.13.2'),(10,True))  # relaunches onto the right files
        self.assertEqual(u.configured_root(config),second)
        self.assertEqual(u.load(state/'active.json')['root'],str(second))
        self.assertTrue(u.recognised(state,app,'6.13.2'))
    def test_hand_rebuild_of_the_same_version_keeps_the_way_back(self):
        state,app,config=self.world();root=self.pending();self.activate();self.pending('6.13.3')
        (app/'Contents/MacOS/KartPad').write_text('hand-built 6.13.2')
        self.assertEqual(u.adopt(state,self.settings,app,config,'6.13.2',False),'recorded')
        self.assertEqual(u.configured_root(config),root);self.assertTrue((state/'rollback.json').exists())
        self.assertFalse((state/'trial.json').exists());self.assertFalse((state/'pending.json').exists())
    def test_check_waits_for_launch_to_move_the_game(self):
        state,app,config=self.world();root=self.pending();self.activate();original=config.read_text()
        (app/'Contents/MacOS/KartPad').write_text('hand-built 6.13.1')
        with patch.object(u,'fetch',side_effect=AssertionError('network not expected')):
            self.assertEqual(self.main(app,'check','6.13.1'),(0,False))
        self.assertEqual(config.read_text(),original);self.assertEqual(u.load(state/'active.json')['version'],'6.13.2')

    # Background checks: the official feed, the maintainers' review and fake downloads.
    def feed(self,pin=None,calls=None,archive=PATCH):
        pin=review() if pin is None else pin
        def fetch(url,limit,offset=0):
            if calls is not None:calls.append(url)
            if url==u.FEED:return Response(('6.13.2 '+u.CDN+'6.13.2.zip /6.13.2.zip Assets').encode())
            if url==u.DELETIONS:return Response(b'6.13.2 /RetroRewind6/Tracks/gone.szs\n6.13.2 /6.13.2.zip\n')
            if url==u.REVIEWED:return Response(json.dumps(pin).encode())
            if url==u.CDN+'6.13.2.zip':return Response(archive)
            raise AssertionError('unexpected download '+url)
        return fetch
    def fake_run(self,command,settings,log):
        self.builds.append(command[0])
        if command[0]=='fake-build':
            profile=json.loads(Path(command[1]).read_text())['retroRewind']
            target=Path(command[2]);(target/'Contents/MacOS').mkdir(parents=True)
            (target/'Contents/MacOS/KartPad').write_text('new runtime '+profile['codePul']['sha256']+' '+profile['riivolutionXml']['sha256'])
            if not self.unbundled:  # the package script bundles the helper when the build names its settings
                (target/'Contents/Resources/LocalUpdater').mkdir(parents=True);(target/'Contents/Resources/LocalUpdater/updater.py').write_text('helper')
    unbundled=False
    def run_check(self,fetch=None,run=None,**options):
        self.builds=getattr(self,'builds',[])
        with patch.object(u,'fetch',side_effect=fetch or self.feed()),patch.object(u,'run',side_effect=run or self.fake_run),patch.object(u.shutil,'disk_usage',return_value=ROOMY):
            u.check(self.settings,'6.13.1',self.state,self.app,**options)
    def status(self):return u.load(self.state/'status.json')

    def test_rebuild_progress_follows_the_build_log(self):
        start=b'Verified local extracted RMCP01 rev0 DOL and REL.\n[translator] Starting translation at 20:13:46\n'
        self.assertEqual(u.build_progress(start[:20]),('preparing',0.0))
        name,done=u.build_progress(start+b"[translator] phase 'discovery': 27.4s (t=27.4s)\n")
        self.assertEqual(name,'translating');self.assertTrue(0.05<done<0.28)
        graph=start+b'Generated validated private Retro Rewind native graph\n[0/2] Re-checking globbed directories...\n[1/2] Re-running CMake...\n'
        self.assertEqual(u.build_progress(graph),('compiling',0.28))  # CMake's own steps aren't the build's
        self.assertAlmostEqual(u.build_progress(graph+b'[50/100] Building CXX object a.o\n')[1],0.28+0.67/2)
        self.assertEqual(u.build_progress(graph+b'[100/100] Linking\nPackaged KartPad: /x.app\n'),('packaging',0.97))
    def test_rebuild_reports_its_progress_while_it_runs(self):
        state,app,config=self.world();seen=[]
        def build(command,settings,log):
            if command[0]=='fake-build':
                for line in ('[translator] Starting translation\n','Generated validated private Retro Rewind native graph\n','[3/4] Building\n','[1/2] Re-running CMake...\n'):
                    log.write(line);log.flush();time.sleep(0.1)
                    status=self.status();seen.append((status.get('buildStage'),status.get('progress')))
            self.fake_run(command,settings,log)
        with patch.object(u,'BUILD_POLL',0.01):self.run_check(run=build)
        self.assertEqual([stage for stage,_ in seen],['translating','compiling','compiling','compiling'])
        self.assertEqual(seen[2][1],seen[3][1])  # progress never goes backwards
        self.assertAlmostEqual(seen[2][1],0.28+0.67*3/4,places=3)
        self.assertEqual(self.status()['phase'],'ready')
    def test_rebuild_slows_down_only_while_kartpad_races(self):
        state,app,config=self.world();paced=[]
        def build(command,settings,log):
            if command[0]=='fake-build':
                time.sleep(0.1)
                (state/'racing').write_text(str(os.getpid()));time.sleep(0.1)  # a race starts
                (state/'racing').write_text('999999999');time.sleep(0.1)  # a KartPad that quit mid-race
            self.fake_run(command,settings,log)
        with patch.object(u,'BUILD_POLL',0.01),patch.object(u,'pace',side_effect=paced.append):self.run_check(run=build)
        self.assertEqual(paced[0],False)  # full speed from the start
        self.assertIn(True,paced);self.assertEqual(paced[-1],False)
        self.assertFalse(u.racing(state))
    def test_reviewed_update_builds_pending_without_installing(self):
        state,app,config=self.world();original=config.read_text();calls=[]
        self.run_check(self.feed(calls=calls))
        pending=u.load(state/'pending.json')
        self.assertEqual((pending['version'],pending['reviewed']),('6.13.2',True))
        root=Path(pending['root'])
        self.assertFalse((root/'Tracks/gone.szs').exists())  # applied from the official delete list
        self.assertTrue((self.old/'Tracks/gone.szs').exists())
        self.assertEqual(list(root.parent.parent.glob('patch-*.zip')),[])
        self.assertEqual((app/'Contents/MacOS/KartPad').read_text(),'old')
        self.assertEqual(config.read_text(),original)
        self.assertEqual((self.old/'code').read_text(),'old code')
        self.assertEqual(self.status()['phase'],'ready')
        profile=u.load(Path(pending['profile']))['retroRewind']
        self.assertEqual((profile['version'],profile['codePul']['sha256'],profile['updateArchive']),('6.13.2',sha('new code'),review()['retroRewind']['updateArchive']))
        self.assertTrue(u.load(Path(pending['profile']))['localBuildUpdates'][-1]['reviewed'])
        self.assertEqual(calls,[u.FEED,u.REVIEWED,u.DELETIONS,u.CDN+'6.13.2.zip'])
    def test_release_whose_pack_reports_an_older_version(self):
        """Retro Rewind 6.13.3 shipped a version.txt reading 6.13.2; the review pins it as packVersion."""
        state,app,config=self.world()
        pin=review('6.13.3');pin['retroRewind']['updateArchive']['url']=u.CDN+'6.13.3.zip'
        def fetch(url,limit,offset=0):
            if url==u.FEED:return Response(('6.13.3 '+u.CDN+'6.13.3.zip /6.13.3.zip Assets').encode())
            if url==u.DELETIONS:return Response(b'')
            if url==u.REVIEWED:return Response(json.dumps(pin).encode())
            if url==u.CDN+'6.13.3.zip':return Response(PATCH)
            raise AssertionError('unexpected download '+url)
        with self.assertRaises(u.VerificationError):self.run_check(fetch)  # without the pin it's a mismatch
        pin['retroRewind']['packVersion']='6.13.2';self.run_check(fetch,force=True)
        pending=u.load(state/'pending.json')
        self.assertEqual((pending['version'],pending['packVersion'],pending['reviewed']),('6.13.3','6.13.2',True))
        self.assertEqual(u.load(Path(pending['profile']))['retroRewind']['packVersion'],'6.13.2')
        self.assertTrue(self.activate());self.assertEqual(u.load(state/'active.json')['packVersion'],'6.13.2')
        with patch.object(u,'fetch',side_effect=fetch):u.check(self.settings,'6.13.3',state,app)
        self.assertEqual(self.status()['phase'],'current')  # the installed pack passes later checks
        self.assertEqual(u.staged_pack(state,'6.13.3')['packVersion'],'6.13.2')
        self.assertTrue(u.rollback(state,app,config,lambda p:None,'manual'));self.assertEqual(u.configured_root(config),self.old)
    def test_rebuild_without_the_helper_is_not_installed(self):
        state,app,config=self.world();self.unbundled=True
        with self.assertRaises(u.VerificationError):self.run_check()
        self.assertFalse((state/'pending.json').exists());self.assertEqual(u.load(state/'failure.json')['kind'],'verification')
    def test_feed_ahead_of_the_review_waits_for_the_player(self):
        state,app,config=self.world();calls=[]
        self.run_check(self.feed(review('6.13.1'),calls))
        self.assertEqual(calls,[u.FEED,u.REVIEWED])  # nothing downloaded, nothing deleted
        self.assertEqual({k:self.status()[k] for k in ('phase','version','reason','reviewed')},
                         {'phase':'unverified','version':'6.13.2','reason':'unreviewed','reviewed':'6.13.1'})
        self.assertFalse((state/'pending.json').exists());self.assertEqual(self.builds,[])
        self.run_check(self.feed(review('6.13.1')),force=True)
        self.assertFalse((state/'pending.json').exists())
        # The maintainers catch up: it installs as reviewed with no further approval.
        self.run_check(self.feed());self.assertTrue(u.load(state/'pending.json')['reviewed'])
    def test_pinned_archive_mismatch_is_never_built(self):
        state,app,config=self.world();calls=[]
        tampered=zip_bytes({'RetroRewind6/version.txt':'6.13.2','RetroRewind6/code':'new code','RetroRewind6/xml':'new xml','RetroRewind6/extra':'x'})
        self.run_check(self.feed(archive=tampered,calls=calls))
        self.assertEqual((self.status()['phase'],self.status()['reason']),('unverified','mismatch'))
        self.assertEqual(self.builds,[]);self.assertFalse((state/'pending.json').exists())
        self.assertEqual(u.load(state/'failure.json')['kind'],'unverified')
        self.assertEqual([p.name for p in state.iterdir() if u.STAGE.fullmatch(p.name)],[])
        # Automatic checks don't download it again until the review changes or the player asks.
        del calls[:];self.run_check(self.feed(archive=tampered,calls=calls))
        self.assertNotIn(u.CDN+'6.13.2.zip',calls)
        del calls[:];self.run_check(self.feed(archive=tampered,calls=calls),force=True)
        self.assertIn(u.CDN+'6.13.2.zip',calls);self.assertEqual(self.builds,[])
        del calls[:];self.run_check(self.feed(review(archive=tampered),archive=tampered,calls=calls))
        self.assertIn(u.CDN+'6.13.2.zip',calls);self.assertTrue((state/'pending.json').exists())
    def test_code_mismatch_after_extraction_is_never_built(self):
        state,app,config=self.world()
        self.run_check(self.feed(review(code='reviewed code')))
        self.assertEqual((self.status()['phase'],self.status()['reason']),('unverified','mismatch'))
        self.assertIn('code differs',self.status()['message'])
        self.assertEqual(self.builds,[]);self.assertFalse((state/'pending.json').exists())
    def test_player_can_install_an_unreviewed_version(self):
        state,app,config=self.world()
        self.run_check(self.feed(review('6.13.1')))
        self.run_check(self.feed(review('6.13.1')),force=True,allow_unverified='6.13.3')  # not what the feed offers
        self.assertFalse((state/'pending.json').exists())
        self.run_check(self.feed(review('6.13.1')),force=True,allow_unverified='6.13.2')
        self.assertEqual(u.load(state/'approved.json')['version'],'6.13.2')
        pending=u.load(state/'pending.json');self.assertFalse(pending['reviewed'])
        self.assertFalse((Path(pending['root'])/'Tracks/gone.szs').exists())  # deletions apply once approved
        self.activate();self.assertFalse((state/'approved.json').exists())
    def test_approval_still_checks_against_a_review(self):
        state,app,config=self.world()
        self.run_check(self.feed(review(code='reviewed code')))
        self.run_check(self.feed(review(code='reviewed code')),force=True,allow_unverified='6.13.2')
        self.assertFalse(u.load(state/'pending.json')['reviewed'])
        self.assertFalse(u.load(Path(u.load(state/'pending.json')['profile']))['localBuildUpdates'][-1]['packReviewed'])
    def test_failed_build_is_not_repeated_until_forced(self):
        state,app,config=self.world();self.builds=[]
        def broken(command,settings,log):
            self.builds.append(command[0])
            if command[0]=='fake-build':raise u.subprocess.CalledProcessError(1,command)
        with self.assertRaises(u.subprocess.CalledProcessError):self.run_check(run=broken)
        self.assertEqual(u.load(state/'failure.json')['kind'],'build')
        self.run_check(run=broken)
        self.assertEqual(self.builds,['fake-build'])
        with self.assertRaises(u.subprocess.CalledProcessError):self.run_check(run=broken,force=True)
        self.assertEqual(self.builds,['fake-build','fake-build'])
        self.assertEqual([p.name for p in state.iterdir() if u.STAGE.fullmatch(p.name)],[])
    def test_failed_build_on_an_older_checkout_says_so_and_retries_after_a_pull(self):
        state,app,config=self.world();self.builds=[]
        profile=self.root/u.CHECKOUT_PROFILE;profile.parent.mkdir(parents=True)
        profile.write_text(json.dumps({'retroRewind':{'version':'6.13.1'}}))
        def broken(command,settings,log):
            self.builds.append(command[0])
            if command[0]=='fake-build':raise u.subprocess.CalledProcessError(1,command)
        with self.assertRaises(u.OutdatedCheckout):self.run_check(run=broken)
        failure=u.load(state/'failure.json');self.assertEqual(u.error_kind(u.OutdatedCheckout()),'checkout')
        self.assertEqual(failure['kind'],'checkout');self.assertIn('needs a newer KartPad checkout (it has 6.13.1)',failure['message'])
        self.run_check(run=broken);self.assertEqual(self.builds,['fake-build'])  # not repeated as it is
        profile.write_text(json.dumps({'retroRewind':{'version':'6.13.2'}}))  # the maintainers' support is pulled
        self.run_check();self.assertTrue((state/'pending.json').exists())
    def test_offline_checks_back_off_until_forced(self):
        state,app,config=self.world();calls=[]
        def offline(url,limit,offset=0):
            calls.append(url);raise urllib.error.URLError('offline')
        with self.assertRaises(urllib.error.URLError):self.run_check(offline)
        self.run_check(offline)
        self.assertEqual(calls,[u.FEED])
        self.run_check(self.feed(),force=True)
        self.assertTrue((state/'pending.json').exists());self.assertFalse((state/'failure.json').exists())
    def test_declined_version_needs_explicit_approval(self):
        state,app,config=self.world()
        u.atomic_json(state/'declined.json',{'version':'6.13.2','url':None})
        self.run_check()
        self.assertFalse((state/'pending.json').exists())
        self.run_check(force=True)
        self.assertEqual(self.status()['phase'],'declined')
        with self.assertRaises(urllib.error.URLError):self.run_check(urllib.error.URLError('offline'))
        self.run_check(force=True);self.assertEqual(self.status()['phase'],'declined')  # remembered past failures
        self.run_check(force=True,allow_declined=True)
        self.assertTrue((state/'pending.json').exists());self.assertFalse((state/'declined.json').exists())
    def test_offline_check_leaves_installed_app_and_pack_alone(self):
        state,app,config=self.world();original=config.read_text()
        with self.assertRaises(urllib.error.URLError):self.run_check(urllib.error.URLError('offline'))
        self.assertEqual(config.read_text(),original)
        self.assertEqual((app/'Contents/MacOS/KartPad').read_text(),'old')
        self.assertFalse((state/'pending.json').exists())
    def test_pending_update_does_not_rebuild_or_touch_config(self):
        state,app,config=self.world();self.pending();original=config.read_text()
        with patch.object(u,'fetch',side_effect=AssertionError('network not expected')):
            u.check({},'6.13.1',state,app)
        self.assertEqual(config.read_text(),original)

if __name__=='__main__':unittest.main()
