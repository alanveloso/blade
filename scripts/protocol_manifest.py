#!/usr/bin/env python3
"""Validate final evidence and write its provenance/metric manifest (no publishing)."""
import ast,hashlib,json,platform,re,shutil,subprocess,sys
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'evidence/protocol'
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def compare(a,b):return {'before':a,'after':b,'delta':b-a,'percent':100*(b-a)/a if a else None}
def read(name):return json.loads((OUT/name).read_text())
old=read('prior-hashes.json')
preserved=[p for p in old if p.startswith('evidence/protocol/')]
assert all((ROOT/p).is_file() and sha(ROOT/p)==old[p] for p in preserved)
first=read('txgas-first.json');repeat=read('txgas.json')
assert set(first)==set(repeat)
for key in first:
    assert first[key]['bytecode']==repeat[key]['bytecode'],key
    assert [(r['name'],r['gasUsed'],r['calldata']) for r in first[key]['receipts']]==[(r['name'],r['gasUsed'],r['calldata']) for r in repeat[key]['receipts']],key
campaigns={}
for seed in ['0x42','0x1234']:
    text=(OUT/f'full-{seed}.txt').read_text().split('Test Suite')[-1]
    rows=re.findall(r'\| ([\w]+)\s+\| (\d+)\s+\| (\d+)\s+\| (\d+)',text)
    counts={'suites':len(rows),'passed':sum(int(x[1]) for x in rows),'failed':sum(int(x[2]) for x in rows),'skipped':sum(int(x[3]) for x in rows)}
    assert counts=={'suites':43,'passed':488,'failed':0,'skipped':0},counts
    campaigns[seed]=counts
symbolic=read('halmos-final.json');checks=[r for rows in symbolic['test_results'].values() for r in rows]
assert symbolic['exitcode']==0 and len(checks)==11
assert all(r['exitcode']==0 and r['num_bounded_loops']==0 and r['num_paths'][2]==0 for r in checks)
assert read('halmos-negative-control.json')['exitcode']!=0

def metrics(name):return {k:int(v) for k,v in re.findall(r'^  ([^\n]+): (\d+)$',(OUT/name).read_text(),re.M)}
a,b=metrics('gas-prior.txt'),metrics('gas-final.txt')
result={'execution_vs_prior':{k:compare(a[k],b[k]) for k in sorted(a.keys()&b.keys())},'receipt_vs_prior':{},'receipt_totals':{}}
for kind in ['request','sync','queue','subscribe']:
    a={r['name']:r['gasUsed'] for r in repeat['prior-'+kind]['receipts'] if not r['name'].startswith('deploy ')}
    b={r['name']:r['gasUsed'] for r in repeat['final-'+kind]['receipts'] if not r['name'].startswith('deploy ')}
    result['receipt_vs_prior'][kind]={k:compare(a[k],b[k]) for k in a}
    result['receipt_totals'][kind]=compare(sum(a.values()),sum(b.values()))
result['queue_vs_sync_final_receipts']=compare(result['receipt_totals']['sync']['after'],result['receipt_totals']['queue']['after'])
(OUT/'gas-comparison.json').write_text(json.dumps(result,indent=2)+'\n')
config=json.loads(subprocess.check_output(['forge','config','--json'],cwd=ROOT))
assert config['solc']=='0.8.26' and config['evm_version']=='cancun' and config['optimizer'] and config['optimizer_runs']==200 and not config['via_ir']
(OUT/'foundry-config-final.json').write_text(json.dumps(config,indent=2)+'\n')
for p in (ROOT/'scripts').glob('*.py'):ast.parse(p.read_text())
source_files=[ROOT/'foundry.toml']
for directory in ['src','test','examples','experiments','formal','scripts','docs']:
    source_files.extend(p for p in (ROOT/directory).rglob('*') if p.is_file() and p.suffix in ['.sol','.py','.md'])
tools={}
for name in ['forge','cast','anvil']:
    p=Path(shutil.which(name));tools[name]={'path':str(p),'sha256':sha(p),'version':subprocess.check_output([str(p),'--version'],text=True).strip()}
manifest={'date':'2026-11-05','head':subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip(),
 'branch':subprocess.check_output(['git','branch','--show-current'],cwd=ROOT,text=True).strip(),
 'python':sys.version,'platform':platform.platform(),'tools':tools,'campaigns':campaigns,
 'symbolic_obligations':[{k:r[k] for k in ['name','exitcode','num_paths','num_bounded_loops']} for r in checks],
 'receipt_repeat':{'scenarios':len(repeat),'identical_gas_calldata_bytecode':True},
 'preserved_previous_evidence_files':len(preserved),
 'source_sha256':{str(p.relative_to(ROOT)):sha(p) for p in sorted(source_files)},
 'artifact_sha256':{str(p.relative_to(ROOT)):sha(p) for p in sorted((ROOT/'out').glob('*/*.json'))},
 'evidence_sha256':{str(p.relative_to(ROOT)):sha(p) for p in sorted(OUT.rglob('*')) if p.is_file() and p.name!='manifest-final.json'}}
assert manifest['head']=='6642b2f41ab0c89e8114e464fa4790a69985d4ad'
assert manifest['branch']=='revision/protocol-evidence'
(OUT/'manifest-final.json').write_text(json.dumps(manifest,indent=2)+'\n')
print('PASS: 2 x 488 tests; 11 symbolic obligations; expected-failing control; 10 identical receipt scenarios;',len(preserved),'previous evidence files unchanged.')
