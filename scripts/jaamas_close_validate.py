#!/usr/bin/env python3
"""Closing campaigns in isolated build directories. Historical evidence is never overwritten."""
import hashlib,json,os,subprocess,tempfile
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1];OUT=ROOT/'evidence/jaamas'
with tempfile.TemporaryDirectory(prefix='blade-close-validation-') as d:
    env=dict(os.environ,FOUNDRY_OUT=d+'/out',FOUNDRY_CACHE_PATH=d+'/cache')
    def run(args,name,environment=env):
        with (OUT/name).open('w') as f:subprocess.run(args,cwd=ROOT,env=environment,stdout=f,stderr=subprocess.STDOUT,check=True)
    for seed in ['0x42','0x1234']:
        budget=dict(env,FOUNDRY_FUZZ_RUNS='1024',FOUNDRY_INVARIANT_RUNS='128',FOUNDRY_INVARIANT_DEPTH='64')
        run(['forge','test','--offline','--evm-version','cancun','--fuzz-seed',seed,'--summary'],f'full-{seed}.txt',budget)
    run(['forge','coverage','--report','summary','--fuzz-seed','0x42'],'coverage.txt')
    run(['forge','test','--offline','--evm-version','cancun','--match-test','test_gas','-vv'],'gas-execution.txt')
    hashes={str(p.relative_to(Path(d)/'out')):hashlib.sha256(p.read_bytes()).hexdigest() for p in (Path(d)/'out').glob('*/*.json')}
    (OUT/'artifact-hashes.json').write_text(json.dumps(hashes,indent=2)+'\n')
for tool in ['forge','cast','anvil']:
    (OUT/(tool+'-version.txt')).write_text(subprocess.check_output([tool,'--version'],text=True))
(OUT/'foundry-config.json').write_bytes(subprocess.check_output(['forge','config','--json'],cwd=ROOT))
print('Closing full campaigns, coverage and execution benchmarks completed.')
