#!/usr/bin/env python3
import errno,importlib.util,io,json,tempfile,unittest,urllib.error,zipfile
from pathlib import Path
from unittest.mock import patch
spec=importlib.util.spec_from_file_location('updater',Path(__file__).with_name('macos-local-updater.py'))
u=importlib.util.module_from_spec(spec);spec.loader.exec_module(u)

class Updates(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.addCleanup(self.tmp.cleanup)
        self.root=Path(self.tmp.name)
    def test_error_messages_can_offer_specific_recovery(self):
        self.assertEqual(u.error_kind(urllib.error.URLError('offline')),'network')
        self.assertEqual(u.error_kind(OSError(errno.ENOSPC,'disk full')),'storage')
        self.assertEqual(u.error_kind(ValueError('At least 8 GB of free disk space is needed to rebuild')),'storage')
        self.assertEqual(u.error_kind(ValueError('Pending pack integrity check failed')),'verification')

    def test_feed_orders_all_intermediate_patches(self):
        text='6.13.2 '+u.CDN+'6.13.2.zip\n6.13.0 '+u.CDN+'6.13.0.zip\n6.13.1 '+u.CDN+'6.13.1.zip'
        self.assertEqual([v for v,url in u.releases(text,'6.12.8')],['6.13.0','6.13.1','6.13.2'])
    def test_feed_rejects_unofficial_url(self):
        with self.assertRaises(ValueError):u.releases('6.13.2 https://evil.example/pack.zip','6.13.1')
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
    def pending(self):
        state=self.root/'state';state.mkdir()
        app=self.root/'KartPad.app';(app/'Contents/MacOS').mkdir(parents=True)
        (app/'Contents/MacOS/KartPad').write_text('old')
        candidate=self.root/'new.app';(candidate/'Contents/MacOS').mkdir(parents=True)
        (candidate/'Contents/MacOS/KartPad').write_text('new')
        root=self.root/'pack';root.mkdir();(root/'version.txt').write_text('6.13.2')
        (root/'code').write_text('code');(root/'xml').write_text('xml')
        profile=self.root/'profile.json';profile.write_text(json.dumps({'retroRewind':{k:{'path':name,'sha256':u.digest(root/name)} for k,name in [('codePul','code'),('riivolutionXml','xml')]}}))
        config=self.root/'Config.toml';config.write_text('[paths]\nretro_rewind_root = "old-pack"\nkeep = true\n')
        u.atomic_json(state/'pending.json',{'version':'6.13.2','root':str(root),'profile':str(profile),'app':str(candidate),'runtimeSha256':u.digest(candidate/'Contents/MacOS/KartPad')})
        return state,app,config
    def test_activate_app_and_pack_together_keeps_backup(self):
        state,app,config=self.pending()
        self.assertTrue(u.activate(state,app,config,lambda p:None))
        self.assertEqual((app/'Contents/MacOS/KartPad').read_text(),'new')
        self.assertEqual((self.root/'KartPad.before-6.13.2.app/Contents/MacOS/KartPad').read_text(),'old')
        self.assertIn('keep = true',config.read_text());self.assertIn(str(self.root/'pack'),config.read_text())
        self.assertFalse((state/'pending.json').exists())
    def test_bad_runtime_cannot_replace_working_app(self):
        state,app,config=self.pending();original=config.read_text()
        (self.root/'new.app/Contents/MacOS/KartPad').write_text('tampered')
        with self.assertRaises(ValueError):u.activate(state,app,config,lambda p:None)
        self.assertEqual((app/'Contents/MacOS/KartPad').read_text(),'old');self.assertEqual(config.read_text(),original)
    def test_bad_pack_cannot_replace_working_app(self):
        state,app,config=self.pending();(self.root/'pack/code').write_text('tampered')
        with self.assertRaises(ValueError):u.activate(state,app,config,lambda p:None)
        self.assertEqual((app/'Contents/MacOS/KartPad').read_text(),'old')
    def test_activation_failure_restores_app_config_and_state(self):
        state,app,config=self.pending();original=config.read_text();atomic=u.atomic_json
        def fail(path,value):
            if path.name=='active.json':raise OSError('simulated disk failure')
            atomic(path,value)
        with patch.object(u,'atomic_json',side_effect=fail):
            with self.assertRaises(OSError):u.activate(state,app,config,lambda p:None)
        self.assertEqual((app/'Contents/MacOS/KartPad').read_text(),'old');self.assertEqual(config.read_text(),original)
        self.assertTrue((state/'pending.json').exists());self.assertFalse((state/'activation.json').exists())
    def test_duplicate_worker_cannot_acquire_lock(self):
        with u.locked(self.root/'state') as first:
            with u.locked(self.root/'state') as second:
                self.assertTrue(first);self.assertFalse(second)
    def test_config_changes_only_pack_path(self):
        original='[paths]\nretro_rewind_root = "old"\n[video]\nvsync = true\n'
        self.assertEqual(u.updated_config(original,Path('/new')),original.replace('"old"','"/new"'))
    def test_background_check_builds_pending_without_installing(self):
        state,app,config=self.pending();(state/'pending.json').unlink()
        old=self.root/'old-pack';old.mkdir();(old/'version.txt').write_text('6.13.1')
        (old/'code').write_text('old code');(old/'xml').write_text('old xml')
        profile=self.root/'old-profile.json'
        profile.write_text(json.dumps({'retroRewind':{'version':'6.13.1',**{key:{'path':name,'bytes':(old/name).stat().st_size,'sha256':u.digest(old/name)} for key,name in [('codePul','code'),('riivolutionXml','xml')]}}}))
        patch_zip=io.BytesIO()
        with zipfile.ZipFile(patch_zip,'w') as z:
            z.writestr('RetroRewind6/version.txt','6.13.2');z.writestr('RetroRewind6/code','new code');z.writestr('RetroRewind6/xml','new xml')
        settings={'initial':{'version':'6.13.1','root':str(old),'profile':str(profile)},'repo':str(self.root),'buildCommand':['fake-build','{profile}','{app}']}
        original=config.read_text()
        def fetch(url,limit):
            return io.BytesIO(('6.13.2 '+u.CDN+'6.13.2.zip').encode() if url==u.FEED else patch_zip.getvalue())
        def run(command,settings,log):
            if command[0]=='fake-build':
                profile=json.loads(Path(command[1]).read_text())['retroRewind']
                target=Path(command[2]);(target/'Contents/MacOS').mkdir(parents=True)
                (target/'Contents/MacOS/KartPad').write_text('new runtime '+profile['codePul']['sha256']+' '+profile['riivolutionXml']['sha256'])
        with patch.object(u,'fetch',side_effect=fetch),patch.object(u,'run',side_effect=run),patch.object(u.shutil,'disk_usage',return_value=type('Disk',(),{'free':20_000_000_000})()):
            u.check(settings,'6.13.1',state,app)
        pending=json.loads((state/'pending.json').read_text())
        self.assertEqual(pending['version'],'6.13.2')
        self.assertEqual((app/'Contents/MacOS/KartPad').read_text(),'old')
        self.assertEqual(config.read_text(),original)
        self.assertEqual((old/'code').read_text(),'old code')
        self.assertEqual(json.loads((state/'status.json').read_text())['phase'],'ready')
    def test_offline_check_leaves_installed_app_and_pack_alone(self):
        state,app,config=self.pending();(state/'pending.json').unlink()
        source=self.root/'pack';(source/'version.txt').write_text('6.13.1')
        profile=self.root/'profile.json'
        settings={'initial':{'version':'6.13.1','root':str(source),'profile':str(profile)}}
        original=config.read_text()
        with patch.object(u,'fetch',side_effect=OSError('offline')):
            with self.assertRaises(OSError):u.check(settings,'6.13.1',state,app)
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

    def test_pending_update_does_not_rebuild_or_touch_config(self):
        state,app,config=self.pending();original=config.read_text()
        with patch.object(u,'fetch',side_effect=AssertionError('network not expected')):
            u.check({},'6.13.1',state,app)
        self.assertEqual(config.read_text(),original)

if __name__=='__main__':unittest.main()
