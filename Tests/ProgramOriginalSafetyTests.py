#!/usr/bin/env python3
"""Narrow real-filesystem program identity tests; no real App, data, or registration."""
import base64
import copy
import contextlib
import io
import ctypes
import json
import os
from pathlib import Path
import plistlib
import pwd
import runpy
import shutil
import stat
import subprocess
import sys
import tempfile
import uuid

ROOT = Path(__file__).resolve().parents[1]
loaded = runpy.run_path(str(ROOT / 'Scripts/backup_verify.py'), run_name='portal_program_identity_fixture')
m = loaded['application_record'].__globals__
checks = 0

def check(condition, label):
    global checks
    if not condition:
        raise AssertionError(label)
    checks += 1
    print('PASS', checks, label, flush=True)

def reject(action, marker, label):
    try:
        action()
    except RuntimeError as error:
        check(marker in str(error), label + ': precise rejection')
    else:
        raise AssertionError(label + ': unsafe action accepted')

class Crash(BaseException):
    pass

def stop_at(point):
    def fault(at):
        if at == point:
            raise Crash()
    return fault

with tempfile.TemporaryDirectory(prefix='portal-program-safety-', suffix='.noindex', dir='/private/tmp') as raw:
    outer = Path(raw)
    original_load = m['load_state']
    fixtures = []
    commands = []
    def command(args):
        if args[0] == '/usr/bin/codesign':
            assert args[1:3] == ['--verify', '--strict'] and Path(args[-1]).is_relative_to(outer)
        elif args[0] == m['APP_LSREGISTER']:
            assert args[1] in ('-u', '-f') and Path(args[-1]).is_relative_to(outer)
        else:
            raise AssertionError('unexpected external command: ' + args[0])
        commands.append(args)
    m['run_checked'] = command
    m['stop_owned_processes'] = lambda: None
    def forbidden(*a, **kw):
        raise AssertionError('real/private data or credentials accessed')
    for key in ('preferences', 'native_hosts', 'keychain_metadata', 'snapshot', 'verify'):
        m[key] = forbidden

    class Fixture:
        def __init__(self):
            self.root = outer / str(uuid.uuid4()); self.root.mkdir(mode=0o700)
            self.apps = self.root / 'Applications'; self.apps.mkdir(mode=0o700)
            self.backups = self.root / 'Backups'; self.backups.mkdir(mode=0o700)
            self.backup = self.backups / ('升级-' + str(uuid.uuid4()) + '.noindex'); self.backup.mkdir(mode=0o700)
            self.prev = self.backup / 'PreviousApplications'; self.prev.mkdir(mode=0o700)
            self.stage = self.apps / ('.GaoMenHu-install-' + str(uuid.uuid4()) + '.noindex'); self.stage.mkdir(mode=0o700)
            self.old = self.apps / '搞门户.app'; self.new = self.stage / '搞门户.app'
            self.fake(self.old, '1.16'); self.fake(self.new, '1.17')
            self.use()
            state = {'format':1,'appID':m['APP_ID'],'phase':'replacing','oldApplications':['搞门户.app'],
                     'newVersion':'1.17','newBuild':'117'}
            m['private_write'](self.backup / 'state.json', m['_app_json'](state))
            m['bind_application_safety'](self.backup, {'搞门户.app': self.old}, self.new)
            self.before = m['application_record'](self.old)
            fixtures.append(self)
        def use(self):
            m['APPLICATIONS'] = self.apps
            m['BACKUPS'] = self.backups
            m['load_state'] = lambda path: original_load(path, self.backups)
            # Registration parsing has its own focused synthetic suite. Keep
            # this original-identity fixture isolated from every real LS query.
            def registration_view():
                rows = []
                for name in m['APP_NAMES']:
                    path = self.apps / name
                    if path.exists():
                        record = m['application_record'](path)
                        rows.append({'identifier': m['APP_ID'], 'path': str(path),
                                     'inode': record['metadataTree']['.']['ino'],
                                     'executableInode': record['metadataTree']['Contents/MacOS/MenDao']['ino']})
                return rows
            m['query_application_registration'] = registration_view
        def fake(self, path, version):
            assert any(p.name.endswith('.noindex') and p.is_dir() for p in path.parents)
            m['private_write'](path / 'Contents/Info.plist', plistlib.dumps({'CFBundleIdentifier':m['APP_ID'],
                'CFBundleExecutable':'MenDao','CFBundleShortVersionString':version,'CFBundleVersion':version.replace('.','')}))
            m['private_write'](path / 'Contents/MacOS/MenDao', b'non-executable synthetic program ' + version.encode())
        def retire(self, **kwargs):
            self.use(); return m['move_application_original'](self.backup,'old:搞门户.app',self.prev/'搞门户.app',**kwargs)
        def installed(self):
            self.retire();m['move_application_original'](self.backup,'new',self.apps/'搞门户.app')
            state=m['load_state'](self.backup);state['phase']='installed';m['update_state'](self.backup,state)

    f=Fixture()
    import fcntl
    lock_fd=os.open(f.backups/'.program-maintenance.lock',os.O_RDWR)
    try:
        fcntl.flock(lock_fd,fcntl.LOCK_EX|fcntl.LOCK_NB)
        reject(f.retire,'已有本App程序维护','concurrent maintenance cannot append or move original')
        check(f.old.exists() and len(m['application_authority'](f.backup)['events'])==1,'busy maintenance lock leaves origin and chain unchanged')
    finally:fcntl.flock(lock_fd,fcntl.LOCK_UN);os.close(lock_fd)

    f = Fixture(); after=f.retire()
    check(after['metadataTree']['.']['ino']==f.before['metadataTree']['.']['ino'], 'actual exclusive move preserves original inode')
    check(after['files']==f.before['files'] and all(k in after['metadataTree']['.'] for k in ('dev','uid','gid','mode','flags','mtime_ns','acl','xattrs_b64')), 'full tree content and native metadata/ACL captured')
    check(m['application_authority'](f.backup)['objects']['old:搞门户.app']['path']==str(f.prev/'搞门户.app'), 'sealed restoration pointer is exact')
    m['move_application_original'](f.backup,'old:搞门户.app',f.old)
    check(f.old.stat().st_ino==f.before['metadataTree']['.']['ino'], 'original inode survives return to formal fixture path')

    f=Fixture(); occupied=f.prev/'搞门户.app';f.fake(occupied,'9.99'); occupied_ino=occupied.stat().st_ino
    reject(f.retire,'已占用','preexisting destination cannot be overwritten')
    check(occupied.stat().st_ino==occupied_ino and f.old.stat().st_ino==f.before['metadataTree']['.']['ino'], 'occupied target and original both retained')

    f=Fixture()
    def race(at):
        if at=='afterMoveIntent':f.fake(f.prev/'搞门户.app','9.98')
    reject(lambda:f.retire(checkpoint=race),'排他原件搬移失败','target appearing after intent is excluded atomically')
    check(f.old.exists() and m['app_info'](f.prev/'搞门户.app')['CFBundleShortVersionString']=='9.98', 'racing object and source preserved')

    f=Fixture(); held=f.root/'Held.noindex';held.mkdir();os.rename(f.old,held/'搞门户.app');shutil.copytree(held/'搞门户.app',f.old)
    reject(f.retire,'不可变链不符','same bytes under replacement inode cannot impersonate original')
    check((held/'搞门户.app').stat().st_ino==f.before['metadataTree']['.']['ino'], 'displaced original retained')

    def fixture_xattr(path):
        lib=m['_app_libc']()
        lib.fsetxattr.argtypes=[ctypes.c_int,ctypes.c_char_p,ctypes.c_void_p,ctypes.c_size_t,ctypes.c_uint32,ctypes.c_int]
        lib.fsetxattr.restype=ctypes.c_int
        fd=os.open(path,os.O_RDONLY);value=b'synthetic-attribute'
        try:
            if lib.fsetxattr(fd,b'user.portal_fixture',value,len(value),0,0)!=0:raise AssertionError('fixture xattr setup failed')
        finally:os.close(fd)

    for change,label in (
        (lambda p:os.chmod(p,0o640),'mode'),
        (fixture_xattr,'user xattr'),
        (lambda p:os.chflags(p,stat.UF_NODUMP),'file flags'),
        (lambda p:subprocess.run(['/bin/chmod','+a','user:'+pwd.getpwuid(os.getuid()).pw_name+' allow readattr',str(p)],check=True,capture_output=True),'ACL')):
        f=Fixture(); binary=f.old/'Contents/MacOS/MenDao';change(binary)
        reject(f.retire,'不可变链不符',label+' change blocks move without altering app')
        check(f.old.exists() and len(m['application_authority'](f.backup)['events'])==1, label+' rejection occurs before any move intent')

    # Only a comparator fixture simulates provenance bytes. No system xattr is written.
    f=Fixture(); changed=copy.deepcopy(f.before);changed['metadataTree']['.']['xattrs_b64'][m['APP_PROVENANCE']]=base64.b64encode(b'synthetic OS transition').decode()
    delta=m['_application_move_delta'](f.before,changed,True)
    check(delta['name']=='com.apple.provenance' and delta['observedOnlyAcrossThisNativeRename'], 'exact root provenance difference requires observed native boundary')
    reject(lambda:m['_application_move_delta'](f.before,changed,False),'未封存','unsealed crash does not authorize provenance difference')
    child=copy.deepcopy(f.before);child['metadataTree']['Contents']['xattrs_b64'][m['APP_PROVENANCE']]='AA=='
    reject(lambda:m['_application_move_delta'](f.before,child,True),'provenance以外','child provenance is never a root exception')
    changed['metadataTree']['Contents']['mode'] ^= 0o010
    reject(lambda:m['_application_move_delta'](f.before,changed,True),'其他属性差异','root provenance never masks another metadata change')

    for point in ('afterMoveIntent','afterNativeRename','afterMoveReceipt','afterMoveCommitted'):
        f=Fixture()
        try:f.retire(checkpoint=stop_at(point))
        except Crash:pass
        else:raise AssertionError('no interruption at '+point)
        chain=m['recover_application_move'](f.backup)
        item=chain['objects']['old:搞门户.app'];path=Path(item['path'])
        check(path.stat().st_ino==f.before['metadataTree']['.']['ino'], point+' retains exact recoverable inode')
        if path!=f.old:m['move_application_original'](f.backup,'old:搞门户.app',f.old)
        check(f.old.stat().st_ino==f.before['metadataTree']['.']['ino'], point+' resumes through sealed pointer without data restore')

    f=Fixture()
    try:f.retire(checkpoint=stop_at('afterMoveIntent'))
    except Crash:pass
    os.rename(f.prev,f.backup/'HeldParent.noindex');f.prev.mkdir(mode=0o700)
    reject(lambda:m['recover_application_move'](f.backup),'父路径身份改变','replaced parent after interruption cannot be reinterpreted')
    check(f.old.exists(),'parent mismatch leaves original untouched')

    f=Fixture();event=next((f.backup/'ApplicationSafety').iterdir());data=json.loads(event.read_bytes());data['objects']['old:搞门户.app']['record']['metadataTree']['.']['uid']+=1;event.write_bytes(m['_app_json'](data))
    reject(lambda:m['application_authority'](f.backup),'摘要改变','immutable receipt tampering rejected')
    check(f.old.exists(),'corrupt receipt cannot move/delete original')

    f=Fixture();f.installed();original_inode=f.before['metadataTree']['.']['ino']
    # Actual public rollback path uses fake signatures/registrations and forbids all private data access.
    fail_once=[True]
    def registration_failure(args):
        if args[0]==m['APP_LSREGISTER'] and fail_once[0]:fail_once[0]=False;raise RuntimeError('fixture registration interruption')
        command(args)
    m['run_checked']=registration_failure
    reject(lambda:m['rollback'](f.backup,no_open=True),'fixture registration interruption','registration failure keeps rollback resumable')
    check(m['load_state'](f.backup)['phase']=='rollingBack' and f.old.stat().st_ino==original_inode,'rollback retains original after registration failure')
    m['run_checked']=command;m['rollback'](f.backup,no_open=True)
    check(m['load_state'](f.backup)['phase']=='rolledBack' and f.old.stat().st_ino==original_inode,'registration retry commits final phase without replacing inode')
    check((f.backup/'FailedApplication.noindex/搞门户.app').exists(),'failed new program preserved inside noindex')
    check(any(x[0]==m['APP_LSREGISTER'] and x[1]=='-f' and x[2]==str(f.old) for x in commands),'only precise owned formal registration requested')

    f=Fixture();f.installed();old_inode=f.before['metadataTree']['.']['ino']
    verify_calls=[]
    def fixture_data_verify(*args,**kwargs):
        verify_calls.append(True)
        return {'dataVerification':{'fixtureOnly':True}}
    m['verify']=fixture_data_verify
    fail_once[0]=True;m['run_checked']=registration_failure
    reject(lambda:m['finalize'](f.backup),'fixture registration interruption','registration failure keeps finalization resumable')
    check(m['load_state'](f.backup)['phase']=='installed','failed registration cannot claim finalized acceptance')
    m['run_checked']=command;m['finalize'](f.backup)
    check(m['load_state'](f.backup)['phase']=='finalized' and len(verify_calls)==2,'finalization retry repeats acceptance guard before terminal phase')
    check((f.prev/'搞门户.app').stat().st_ino==old_inode,'finalization retains the same original in noindex long term')
    m['verify']=forbidden

    f=Fixture();identity=(f.stage.stat().st_dev,f.stage.stat().st_ino)
    m['_cleanup_empty_program_stage'](f.stage,identity,f.backup)
    check(f.new.exists() and list(f.backup.glob('程序暂存保留-*.json')),'nonempty stage retained with maintenance pointer, never recursively deleted')
    held=f.root/'HeldStage.noindex';os.rename(f.stage,held);f.stage.mkdir(mode=0o700)
    m['_cleanup_empty_program_stage'](f.stage,identity,f.backup)
    check(f.stage.exists() and (held/'搞门户.app').exists(),'replacement stage identity cannot be deleted even when empty')

    # Exercise only the real install coordinator with nonexecutable fake images,
    # fake codesign/registration, and synthetic data callbacks.
    for fail_stage in (True,False):
        f=Fixture();before_inode=f.old.stat().st_ino
        project=f.root/'Project';project.mkdir();m['ROOT']=project
        m['private_write'](project/'VERSION',b'1.17\n')
        package=project/'Release/GaoMenHu-1.17.dmg';m['private_write'](package,b'fake disk image')
        m['private_write'](package.with_suffix('.dmg.sha256'),(m['digest'](package.read_bytes())+'  '+package.name+'\n').encode())
        backups=f.root/'InstallBackups';backups.mkdir(mode=0o700);m['BACKUPS']=backups
        m['load_state']=lambda path:original_load(path,backups)
        home=f.root/'Home';lib=home/'Library/Application Support/MenDao/library.json'
        m['private_write'](lib,b'{"schema":1,"sites":[],"tiles":[],"appearance":"system"}')
        raw_library=lib.read_bytes();made=[];stage_paths=[];mount_paths=[]
        def fixture_snapshot():
            path=backups/('升级-'+str(uuid.uuid4())+'.noindex');path.mkdir(mode=0o700)
            m['private_write'](path/'state.json',m['_app_json']({'format':1,'appID':m['APP_ID'],'phase':'backedUp','oldApplications':[]}))
            made.append(path);return path
        m['snapshot']=fixture_snapshot;m['preferences']=lambda:None;m['native_hosts']=lambda home:{}
        m['verify']=lambda *args,**kwargs:{'dataVerification':{'synthetic':True}}
        real_mkdtemp=tempfile.mkdtemp
        def fixture_mkdtemp(*args,**kwargs):
            if kwargs.get('dir')=='/private/tmp':kwargs['dir']=f.root
            return real_mkdtemp(*args,**kwargs)
        def install_command(args):
            if args[:2]==['/usr/bin/hdiutil','attach']:
                mount=Path(args[args.index('-mountpoint')+1]);mount_paths.append(mount);f.fake(mount/'搞门户.app','1.17')
            elif args[0]=='/usr/bin/ditto':
                target=Path(args[2]);stage_paths.append(target.parent);shutil.copytree(args[1],args[2])
                if fail_stage:(target/'Contents/MacOS/MenDao').write_bytes(b'unknown unverified candidate bytes')
            elif args[:2]==['/usr/bin/hdiutil','detach']:
                shutil.rmtree(Path(args[-1])/'搞门户.app')  # fixture teardown, not production cleanup
            elif args[0]=='/usr/bin/codesign' and fail_stage and Path(args[-1]).parent in stage_paths:
                raise RuntimeError('synthetic invalid stage signature')
            else:command(args)
        m['run_checked']=install_command;tempfile.mkdtemp=fixture_mkdtemp
        try:
            if fail_stage:
                reject(lambda:m['install'](no_open=True,home=home),'synthetic invalid stage','unverified staged code aborts before retiring original')
                check(f.old.stat().st_ino==before_inode and stage_paths[0].exists(),'failed install retains both original and unverified noindex stage')
                check(list(backups.glob('程序暂存保留-*.json')) and not made,'pre-backup failed stage has exact maintenance pointer')
            else:
                with contextlib.redirect_stdout(io.StringIO()):m['install'](no_open=True,home=home)
                check(m['load_state'](made[0])['phase']=='installed' and m['app_info'](f.old)['CFBundleVersion']=='117','actual install coordinator commits only fully bound fixture candidate')
                check((made[0]/'PreviousApplications/搞门户.app').stat().st_ino==before_inode,'actual install coordinator keeps old original inode long term')
                check(not stage_paths[0].exists(),'only verified empty successful stage container is removed')
            check(all(not path.exists() for path in mount_paths) and lib.read_bytes()==raw_library,'install fixture detaches only its image and never restores old data')
        finally:tempfile.mkdtemp=real_mkdtemp
    m['run_checked']=command
    for key in ('preferences','native_hosts','snapshot','verify'):m[key]=forbidden

    f=Fixture();state=m['load_state'](f.backup);del state['applicationSafety'];m['update_state'](f.backup,state)
    reject(lambda:m['rollback'](f.backup,no_open=True),'完整程序身份链','historical bytes-only receipt not silently adopted as authority')
    check(f.old.exists(),'legacy uncertainty preserves original and old receipt')

print('Program original safety:',checks,'isolated checks passed; no real App, data, Keychain, UI, registration or snapshot modified.')
