# Explicit Linux-only producer regression; this is not cross-platform coverage.
# Run unprivileged with existing authenticated Nix, Bash and coreutils. Enforce
# AF_UNIX-only networking externally; the test verifies Internet sockets fail.
# Example (substitute measured absolute tools and an absent evidence path):
# systemd-run --user --wait --collect -p RestrictAddressFamilies=AF_UNIX \
#   -p MemoryMax=2G -p RuntimeMaxSec=240 python3 \
#   setup-dev-env/test-nix-profile-lifetime.py --nix /absolute/bin/nix \
#   --bash /absolute/bin/bash --coreutils-dir /absolute/coreutils/bin \
#   --evidence-root /absolute/absent-evidence-directory
# Every GC targets only the exclusive private logical store below that directory.
# Retain evidence on failure; never run production-store GC to prepare this test.
# Real generated wrapper + real Nix profile/GC. The tiny environment is Nix-
# evaluated serialization fixture data with genuine source string context;
# no fake Nix/GC/compiler, builders, downloads or production-store collection.
from pathlib import Path
import os,sys,json,subprocess,shutil,hashlib,stat,shlex,urllib.parse,platform,time
import argparse
parser=argparse.ArgumentParser(description="Real isolated Linux Nix profile/source retention oracle; requires AF_UNIX-only sandbox")
parser.add_argument('--nix',required=True,type=Path)
parser.add_argument('--bash',required=True,type=Path)
parser.add_argument('--coreutils-dir',required=True,type=Path)
parser.add_argument('--evidence-root',required=True,type=Path)
args=parser.parse_args()
assert platform.system()=='Linux', 'This real private-store oracle requires Linux; no other-platform acceptance is implied'
assert os.getuid()!=0, 'Run unprivileged'
# Every write and collection is confined to this exclusive task-owned directory.
O=args.evidence_root.absolute();O.mkdir(mode=0o700,parents=False,exist_ok=False)
T=O/'private fixture with spaces';T.mkdir(mode=0o700)
uid=os.getuid();ts=T.lstat()
action=Path(__file__).resolve().parent/'action.yml'
roles={}
for name,p in {'nix':args.nix,'nix-store':args.nix.parent/'nix-store','bash':args.bash,**{n:args.coreutils_dir/n for n in ['cat','mktemp','mkdir','chmod','rm','readlink']}}.items():
  p=p.absolute();principal=p.resolve(strict=True);assert p.is_file() and os.access(p,os.X_OK)
  roles[name]={'path':str(p),'principal':str(principal),'SHA':hashlib.sha256(principal.read_bytes()).hexdigest()}
b={'roles':roles,'PATH':':'.join(dict.fromkeys([str(args.nix.absolute().parent),str(args.bash.absolute().parent),str(args.coreutils_dir.absolute())])),'draft':str(action),'draftSHA':hashlib.sha256(action.read_bytes()).hexdigest()}
(O/'roles.json').write_text(json.dumps(b,indent=2))
# Actual per-scope network restriction must deny Internet sockets before Nix.
import socket,errno
for family in [socket.AF_INET,socket.AF_INET6]:
  try:
    sock=socket.socket(family,socket.SOCK_STREAM);sock.close()
  except OSError as e:
    assert e.errno in [errno.EPERM,errno.EAFNOSUPPORT],e
  else:raise AssertionError('Internet socket creation not denied')
local=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM);local.close()
identity=(ts.st_dev,ts.st_ino);store=T/'store';state=T/'state';logs=T/'logs';home=T/'home';tmp=T/'tmp';rt=T/'runner temp with spaces';cwd=T/'consumer';fixture=T/'fixture';src=fixture/'source-input';wrong=fixture/'wrong-source-input';missing=fixture/'missing-source-input'
for p in [home,tmp,rt,cwd,fixture,src,wrong,missing,T/'config',T/'cache',T/'state-home']:p.mkdir(mode=0o700)
(src/'repro.nim').write_text('owned-source-marker\n');(wrong/'repro.nim').write_text('wrong-real-source-bytes\n');(missing/'unrelated.nim').write_text('real-source-without-marker\n');uri='local?'+urllib.parse.urlencode({'store':str(store),'state':str(state),'log':str(logs)},quote_via=urllib.parse.quote)
def guard():
  st=T.lstat();assert (st.st_dev,st.st_ino)==identity and st.st_uid==uid and not T.is_symlink()
  q=urllib.parse.parse_qs(uri.split('?',1)[1]);assert uri.startswith('local?') and q=={'store':[str(store)],'state':[str(state)],'log':[str(logs)]}
  for p in [store,state,logs]:
    assert p.parent==T and p!=Path('/nix/store')
    if p.exists():assert p.lstat().st_uid==uid and not p.is_symlink()
  for name,h in b['roles'].items():assert str(Path(h['path']).resolve())==h['principal'] and hashlib.sha256(Path(h['principal']).read_bytes()).hexdigest()==h['SHA'],name
  assert hashlib.sha256(Path(b['draft']).read_bytes()).hexdigest()==b['draftSHA']
