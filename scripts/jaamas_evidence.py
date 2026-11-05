#!/usr/bin/env python3
"""Run local Cancun evidence without commits, network, or modifying the baseline checkout.
Requires forge, cached solc 0.8.26, and (for formal) SOLC and Z3_LIB_DIR.
"""
import hashlib
import io
import json
import os
from pathlib import Path
import subprocess
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parents[1]
OUT = Path(os.environ.get('BLADE_EVIDENCE_DIR', str(ROOT / 'evidence/jaamas')))
BASE = '6642b2f41ab0c89e8114e464fa4790a69985d4ad'
OUT.mkdir(parents=True, exist_ok=True)

def run(args, name, cwd=ROOT, env=None):
    result = subprocess.run(args, cwd=cwd, env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    (OUT / name).write_text(result.stdout)
    if result.returncode:
        raise RuntimeError(f'{name}: exit {result.returncode}; inspect log')
    return result.stdout

metadata = {'baseline_commit': BASE, 'head': run(['git', 'rev-parse', 'HEAD'], 'head.txt').strip(),
            'branch': run(['git', 'branch', '--show-current'], 'branch.txt').strip(),
            'forge': run(['forge', '--version'], 'forge-version.txt'),
            'seed': '0x42', 'evm_version': 'cancun'}
run(['forge', 'config', '--json'], 'foundry-config.json')
with tempfile.TemporaryDirectory(prefix='blade-jaamas-baseline-') as d:
    archive = subprocess.check_output(['git', 'archive', BASE], cwd=ROOT)
    with tarfile.open(fileobj=io.BytesIO(archive)) as tar:
        tar.extractall(d, filter='data')
    run(['forge', 'test', '--offline', '--evm-version', 'cancun', '--fuzz-seed', '0x42', '--summary'], 'baseline-seeded-tests.txt', d)
    run(['forge', 'test', '--offline', '--evm-version', 'cancun', '--match-contract', '^GasRequestTest$', '-vv'], 'baseline-gas.txt', d)
    # Capture full creation/runtime bytecode hashes, including metadata (no equality assumption).
    def hashes(base):
        data = {}
        for name in ['ScriptedRequestAgent', 'ExampleRequester', 'ExampleParticipant', 'ExposedContractNetManager']:
            source = {'ScriptedRequestAgent':'Request.t.sol', 'ExampleRequester':'RequestExample.sol',
                      'ExampleParticipant':'RequestExample.sol', 'ExposedContractNetManager':'ContractNetActors.sol'}[name]
            files = [Path(base) / 'out' / source / (name + '.json')]
            artifact = json.loads(files[0].read_text())
            data[name] = {k: hashlib.sha256(bytes.fromhex(artifact[k]['object'].removeprefix('0x'))).hexdigest()
                          for k in ['bytecode', 'deployedBytecode']}
        return data
    metadata['baseline_bytecode_sha256'] = hashes(d)
run(['forge', 'test', '--offline', '--evm-version', 'cancun', '--fuzz-seed', '0x42', '--summary'], 'final-tests.txt')
run(['forge', 'test', '--offline', '--evm-version', 'cancun', '--match-test', 'test_gas', '-vv'], 'final-gas.txt')
metadata['final_bytecode_sha256'] = hashes(ROOT)
metadata['source_sha256'] = {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest()
    for directory in ['src', 'examples', 'experiments', 'formal', 'test/jaamas', 'test/symbolic', 'scripts']
    for p in sorted((ROOT / directory).rglob('*')) if p.is_file()}
(OUT / 'manifest.json').write_text(json.dumps(metadata, indent=2)+'\n')
solc = os.environ.get('SOLC')
z3 = os.environ.get('Z3_LIB_DIR')
if solc and z3:
    env = dict(os.environ, LD_LIBRARY_PATH=z3)
    run([solc, '--version'], 'solc-version.txt', env=env)
    for engine in ['chc', 'bmc']:
        run([solc, '--base-path', '.', '--model-checker-engine', engine,
             '--model-checker-targets', 'assert', '--model-checker-timeout', '10000',
             '--model-checker-show-proved-safe', '--model-checker-show-unproved', '--model-checker-show-unsupported',
             'formal/RequestProperties.sol'], f'formal-{engine}-z3.txt', env=env)
    # solc exit code alone does NOT indicate successful proofs. Inspect solver diagnostics.
else:
    print('Formal checks not run: set SOLC and Z3_LIB_DIR (see docs/JAAMAS_REVISION.md).')
print('Evidence written to', OUT)
