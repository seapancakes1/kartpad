#!/usr/bin/env python3
import errno,importlib.util,io,json,os,tempfile,time,unittest,urllib.error,zipfile
from pathlib import Path,PurePosixPath
from unittest.mock import patch
spec=importlib.util.spec_from_file_location('updater',Path(__file__).with_name('macos-local-updater.py'))
u=importlib.util.module_from_spec(spec);spec.loader.exec_module(u)
ROOMY=type('Disk',(),{'free':20_000_000_000})()

def zip_bytes(files):
    data=io.BytesIO()
    with zipfile.ZipFile(data,'w') as z:
        for name,text in files.items():z.writestr(name,text)
    return data.getvalue()

class Response(io.BytesIO):
    def __init__(self,data,status=200):
        super().__init__(data);self.status=status;self.headers={'Content-Length':str(len(data))}

class Updates(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.addCleanup(self.tmp.cleanup)
        self.root=Path(self.tmp.name).resolve()
    def test_error_messages_can_offer_specific_recovery(self):
        self.assertEqual(u.error_kind(urllib.error.URLError('offline')),'network')
        self.assertEqual(u.error_kind(TimeoutError('slow')),'network')
        self.assertEqual(u.error_kind(OSError(errno.ENOSPC,'disk full')),'storage')
        self.assertEqual(u.error_kind(u.StorageError('At least 8 GB of free disk space is needed to rebuild')),'storage')
        self.assertEqual(u.error_kind(u.VerificationError('Pending pack integrity check failed')),'verification')
        # Wording no longer decides the kind: a settings mismatch is configuration.
        self.assertEqual(u.error_kind(ValueError('Updater settings do not match this app version')),'configuration')

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

    def pending(self):
        state=self.root/'state';state.mkdir()
        app=self.root/'Apps/KartPad.app';(app/'Contents/MacOS').mkdir(parents=True)
        (app/'Contents/MacOS/KartPad').write_text('old')
        stage=state/'6.13.2-abc';candidate=stage/'KartPad.app';(candidate/'Contents/MacOS').mkdir(parents=True)
        (candidate/'Contents/MacOS/KartPad').write_text('new')
        root=stage/'pack/RetroRewind6';root.mkdir(parents=True);(root/'version.txt').write_text('6.13.2')
        (root/'code').write_text('code');(root/'xml').write_text('xml')
        profile=stage/'profile.json';profile.write_text(json.dumps({'retroRewind':{k:{'path':name,'sha256':u.digest(root/name)} for k,name in [('codePul','code'),('riivolutionXml','xml')]}}))
        old=self.root/'old-pack';old.mkdir();(old/'version.txt').write_text('6.13.1')
        self.initial={'version':'6.13.1','root':str(old),'profile':str(self.root/'old-profile.json')}
        config=self.root/'Config.toml';config.write_text('[paths]\nretro_rewind_root = "old-pack"\nkeep = true\n')
        u.atomic_json(state/'pending.json',{'version':'6.13.2','url':u.CDN+'6.13.2.zip','root':str(root),'profile':str(profile),'app':str(candidate),'runtimeSha256':u.digest(candidate/'Contents/MacOS/KartPad')})
        return state,app,config
    def activate(self,state,app,config):
        return u.activate(state,app,config,lambda p:None,self.initial)

    def test_activate_app_and_pack_together_keeps_backup(self):
        state,app,config=self.pending()
        self.assertTrue(self.activate(state,app,config))
        self.assertEqual((app/'Contents/MacOS/KartPad').read_text(),'new')
        self.assertEqual((app.with_name('KartPad.before-6.13.2.app')/'Contents/MacOS/KartPad').read_text(),'old')
        self.assertIn('keep = true',config.read_text());self.assertIn(str(state/'6.13.2-abc/pack/RetroRewind6'),config.read_text())
        self.assertFalse((state/'pending.json').exists())
        self.assertEqual(u.load(state/'trial.json'),{'version':'6.13.2','launches':0})
        self.assertEqual(u.load(state/'rollback.json')['version'],'6.13.1')
    def test_activation_removes_the_spare_candidate_and_older_versions(self):
        state,app,config=self.pending()
        older=state/'6.12.8-old';(older/'pack').mkdir(parents=True)
        stale=app.with_name('KartPad.before-6.12.8.app');stale.mkdir()
        self.activate(state,app,config)
        self.assertFalse((state/'6.13.2-abc/KartPad.app').exists())
        self.assertTrue((state/'6.13.2-abc/pack/RetroRewind6/code').exists())
        self.assertFalse(older.exists());self.assertFalse(stale.exists())
        self.assertTrue(app.with_name('KartPad.before-6.13.2.app').exists())
    def test_existing_backup_name_does_not_block_activation(self):
        state,app,config=self.pending()
        app.with_name('KartPad.before-6.13.2.app').mkdir()
        self.assertTrue(self.activate(state,app,config))
        self.assertEqual(Path(u.load(state/'rollback.json')['app']).name,'KartPad.before-6.13.2-2.app')
    def test_leftover_unjournaled_copy_does_not_block_activation(self):
        state,app,config=self.pending()
        (app.with_name('.KartPad.update.app')/'partial').mkdir(parents=True)
        self.assertTrue(self.activate(state,app,config))
        self.assertFalse(app.with_name('.KartPad.update.app').exists())
    def test_bad_runtime_cannot_replace_working_app(self):
        state,app,config=self.pending();original=config.read_text()
        (state/'6.13.2-abc/KartPad.app/Contents/MacOS/KartPad').write_text('tampered')
        with self.assertRaises(ValueError):self.activate(state,app,config)
        self.assertEqual((app/'Contents/MacOS/KartPad').read_text(),'old');self.assertEqual(config.read_text(),original)
    def test_rejected_build_is_discarded_so_updates_continue(self):
        state,app,config=self.pending();(state/'6.13.2-abc/pack/RetroRewind6/code').write_text('tampered')
        with self.assertRaises(ValueError):self.activate(state,app,config)
        self.assertEqual((app/'Contents/MacOS/KartPad').read_text(),'old')
        self.assertFalse((state/'pending.json').exists());self.assertFalse((state/'6.13.2-abc').exists())
        failure=u.load(state/'failure.json')
        self.assertEqual((failure['kind'],failure['version']),('verification','6.13.2'))
    def test_activation_failure_restores_app_config_and_state(self):
        state,app,config=self.pending();original=config.read_text();atomic=u.atomic_json
        def fail(path,value):
            if path.name=='active.json':raise OSError(errno.ENOSPC,'disk full')
            atomic(path,value)
        with patch.object(u,'atomic_json',side_effect=fail):
            with self.assertRaises(OSError):self.activate(state,app,config)
        self.assertEqual((app/'Contents/MacOS/KartPad').read_text(),'old');self.assertEqual(config.read_text(),original)
        # Out of space is worth retrying, so the build stays pending.
        self.assertTrue((state/'pending.json').exists());self.assertFalse((state/'activation.json').exists())
        self.assertFalse((state/'trial.json').exists());self.assertFalse((state/'rollback.json').exists())
    def test_duplicate_worker_cannot_acquire_lock(self):
        with u.locked(self.root/'state') as first:
            with u.locked(self.root/'state') as second:
                self.assertTrue(first);self.assertFalse(second)
    def test_config_changes_only_pack_path(self):
        original='[paths]\nretro_rewind_root = "old"\n[video]\nvsync = true\n'
        self.assertEqual(u.updated_config(original,Path('/new')),original.replace('"old"','"/new"'))

    def test_rollback_restores_previous_app_pack_and_later_settings(self):
        state,app,config=self.pending();self.activate(state,app,config)
        config.write_text(config.read_text()+'changed_after_update = true\n')
        u.rollback(state,app,config,lambda p:None,'manual')
        self.assertEqual((app/'Contents/MacOS/KartPad').read_text(),'old')
        self.assertIn('retro_rewind_root = '+json.dumps(self.initial['root']),config.read_text())
        self.assertIn('changed_after_update = true',config.read_text())
        self.assertFalse((state/'active.json').exists());self.assertFalse((state/'rollback.json').exists())
        self.assertEqual(u.load(state/'failure.json')['kind'],'declined')
        self.assertEqual(u.load(state/'status.json')['phase'],'rolledBack')
    def test_new_app_that_keeps_failing_is_rolled_back(self):
        state,app,config=self.pending();self.activate(state,app,config)
        verify=lambda p:None
        for launch in range(u.TRIAL_LAUNCHES):
            self.assertFalse(u.trial(state,app,config,verify,'6.13.2'))
        self.assertEqual(u.load(state/'trial.json')['launches'],u.TRIAL_LAUNCHES)
        self.assertTrue(u.trial(state,app,config,verify,'6.13.2'))
        self.assertEqual((app/'Contents/MacOS/KartPad').read_text(),'old')
        self.assertEqual(u.load(state/'status.json')['reason'],'unstable')
    def test_failed_automatic_rollback_is_reported_once(self):
        state,app,config=self.pending();self.activate(state,app,config)
        u.atomic_json(state/'trial.json',{'version':'6.13.2','launches':u.TRIAL_LAUNCHES})
        def missing(path):raise u.subprocess.CalledProcessError(1,['codesign'])
        with self.assertRaises(u.subprocess.CalledProcessError):u.trial(state,app,config,missing,'6.13.2')
        self.assertFalse((state/'trial.json').exists())
        self.assertEqual((app/'Contents/MacOS/KartPad').read_text(),'new')
    def test_confirmed_app_is_not_rolled_back(self):
        state,app,config=self.pending();self.activate(state,app,config)
        (state/'trial.json').unlink()  # the app removes it once it has run long enough
        self.assertFalse(u.trial(state,app,config,lambda p:None,'6.13.2'))
        self.assertEqual((app/'Contents/MacOS/KartPad').read_text(),'new')

    def installed(self,state):
        old=self.root/'old-pack';old.mkdir(exist_ok=True);(old/'version.txt').write_text('6.13.1')
        (old/'code').write_text('old code');(old/'xml').write_text('old xml');(old/'Tracks').mkdir(exist_ok=True)
        (old/'Tracks/gone.szs').write_text('removed in 6.13.2')
        profile=self.root/'old-profile.json'
        profile.write_text(json.dumps({'retroRewind':{'version':'6.13.1',**{key:{'path':name,'bytes':(old/name).stat().st_size,'sha256':u.digest(old/name)} for key,name in [('codePul','code'),('riivolutionXml','xml')]}}}))
        return {'initial':{'version':'6.13.1','root':str(old),'profile':str(profile)},'repo':str(self.root),'buildCommand':['fake-build','{profile}','{app}']},old
    def feed(self,calls=None):
        patch_zip=zip_bytes({'RetroRewind6/version.txt':'6.13.2','RetroRewind6/code':'new code','RetroRewind6/xml':'new xml'})
        def fetch(url,limit,offset=0):
            if calls is not None:calls.append(url)
            if url==u.FEED:return Response(('6.13.2 '+u.CDN+'6.13.2.zip /6.13.2.zip Assets').encode())
            if url==u.DELETIONS:return Response(b'6.13.2 /RetroRewind6/Tracks/gone.szs\n6.13.2 /6.13.2.zip\n')
            return Response(patch_zip)
        return fetch
    def fake_run(self,command,settings,log):
        if command[0]=='fake-build':
            profile=json.loads(Path(command[1]).read_text())['retroRewind']
            target=Path(command[2]);(target/'Contents/MacOS').mkdir(parents=True)
            (target/'Contents/MacOS/KartPad').write_text('new runtime '+profile['codePul']['sha256']+' '+profile['riivolutionXml']['sha256'])
    def run_check(self,settings,state,app,fetch=None,run=None,**options):
        with patch.object(u,'fetch',side_effect=fetch or self.feed()),patch.object(u,'run',side_effect=run or self.fake_run),patch.object(u.shutil,'disk_usage',return_value=ROOMY):
            u.check(settings,'6.13.1',state,app,**options)

    def test_background_check_builds_pending_without_installing(self):
        state,app,config=self.pending();(state/'pending.json').unlink()
        settings,old=self.installed(state);original=config.read_text()
        self.run_check(settings,state,app)
        pending=json.loads((state/'pending.json').read_text())
        self.assertEqual(pending['version'],'6.13.2')
        root=Path(pending['root'])
        self.assertFalse((root/'Tracks/gone.szs').exists())  # applied from the official delete list
        self.assertTrue((old/'Tracks/gone.szs').exists())
        self.assertEqual(list(root.parent.parent.glob('patch-*.zip')),[])
        self.assertEqual((app/'Contents/MacOS/KartPad').read_text(),'old')
        self.assertEqual(config.read_text(),original)
        self.assertEqual((old/'code').read_text(),'old code')
        self.assertEqual(json.loads((state/'status.json').read_text())['phase'],'ready')
    def test_failed_build_is_not_repeated_until_forced(self):
        state,app,config=self.pending();(state/'pending.json').unlink()
        settings,old=self.installed(state);builds=[]
        def broken(command,settings,log):
            builds.append(command[0])
            if command[0]=='fake-build':raise u.subprocess.CalledProcessError(1,command)
        with self.assertRaises(u.subprocess.CalledProcessError):self.run_check(settings,state,app,run=broken)
        self.assertEqual(u.load(state/'failure.json')['kind'],'build')
        self.run_check(settings,state,app,run=broken)
        self.assertEqual(builds,['fake-build'])
        with self.assertRaises(u.subprocess.CalledProcessError):self.run_check(settings,state,app,run=broken,force=True)
        self.assertEqual(builds,['fake-build','fake-build'])
        self.assertEqual([p.name for p in state.iterdir() if u.STAGE.fullmatch(p.name)],[])
    def test_offline_checks_back_off_until_forced(self):
        state,app,config=self.pending();(state/'pending.json').unlink()
        settings,old=self.installed(state);calls=[]
        def offline(url,limit,offset=0):
            calls.append(url);raise urllib.error.URLError('offline')
        with self.assertRaises(urllib.error.URLError):self.run_check(settings,state,app,fetch=offline)
        self.run_check(settings,state,app,fetch=offline)
        self.assertEqual(calls,[u.FEED])
        self.run_check(settings,state,app,fetch=self.feed(),force=True)
        self.assertTrue((state/'pending.json').exists());self.assertFalse((state/'failure.json').exists())
    def test_declined_version_needs_explicit_approval(self):
        state,app,config=self.pending();(state/'pending.json').unlink()
        settings,old=self.installed(state)
        u.remember(state,'declined','6.13.2')
        self.run_check(settings,state,app)
        self.assertFalse((state/'pending.json').exists())
        self.run_check(settings,state,app,force=True)
        self.assertEqual(u.load(state/'status.json')['phase'],'declined')
        self.run_check(settings,state,app,force=True,allow_declined=True)
        self.assertTrue((state/'pending.json').exists())
    def test_offline_check_leaves_installed_app_and_pack_alone(self):
        state,app,config=self.pending();(state/'pending.json').unlink()
        source=self.root/'pack';source.mkdir();(source/'version.txt').write_text('6.13.1')
        (source/'code').write_text('code');(source/'xml').write_text('xml')
        profile=self.root/'profile.json'
        profile.write_text(json.dumps({'retroRewind':{k:{'path':name,'sha256':u.digest(source/name)} for k,name in [('codePul','code'),('riivolutionXml','xml')]}}))
        settings={'initial':{'version':'6.13.1','root':str(source),'profile':str(profile)}}
        original=config.read_text()
        with patch.object(u,'fetch',side_effect=urllib.error.URLError('offline')):
            with self.assertRaises(urllib.error.URLError):u.check(settings,'6.13.1',state,app)
        self.assertEqual(config.read_text(),original)
        self.assertEqual((app/'Contents/MacOS/KartPad').read_text(),'old')
        self.assertFalse((state/'pending.json').exists())

    def test_crash_recovery_restores_previous_active_metadata(self):
        state,app,config=self.pending();original=config.read_text()
        pending=json.loads((state/'pending.json').read_text())
        previous={'version':'6.13.1','root':'old-pack','profile':'old-profile'}
        backup=self.root/'backup.app';app.rename(backup)
        app.mkdir();(app/'bad').write_text('interrupted installation')
        config.write_text('interrupted config')
        u.atomic_json(state/'active.json',{'version':'6.13.2'})
        u.atomic_json(state/'activation.json',{'app':str(app),'backup':str(backup),'config':str(config),'originalConfig':original,'previousActive':previous,'pending':pending,'staged':str(self.root/'staged.app')})
        u.recover(state)
        self.assertEqual(config.read_text(),original)
        self.assertEqual((app/'Contents/MacOS/KartPad').read_text(),'old')
        self.assertEqual(json.loads((state/'active.json').read_text()),previous)
    def test_interrupted_transaction_is_undone_at_every_step(self):
        for completed in range(3):
            with self.subTest(completed=completed):
                self.root=Path(self.tmp.name).resolve()/f'run{completed}';self.root.mkdir()
                state,app,config=self.pending();original=config.read_text();before=u.snapshot(state)
                staged=app.with_name('.KartPad.update.app');u.clone(state/'6.13.2-abc/KartPad.app',staged)
                backup=app.with_name('KartPad.before-6.13.2.app');moves=[(app,backup),(staged,app)]
                u.atomic_json(state/'activation.json',{'moves':[[str(a),str(b)] for a,b in moves],'config':str(config),'originalConfig':original,'previous':before})
                for source,target in moves[:completed]:os.replace(source,target)
                if completed==2:config.write_text('half written');u.atomic_json(state/'active.json',{'version':'6.13.2'})
                u.recover(state)
                self.assertEqual((app/'Contents/MacOS/KartPad').read_text(),'old')
                self.assertEqual(config.read_text(),original);self.assertEqual(u.snapshot(state),before)
                self.assertFalse(backup.exists());self.assertFalse((state/'activation.json').exists())

    def test_pending_update_does_not_rebuild_or_touch_config(self):
        state,app,config=self.pending();original=config.read_text()
        with patch.object(u,'fetch',side_effect=AssertionError('network not expected')):
            u.check({},'6.13.1',state,app)
        self.assertEqual(config.read_text(),original)

if __name__=='__main__':unittest.main()
