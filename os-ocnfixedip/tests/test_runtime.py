import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = ROOT / 'src/opnsense/scripts/OPNsense/ocnfixedip'
spec = importlib.util.spec_from_file_location('runtime', SCRIPTS / 'runtime.py')
runtime = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runtime)


class Helpers(unittest.TestCase):
    def test_json_round_trip(self):
        text = '"\\\n<img src=x onerror=alert(1)>café'
        self.assertEqual(json.loads(runtime.format_json('{"a":"%s"}', [text])), {'a': text})

    def test_ipv6_filters(self):
        lines = '''inet6 fd00::1 prefixlen 64
inet6 fe90::1 prefixlen 64
inet6 ::1234 prefixlen 64
inet6 2001:4860:1::1 prefixlen 64 tentative
inet6 2001:4860:1::2 prefixlen 64 deprecated
inet6 2001:4860:1::3 prefixlen 64 temporary
inet6 2001:4860:1::4 prefixlen 128
inet6 2001:4860:1::5 prefixlen 64
'''
        self.assertEqual(runtime.select_ipv6(lines, ['2001:4860:1::4']), '2001:4860:1::5')
        with self.assertRaises(ValueError):
            runtime.select_ipv6(lines + 'inet6 2001:4860:2::5 prefixlen 64\n')
        with self.assertRaises(ValueError):
            runtime.select_ipv6('inet6 fd00::1 prefixlen 64')

    def test_native_wan_128_is_eligible(self):
        self.assertEqual(runtime.select_ipv6('inet6 2001:4860::1 prefixlen 128'), '2001:4860::1')

    def test_selector_failure_has_no_stdout(self):
        result=subprocess.run([sys.executable,str(SCRIPTS/'runtime.py'),'select-ipv6'],input='inet6 fd00::1 prefixlen 64',text=True,capture_output=True)
        self.assertNotEqual(result.returncode,0)
        self.assertEqual(result.stdout,'')

    def test_update_url(self):
        self.assertEqual(runtime.update_url('https://example.invalid/nic?a=1', 'token-123'), 'https://example.invalid/nic?a=1&hostname=token-123')
        self.assertEqual(runtime.update_url('http://example.invalid/?hostname=old', 'new'), 'http://example.invalid/?hostname=old')
        for url, token in [('file:///etc/passwd', ''), ('http://user:pass@example.invalid/', ''), ('https://example.invalid/', '<b>x</b>'), ('http://example.invalid/?hostname=x&hostname=y', '')]:
            with self.assertRaises(ValueError): runtime.update_url(url, token)

    def test_netrc_escaping(self):
        import shlex
        with tempfile.TemporaryDirectory() as directory:
            p = Path(directory) / 'netrc'
            user, password = 'a user', 'p "quoted" \\ pass'
            p.write_text('default\nlogin ' + runtime.quote_netrc(user) + '\npassword ' + runtime.quote_netrc(password))
            self.assertEqual(shlex.split(p.read_text()), ['default', 'login', user, 'password', password])
        with self.assertRaises(ValueError): runtime.quote_netrc('newline\npassword')

    def test_update_timeout_and_signal_remove_credentials(self):
        from unittest import mock
        for error in (subprocess.TimeoutExpired('curl',12), KeyboardInterrupt()):
            with self.subTest(error=type(error).__name__), tempfile.TemporaryDirectory() as directory:
                state=Path(directory)/'prefix-state'
                credentials=[]
                def interrupted(command, **kwargs):
                    credentials.append(Path(command[command.index('--netrc-file')+1]))
                    self.assertEqual(credentials[-1].stat().st_mode & 0o777,0o600)
                    raise error
                with mock.patch.object(runtime.subprocess,'run',side_effect=interrupted):
                    if isinstance(error, KeyboardInterrupt):
                        with self.assertRaises(KeyboardInterrupt):
                            runtime.prefix_update(['user','password','token','https://example.invalid/'],state)
                    else:
                        self.assertEqual(runtime.prefix_update(['user','password','token','https://example.invalid/'],state)['status'],'ng')
                self.assertTrue(credentials)
                self.assertFalse(credentials[0].exists())

    def test_kernel_lock_serializes(self):
        with tempfile.TemporaryDirectory() as directory:
            lock = str(Path(directory) / 'lock')
            log = Path(directory) / 'log'
            code = 'from pathlib import Path; import sys,time; p=Path(sys.argv[1]); f=p.open("a"); f.write("start\\n"); f.flush(); time.sleep(.2); f.write("end\\n"); f.close()'
            cmd = [sys.executable, str(SCRIPTS / 'runtime.py'), 'lock', lock, sys.executable, '-c', code, str(log)]
            first = subprocess.Popen(cmd)
            second = subprocess.Popen(cmd)
            self.assertEqual(first.wait(timeout=5), 0)
            self.assertEqual(second.wait(timeout=5), 0)
            self.assertEqual(log.read_text(), 'start\nend\nstart\nend\n')


