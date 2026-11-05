#!/usr/bin/env python3
"""Verify closing evidence without modifying any earlier source or result."""
import hashlib,json,platform,re,subprocess
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1];OUT=ROOT/'evidence/jaamas-close'
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def read(n):return json.loads((OUT/n).read_text())
def delta(a,b):return {'before':a,'after':b,'delta':b-a,'percent':100*(b-a)/a}
old=read('prior-hashes.json');bad=[p for p,h in old.items() if not (ROOT/p).is_file() or sha(ROOT/p)!=h]
assert not bad,bad
checks=[r for v in read('halmos-final.json')['test_results'].values() for r in v]
assert len(checks)==14 and all(r['exitcode']==0 and r['num_paths'][1]>0 and r['num_paths'][2]==0 and r['num_bounded_loops']==0 for r in checks)
assert read('halmos-negative-control.json')['exitcode']!=0
counts={}
for seed in ['0x42','0x1234']:
 text=(OUT/f'full-{seed}.txt').read_text().split('Test Suite')[-1]
 rows=re.findall(r'\| (\w+)\s+\| (\d+)\s+\| (\d+)\s+\| (\d+)',text)
 counts[seed]=[sum(int(r[i]) for r in rows) for i in [1,2,3]]
 assert counts[seed]==[497,0,0],counts
first=read('txgas-first.json');second=read('txgas.json');assert set(first)==set(second) and len(first)==12
for k in first:
 assert first[k]['bytecode']==second[k]['bytecode'],k
 assert [(r['name'],r['gasUsed'],r['calldata']) for r in first[k]['receipts']]==[(r['name'],r['gasUsed'],r['calldata']) for r in second[k]['receipts']],k
comparison={}
for kind in ['request','sync','queue','subscribe']:
 a=[r['gasUsed'] for r in second['prior-'+kind]['receipts'] if not r['name'].startswith('deploy ')]
 b=[r['gasUsed'] for r in second['final-'+kind]['receipts'] if not r['name'].startswith('deploy ')]
 assert a==b,kind;comparison[kind]=delta(sum(a),sum(b))
for i in [1,2]:
 native=sum(r['gasUsed'] for r in second['final-audit-native']['receipts'] if r['name'].startswith(str(i)+' '))
 for k in ['native','unique','generated','token']:
  gas=sum(r['gasUsed'] for r in second['final-audit-'+k]['receipts'] if r['name'].startswith(str(i)+' '))
  comparison[f'{k}-cycle-{i}']=delta(native,gas)
(OUT/'comparison.json').write_text(json.dumps(comparison,indent=2)+'\n')
config=read('foundry-config.json');assert config['evm_version']=='cancun' and config['solc']=='0.8.26' and config['optimizer_runs']==200 and config['optimizer'] and not config['via_ir']
source=[]
for d in ['src','test','experiments','examples','scripts','formal','docs']:
 source.extend(p for p in (ROOT/d).rglob('*') if p.is_file() and p.suffix in ['.sol','.py','.md'])
source.append(ROOT/'foundry.toml')
head=subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip()
branch=subprocess.check_output(['git','branch','--show-current'],cwd=ROOT,text=True).strip()
assert head=='6642b2f41ab0c89e8114e464fa4790a69985d4ad' and branch=='revision/jaamas-protocol-evidence'
manifest={'head':head,'branch':branch,'platform':platform.platform(),'preserved_files':len(old),'full_test_counts_pass_fail_skip':counts,
 'symbolic':[{k:r[k] for k in ['name','exitcode','num_paths','num_bounded_loops']} for r in checks],
 'repeated_receipt_scenarios':12,'original_functional_sources_unchanged':True,
 'source_sha256':{str(p.relative_to(ROOT)):sha(p) for p in sorted(source)},
 'evidence_sha256':{str(p.relative_to(ROOT)):sha(p) for p in sorted(OUT.rglob('*')) if p.is_file() and p.name!='manifest.json'}}
(OUT/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
print(f'PASS: {len(old)} historical files unchanged; 2 x 497 tests; 14 symbolic obligations; 12 receipt scenarios reproduced.')