env={k:v for k,v in os.environ.items() if not k.startswith(('NIX_','REPRO_','REPROBUILD_','GIT_'))};env.update(HOME=str(home),TMPDIR=str(tmp),TMP=str(tmp),TEMP=str(tmp),XDG_CONFIG_HOME=str(T/'config'),XDG_CACHE_HOME=str(T/'cache'),XDG_STATE_HOME=str(T/'state-home'),NIX_CONF_DIR=str(T/'config'),NIX_USER_CONF_FILES='/dev/null',NIX_REMOTE=uri,NIX_PATH='',PATH=b['PATH'],LC_ALL='C',NIX_CONFIG='experimental-features = nix-command flakes\nflake-registry =\nmax-jobs = 0\nbuilders =\nsubstitute = false\nallow-import-from-derivation = false\nmin-free = 0\nmax-free = 0\nauto-optimise-store = false\n')
N=b['roles']['nix']['path'];NS=b['roles']['nix-store']['path'];B=b['roles']['bash']['path'];stages=[];logBytes=0
def run(name,args,expected=0,customEnv=None):
  global logBytes
  guard();start=time.monotonic();(O/'active-stage.json').write_text(json.dumps({'stage':name,'argv':args,'privateStore':uri}))
  z=subprocess.run(args,cwd=cwd,env=customEnv or env,capture_output=True,text=True,timeout=25)
  logBytes+=len(z.stdout.encode())+len(z.stderr.encode());assert logBytes<=64*2**20,('log cap',name,logBytes)
  (O/(name+'.stdout')).write_text(z.stdout);(O/(name+'.stderr')).write_text(z.stderr)
  assert 'building ' not in z.stderr and 'copying path ' not in z.stderr,('unexpected builder or acquisition',name)
  stages.append({'stage':name,'code':z.returncode,'seconds':time.monotonic()-start});(O/'stages.json').write_text(json.dumps(stages,indent=2));guard()
  if expected is not None:assert z.returncode==expected,(name,z.returncode,z.stderr)
  return z
base=[N,'--store',uri,'--offline','--no-use-registries'];actual=run('private-store-dir',base+['eval','--raw','--expr','builtins.storeDir']).stdout;assert actual==str(store),(actual,store)
assert str(store) not in os.environ.get('NIX_GCROOT','')
system={'Linux':{'x86_64':'x86_64-linux','aarch64':'aarch64-linux'},'Darwin':{'arm64':'aarch64-darwin'}}[platform.system()][platform.machine()]
quoted=lambda x:json.dumps(str(x))
# A real input-free local flake declares all fixture files for pure evaluation.
flake="""{ outputs = { self }: let mkEnv = name: directory:
  let src = builtins.path { path = directory; name = "sdk-" + name; };
  in builtins.toFile (name + "-fixture-env") (builtins.toJSON {
    variables = {
      SDK_SRC = { type = "exported"; value = "${src}"; };
      PATH = { type = "exported"; value = PATH_VALUE; };
      outputs = { type = "array"; value = []; };
      system = { type = "var"; value = SYSTEM_VALUE; };
      shellHook = { type = "var"; value = ""; };
    }; bashFunctions = {};
  }); in {
    environment = mkEnv "good" ./source-input;
    wrongEnvironment = mkEnv "wrong" ./wrong-source-input;
    missingEnvironment = mkEnv "missing" ./missing-source-input;
  }; }
"""
flake=flake.replace('PATH_VALUE',quoted(b['PATH'])).replace('SYSTEM_VALUE',quoted(system));(fixture/'flake.nix').write_text(flake)
def inputs(label,attr='environment',expectedMarker=True):
  target='path:'+urllib.parse.quote(str(fixture),safe='/')+'#'+attr
  # This affects fixture-data materialization only, not tested dev-exec cache behavior.
  path=Path(run(label+'-input',base+['eval','--no-write-lock-file','--option','eval-cache','false','--raw',target]).stdout)
  assert path.parent==store and path.name.endswith('-env');data=json.loads(path.read_text());sp=Path(data['variables']['SDK_SRC']['value']);assert sp.parent==store
  if expectedMarker:assert (sp/'repro.nim').read_text()=='owned-source-marker\n'
  refs=run(label+'-refs',[NS,'--store',uri,'--query','--references',str(path)]).stdout.splitlines();assert str(sp) in refs;return path,sp
inputPath,sourcePath=inputs('old');(O/'input-identities.json').write_text(json.dumps({'environment':str(inputPath),'source':str(sourcePath),'URI':uri,'Tuid':uid,'Tinode':ts.st_ino,'sourceReferencesReal':True},indent=2))
# Extract the authentic proposed action's entire existing run block.
text=Path(b['draft']).read_text();section=text.split('    - name: Install dev-exec wrapper (nix)\n',1)[1];lines=section.split('      run: |\n',1)[1].splitlines();body=[]
for line in lines:
  if line and not line.startswith('        '):break
  body.append(line[8:] if line else '')