# A fake FreeBSD network stack. All mutations are confined to a temporary JSON file.
MOCK = r'''#!/usr/bin/env python3
import json, os, sys, pathlib, shlex, time
p=pathlib.Path(os.environ['OCN_TEST_STATE']); state=json.loads(p.read_text()); tool=pathlib.Path(sys.argv[0]).name; a=sys.argv[1:]
state.setdefault('calls', []).append([tool]+a)
def save(): p.write_text(json.dumps(state))
if tool=='logger': save(); sys.exit(0)
if tool=='php': save(); print('existing:opt1'); sys.exit(0)
if tool=='sleep': sys.exit(0)
if tool=='drill':
 print('one.one.one.one.\t10\tIN\tA\t1.1.1.1'); save(); sys.exit(0)
if tool=='ping':
 if state.get('br_ping_fail') and a[-1]=='2001:4860::a': save(); sys.exit(1)
 print('64 bytes time=1.0 ms'); save(); sys.exit(0)
if tool=='curl':
 if '--netrc-file' in a:
  credentials=shlex.split(pathlib.Path(a[a.index('--netrc-file')+1]).read_text())
  assert credentials==['default','login','test user','password','p "quoted" \\ pass']
  assert '-k' not in a and '--max-time' in a and '--disable' in a
  state['auth_files']=state.get('auth_files',[])+[a[a.index('--netrc-file')+1]]
  save(); print(state.get('update_result','nochg')); sys.exit(state.get('update_rc',0))
 print('200|0|1.1.1.1'); save(); sys.exit(0)
if tool=='sysctl':
 if state.get('sysctl_missing'): save(); sys.exit(1)
 if a[0]=='-n': print(state.get('sysctl',0))
 else: state['sysctl']=int(a[0].split('=')[1])
 save(); sys.exit(0)
if tool=='route':
 if a==['-n','get','default']:
  if not state.get('route'): save(); sys.exit(1)
  print('gateway: '+state['route']+'\ninterface: '+('gif0' if state['route']=='192.0.0.1' else 'wan0'))
 elif a[0]=='delete': state['route']=None
 elif a[0] in ('add','change'):
  if state.get('route_fail'): save(); sys.exit(1)
  state['route']=a[-1]
 save(); sys.exit(0)
if tool=='ifconfig':
 dev=a[0]
 if dev=='gif0':
  if len(a)>1 and a[1]=='create': state['tunnel']={}
  elif len(a)>1 and a[1]=='destroy': state.pop('tunnel',None)
  elif 'tunnel' not in state: save(); sys.exit(1)
  elif len(a)==1:
   t=state['tunnel']; print('gif0: flags='+state.get('tunnel_flags','UP,RUNNING')+' mtu '+str(t.get('mtu',1460)))
   if 'local' in t: print('tunnel '+t.get('family','inet6')+' '+t['local']+' --> '+t['remote'])
   if 'ipv4' in t: print('inet '+t['ipv4']+' --> 192.0.0.1')
  elif a[1:3]==['inet6','tunnel']: state['tunnel'].update(local=a[3],remote=a[4])
  elif a[1]=='inet': state['tunnel']['ipv4']=a[2]
  elif a[1]=='mtu':
   if state.pop('mtu_fail_once',False): save(); sys.exit(1)
   if state.get('mtu_fail'): save(); sys.exit(1)
   state['tunnel']['mtu']=int(a[2])
 elif dev.startswith('wan'):
  if len(a)==1:
   print('inet6 '+state.get('wan_v6','2001:4860:1234:5601::1')+' prefixlen 64')
   for addr in state.get('aliases',{}).get(dev,[]): print('inet6 '+addr+' prefixlen 128')
  elif a[-1]=='alias': state.setdefault('aliases',{}).setdefault(dev,[]).append(a[2].split('/')[0])
  elif a[-1]=='-alias':
   if state.get('alias_delete_fail'): save(); sys.exit(1)
   state['aliases'][dev].remove(a[2])
 else: save(); sys.exit(1)
 save(); sys.exit(0)
save(); sys.exit(1)
'''


