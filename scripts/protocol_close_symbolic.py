#!/usr/bin/env python3
"""Halmos bytecode proofs plus a negative control in an isolated source copy."""
import json,os,shutil,subprocess,tempfile
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'evidence/protocol'
HALMOS=os.environ.get('HALMOS','/tmp/blade-halmos/bin/halmos')
Z3=os.environ.get('HALMOS_Z3','/tmp/blade-halmos/bin/z3')

def run(root,label,extra):
    with tempfile.TemporaryDirectory(prefix='blade-halmos-build-') as artifacts:
        artifacts=Path(artifacts)
        args=[HALMOS,'--root',str(root),'--solver-command',Z3,'--solver-timeout-assertion','30000',
              '--loop','4','--no-status','--forge-build-out',str(artifacts/'out'),
              '--json-output',str(OUT/(label+'.json')),*extra]
        env=dict(os.environ,FOUNDRY_OUT=str(artifacts/'out'),FOUNDRY_CACHE_PATH=str(artifacts/'cache'))
        with (OUT/(label+'.txt')).open('w') as log:
            result=subprocess.run(args,cwd=root,stdout=log,stderr=subprocess.STDOUT,env=env)
        import hashlib
        hashes={str(p.relative_to(artifacts/'out')): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in (artifacts/'out').glob('*/*.json')}
        (OUT/(label+'-artifact-hashes.json')).write_text(json.dumps(hashes,indent=2)+'\n')
        return result.returncode

assert run(ROOT,'halmos-final',['--match-contract','.*BytecodeProof'])==0
with tempfile.TemporaryDirectory(prefix='blade-symbolic-control-') as d:
    temp=Path(d)
    for folder in ['src','examples','experiments','formal','test','lib']:
        shutil.copytree(ROOT/folder,temp/folder)
    shutil.copyfile(ROOT/'foundry.toml',temp/'foundry.toml')
    p=temp/'src/core/RequestAgent.sol'
    text=p.read_text();guard='if ((fromInitiator ? replyWith : inReplyTo) != s.replyWith)'
    assert text.count(guard)==1
    p.write_text(text.replace(guard,'if (false)'))
    (OUT/'symbolic-negative-control.patch.txt').write_text(guard+'\n=> if (false)\nTemporary copy only. Production unchanged.\n')
    result=run(temp,'halmos-negative-control',['--contract','RequestBytecodeProof','--function','check_peerTokenIsolation'])
    report=(OUT/'halmos-negative-control.txt').read_text()
    assert result!=0 and '[FAIL]' in report,report
print('Positive checks and expected-failing mutation control executed.')