script='\n'.join(body)+'\n';(O/'actual-install-step.sh').write_text(script)
def generate(label,explicit=None,selectedInput=None):
  extra=['--store',uri,'--offline','--no-use-registries']
  if explicit:extra+=['--profile',str(explicit)]
  extra+=[str(selectedInput or inputPath)];e={**env,'RUNNER_TEMP':str(rt),'GITHUB_PATH':str(T/'github-path'),'FLAKE_OVERRIDE_INPUTS':'','NIX_ATTR':'','NIX_DEVELOP_ARGS':shlex.join(extra)}
  run(label,[B,str(O/'actual-install-step.sh')],customEnv=e);return home/'.local/bin/dev-exec'
wrapper=generate('generate-real-wrapper');newBody=wrapper.read_text();needle=' --profile "$profile_dir/profile"';assert newBody.count(needle)==1;oldBody=newBody.replace(needle,'');(O/'old-wrapper.sh').write_text(oldBody);(O/'new-wrapper.sh').write_text(newBody);wrapper.write_text(oldBody)
body='set -e; test "$(readlink /proc/$$/exe)" = '+shlex.quote(b['roles']['bash']['principal'])+'; printf "source-check-start\\n"; test "$(cat "$SDK_SRC/repro.nim")" = owned-source-marker; printf "cwd:%s\\n" "$PWD"; printf "arg:%s\\n" "$@"; exit 17'
command=[str(wrapper),B,'-c',body,'probe','one space','*literal','--dash']
expect='source-check-start\n'+'cwd:'+str(cwd)+'\narg:one space\narg:*literal\narg:--dash\n'
assert run('old-first-use',command,expected=17).stdout==expect
run('old-private-GC',[NS,'--store',uri,'--gc']);assert not inputPath.exists() and not sourcePath.exists(),('old did not falsify',inputPath,sourcePath)
z=run('old-reuse-refuses',command,expected=None);assert z.returncode!=0 and str(inputPath) in z.stderr
again,sourceAgain=inputs('new');assert (again,sourceAgain)==(inputPath,sourcePath);wrapper.write_text(newBody)
assert run('new-first-use',command,expected=17).stdout==expect
run('new-private-GC',[NS,'--store',uri,'--gc']);assert inputPath.is_file() and (sourcePath/'repro.nim').is_file()
assert run('new-second-use',command,expected=17).stdout==expect
profileLinks=list(rt.glob('mcl-nix-profiles.*/invocation.*/profile'));assert len(profileLinks)==2 and len({str(x.parent) for x in profileLinks})==2
for p in profileLinks:assert p.resolve()==inputPath and stat.S_IMODE(p.parent.parent.stat().st_mode)==0o700
(O/'retained-default-profiles.json').write_text(json.dumps([str(p) for p in profileLinks],indent=2));roots=run('new-private-roots',[NS,'--store',uri,'--query','--roots',str(inputPath)]).stdout;assert str(rt) in roots
# The same real Bash body must stop at the source assertion, not later prints.
for label,attr in [('wrong-source','wrongEnvironment'),('missing-source','missingEnvironment')]:
  badEnv,badSource=inputs(label,attr,False)
  if label=='wrong-source':assert (badSource/'repro.nim').read_text()=='wrong-real-source-bytes\n'
  else:assert not (badSource/'repro.nim').exists()
  generate(label+'-wrapper',selectedInput=badEnv);bad=run(label+'-guard',command,expected=1);assert bad.stdout=='source-check-start\n'
explicitRoot=T/'explicit requested profile';explicitRoot.mkdir(mode=0o700);explicit=explicitRoot/'profile';generate('generate-explicit-profile',explicit);assert run('explicit-profile-precedence',command,expected=17).stdout==expect;assert explicit.resolve()==inputPath
# Only task-owned root directories are removed; the private store is retained.
for p in [*rt.glob('mcl-nix-profiles.*'),explicitRoot]:
  guard();assert p.is_relative_to(T) and not p.is_symlink() and p.lstat().st_uid==uid;shutil.rmtree(p)
run('released-private-GC',[NS,'--store',uri,'--gc']);assert not inputPath.exists() and not sourcePath.exists()
(O/'completed.json').write_text(json.dumps({'oldSourceCollected':True,'oldReuseRefused':True,'newSourceRetained':True,'twoInvocationsUnique':True,'spacePathArgvCWDStatusPreserved':True,'explicitCallerProfileHonored':True,'releasedSourceCollected':True,'sourceReferenceWasActual':True,'wrongAndMissingSourceAssertRealFailure':True,'actualBashPrincipalBound':b['roles']['bash'],'ordinaryCachedPATHBashFallbackNoAcquisition':True,'noBuilderOrNetworkAuthorized':True,'productionStoreGCNotInvoked':True,'historicalMacCauseNotClaimed':True,'stages':stages},indent=2));print('all real private-store profile/GC controls passed')
