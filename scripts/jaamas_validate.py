#!/usr/bin/env python3
"""Additional final tests, frozen previous-working-tree benchmark, coverage, and integrity check.
Run separately from jaamas_symbolic.py and jaamas_txgas.py to avoid competing builds.
"""
import hashlib,json,os,shutil,subprocess,tarfile,tempfile
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'evidence/jaamas'

def run(args,name,cwd=ROOT,env=None):
    with (OUT/name).open('w') as log:
        subprocess.run(args,cwd=cwd,env=env,stdout=log,stderr=subprocess.STDOUT,check=True)

for seed in ['0x42','0x1234']:
    env=dict(os.environ,FOUNDRY_FUZZ_RUNS='1024',FOUNDRY_INVARIANT_RUNS='128',FOUNDRY_INVARIANT_DEPTH='64')
    run(['forge','test','--offline','--evm-version','cancun','--fuzz-seed',seed,'--summary'],f'full-{seed}.txt',env=env)
run(['forge','coverage','--report','summary','--fuzz-seed','0x42'],'coverage-final.txt')
# Coverage disables optimizer. Explicit rebuild before recording benchmark and bytecode.
run(['forge','build','--offline','--force'],'final-build.txt')
run(['forge','test','--offline','--match-test','test_gas','-vv'],'gas-final.txt')
with tempfile.TemporaryDirectory(prefix='blade-prior-gas-') as d:
    with tarfile.open(OUT/'prior-work.tar.gz') as t:t.extractall(d,filter='data')
    shutil.copytree(ROOT/'lib',Path(d)/'lib')
    shutil.copyfile(ROOT/'test/jaamas/FinalGas.t.sol',Path(d)/'test/jaamas/FinalGas.t.sol')
    run(['forge','test','--offline','--match-test','test_gas','-vv'],'gas-prior.txt',cwd=d)
old=json.loads((OUT/'prior-hashes.json').read_text())
changes={p:{'before':h,'after':hashlib.sha256((ROOT/p).read_bytes()).hexdigest()}
         for p,h in old.items() if (ROOT/p).is_file() and hashlib.sha256((ROOT/p).read_bytes()).hexdigest()!=h}
assert not any(p.startswith('evidence/jaamas/') for p in changes), changes
assert not any(not (ROOT/p).is_file() for p in old), 'A preserved file is missing'
(OUT/'changes-vs-prior.json').write_text(json.dumps(changes,indent=2)+'\n')
for tool in ['forge','anvil','cast']:
    run([tool,'--version'],tool+'-version.txt')
print('Two full campaigns, coverage, prior/final gas, and original evidence integrity passed.')