class ShellLifecycle(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='ocnfixedip-tests-')
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.scripts = self.directory / 'scripts'; shutil.copytree(SCRIPTS, self.scripts)
        self.state = self.directory / 'network.json'; self.state.write_text('{}')
        self.bin = self.directory / 'bin'; self.bin.mkdir()
        for tool in ['ifconfig','route','sysctl','logger','sleep','curl','drill','ping','php']:
            p=self.bin/tool; p.write_text(MOCK); p.chmod(0o755)
        self.config = self.directory / 'config.xml'
        self.config.write_text('''<opnsense><interfaces><wan><if>wan0</if></wan></interfaces><OPNsense><ocnfixedip><enabled>1</enabled><wan_interface>wan</wan_interface><fixedip_aftr>2001:4860::a</fixedip_aftr><fixedip_v4>203.0.113.96</fixedip_v4><mtu>1460</mtu><fixedip_update_url>http://example.invalid/nic</fixedip_update_url><fixedip_update_hostname>token</fixedip_update_hostname><fixedip_auth_user>test user</fixedip_auth_user><fixedip_auth_pass>p "quoted" \\ pass</fixedip_auth_pass></ocnfixedip></OPNsense></opnsense>''')
        # Substitute only filesystem paths in the copied scripts, never network behavior.
        for p in self.scripts.glob('*.sh'):
            s=p.read_text().replace('/conf/config.xml', str(self.config)).replace('/var/run/', str(self.directory)+'/').replace('/usr/local/bin/xmllint',shutil.which('xmllint')).replace('/usr/local/bin/php',str(self.bin/'php'))
            p.write_text(s); p.chmod(0o755)
        self.env = dict(os.environ, PATH=str(self.bin)+os.pathsep+os.environ['PATH'], OCN_TEST_STATE=str(self.state))

    def network(self): return json.loads(self.state.read_text())
    def change_network(self, **values):
        state=self.network(); state.update(values); self.state.write_text(json.dumps(state))
    def setting(self, key, value):
        import xml.etree.ElementTree as ET
        tree=ET.parse(self.config); tree.find('.//ocnfixedip/'+key).text=value; tree.write(self.config)
    def run_script(self, script, *args, success=True):
        r=subprocess.run(['sh',str(self.scripts/script),*args],env=self.env,capture_output=True,text=True,timeout=15)
        self.assertEqual(r.returncode, 0 if success else 1, r.stderr+r.stdout)
        return json.loads(r.stdout) if r.stdout.strip() else None

    def test_freebsd15_boot_without_volatile_state_or_mss_sysctl(self):
        address='2001:4860:1234:5600:cb:71:6000:0'
        self.change_network(tunnel={'local':address,'remote':'2001:4860::a','ipv4':'203.0.113.96','mtu':1280},sysctl_missing=True,tunnel_flags='UP,LOWER_UP')
        result=self.run_script('configure.sh')
        self.assertEqual(result['result'],'ok')
        self.assertEqual(self.network()['tunnel']['mtu'],1460)
        self.assertIn(address,self.network()['aliases']['wan0'])
        self.assertFalse((self.directory/'ocnfixedip_mss_ifmtu').exists())
        self.assertEqual(self.run_script('status.sh')['tunnel']['health'],'healthy')
        # Simulate another reboot: the assigned GIF survives but /var/run does not.
        (self.directory/'ocnfixedip_local_tunnel_v6').unlink()
        self.change_network(aliases={})
        self.assertEqual(self.run_script('configure.sh')['result'],'ok')
        self.assertIn(address,self.network()['aliases']['wan0'])
        self.run_script('teardown.sh')
        self.assertNotIn('tunnel',self.network())

    def test_stop_with_saved_sysctl_on_kernel_without_oid(self):
        self.run_script('configure.sh')
        self.change_network(sysctl_missing=True)
        self.run_script('teardown.sh')
        self.assertFalse((self.directory/'ocnfixedip_mss_ifmtu').exists())

    def test_assignment_php_is_isolated(self):
        self.run_script('configure.sh')
        self.assertTrue(any(call[0]=='php' for call in self.network()['calls']))
        self.assertNotIn('/usr/local/bin/php',(self.scripts/'configure.sh').read_text())

    def test_apply_restart_disable_and_alias_ownership(self):
        self.assertEqual(self.run_script('configure.sh')['result'],'ok')
        first=self.network(); old=first['tunnel']['local']; self.assertEqual(first['sysctl'],1)
        self.change_network(wan_v6='2001:4860:abcd:7801::1')
        self.assertEqual(self.run_script('configure.sh','restart')['result'],'ok')
        state=self.network(); self.assertNotIn(old,state['aliases']['wan0'])
        self.setting('enabled','0')
        self.assertEqual(self.run_script('configure.sh')['result'],'ok')
        state=self.network(); self.assertNotIn('tunnel',state); self.assertFalse(state['aliases']['wan0']); self.assertEqual(state['sysctl'],0)
        for auth in state['auth_files']: self.assertFalse(Path(auth).exists())

    def test_ipv6_over_ipv4_foreign_tunnel_is_preserved(self):
        original={'family':'inet','local':'192.0.2.1','remote':'192.0.2.2','mtu':1400}
        self.change_network(tunnel=original)
        self.assertEqual(self.run_script('configure.sh',success=False)['phase'],'ownership')
        self.run_script('teardown.sh')
        self.assertEqual(self.network()['tunnel'],original)

    def test_stop_preserves_unmanaged_tunnel_and_route(self):
        original={'local':'2001:4860::1','remote':'2001:4860::2','ipv4':'192.0.2.1','mtu':1400}
        self.change_network(tunnel=original,route='192.0.0.1')
        self.run_script('teardown.sh')
        self.assertEqual(self.network()['tunnel'],original)
        self.assertEqual(self.network()['route'],'192.0.0.1')

    def test_wan_change_cleans_old_device(self):
        self.run_script('configure.sh'); old=self.network()['tunnel']['local']
        self.setting('wan_interface','wan1'); self.run_script('configure.sh')
        state=self.network(); self.assertNotIn(old,state['aliases']['wan0']); self.assertIn(old,state['aliases']['wan1'])

    def test_existing_native_address_is_not_claimed(self):
        address='2001:4860:1234:5600:cb:71:6000:0'
        self.change_network(wan_v6=address)
        self.run_script('configure.sh'); self.run_script('configure.sh')
        self.run_script('teardown.sh')
        state=self.network()
        self.assertEqual(state['wan_v6'],address)
        self.assertFalse(any(call[0]=='ifconfig' and call[-1]=='-alias' for call in state['calls']))

    def test_br_icmp_failure_does_not_hide_ipv4_connectivity(self):
        self.run_script('configure.sh'); self.change_network(br_ping_fail=True)
        tunnel=self.run_script('status.sh')['tunnel']
        self.assertEqual(tunnel['connectivity'],'connected')
        self.assertEqual(tunnel['health_failures'],'ce_to_br')

    def test_external_alias_is_preserved(self):
        addr='2001:4860:1234:5600:cb:71:6000:0'
        self.change_network(aliases={'wan0':[addr]})
        self.run_script('configure.sh'); self.run_script('teardown.sh')
        self.assertEqual(self.network()['aliases']['wan0'],[addr])

    def test_failed_alias_delete_retains_record(self):
        self.run_script('configure.sh'); self.change_network(alias_delete_fail=True)
        self.run_script('teardown.sh',success=False)
        self.assertTrue((self.directory/'ocnfixedip_local_tunnel_v6').exists())

    def test_backend_failure_is_json_not_success(self):
        self.change_network(mtu_fail=True)
        result=self.run_script('configure.sh',success=False)
        self.assertEqual((result['result'],result['phase']),('failed','tunnel'))
        self.change_network(mtu_fail=False)
        self.assertEqual(self.run_script('configure.sh')['result'],'ok')

    def test_failed_reconfigure_restores_working_state(self):
        self.run_script('configure.sh')
        original=self.network()['tunnel'].copy()
        self.change_network(wan_v6='2001:4860:abcd:7801::1',mtu_fail_once=True)
        result=self.run_script('configure.sh','restart',success=False)
        self.assertEqual(result['warning'],'')
        state=self.network()
        self.assertEqual(state['tunnel'],original)
        self.assertEqual(state['aliases']['wan0'],[original['local']])
        self.assertEqual(state['route'],'192.0.0.1')
        self.run_script('teardown.sh')
        self.assertEqual(self.network()['sysctl'],0)

    def test_unmanaged_tunnel_is_not_overwritten(self):
        original={'local':'2001:4860:other::1','remote':'2001:4860::2','ipv4':'192.0.2.1','mtu':1400}
        self.change_network(tunnel=original)
        self.assertEqual(self.run_script('configure.sh',success=False)['phase'],'ownership')
        self.assertEqual(self.network()['tunnel'],original)

    def test_route_failure_is_reported(self):
        self.change_network(route_fail=True)
        result=self.run_script('configure.sh',success=False)
        self.assertEqual(result['phase'],'default_route')

    def test_bad_input_does_not_tear_down_existing_tunnel(self):
        self.run_script('configure.sh'); original=self.network()['tunnel']
        self.setting('fixedip_update_hostname','bad"<b>token</b>')
        self.assertEqual(self.run_script('configure.sh','restart',success=False)['phase'],'validation')
        self.assertEqual(self.network()['tunnel'],original)

    def test_diagnostics_safe_and_prefix_warning(self):
        self.run_script('configure.sh'); self.change_network(update_result='badauth')
        self.assertEqual(self.run_script('configure.sh')['warning'],'prefix_update')
        result=self.run_script('diagnostics.sh')
        self.assertEqual(len(result['checks']),16)
        self.assertEqual(result['checks']['prefix_update']['result'],'badauth')
        self.assertNotIn('token',json.dumps(result))
        self.assertNotIn('test user',json.dumps(result))

    def test_status_cache_and_disable_invalidation(self):
        self.run_script('configure.sh')
        first=self.run_script('status.sh'); count=len(self.network()['calls'])
        second=self.run_script('status.sh'); self.assertEqual(first,second); self.assertEqual(len(self.network()['calls']),count)
        self.setting('enabled','0'); self.run_script('configure.sh')
        self.assertEqual(self.run_script('status.sh')['tunnel']['status'],'disabled')


if __name__=='__main__': unittest.main()
