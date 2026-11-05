#!/usr/bin/env python3
"""Deterministic local Anvil Cancun receipt campaign. No external RPC, keys, commits, or publishing."""
import io,json,os,subprocess,tarfile,tempfile,time,urllib.request,hashlib
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'evidence/jaamas-close'
RPC='http://127.0.0.1:18547'
BASE='6642b2f41ab0c89e8114e464fa4790a69985d4ad'
ZERO='0x'+'00'*20
BZERO='0x'+'00'*32
ID='0x'+'00'*31+'01'
TUP='(uint8,uint8,bytes32,bytes32,bytes32,uint64,bytes32,bytes)'
results={}

def rpc(method,params=[]):
    req=urllib.request.Request(RPC,json.dumps(dict(jsonrpc='2.0',id=1,method=method,params=params)).encode(),{'Content-Type':'application/json'})
    obj=json.loads(urllib.request.urlopen(req,timeout=15).read())
    if 'error' in obj: raise RuntimeError(obj['error'])
    return obj['result']

def cast(*args): return subprocess.check_output(['cast',*args],text=True).strip()

def msg(act,deadline=0,reply=BZERO,irt=BZERO):
    return f'({act},2,{ID},{reply},{irt},{deadline},{BZERO},0x)'

def campaign(base,label,kind):
    global stamp
    stamp=1700000010
    sender=rpc('eth_accounts')[0]
    receipts=[]; hashes={}; deployed={}
    def send(to,data,name):
        global stamp
        rpc('evm_setNextBlockTimestamp',[stamp]);stamp+=1
        tx={'from':sender,'data':data,'gas':hex(29_000_000)}
        if to:tx['to']=to
        txhash=rpc('eth_sendTransaction',[tx])
        for _ in range(100):
            receipt=rpc('eth_getTransactionReceipt',[txhash])
            if receipt is not None:break
            time.sleep(.05)
        else:raise RuntimeError('Receipt timeout: '+txhash)
        assert int(receipt['status'],16)==1,(name,receipt)
        intrinsic = 21000 + sum(4 if b==0 else 16 for b in bytes.fromhex(data[2:])) if to else None
        receipts.append({'name':name,'gasUsed':int(receipt['gasUsed'],16),'intrinsicGas':intrinsic,
                         'netExecutionAfterRefund':int(receipt['gasUsed'],16)-intrinsic if intrinsic is not None else None,
                         'calldata':data,'receipt':receipt})
        return receipt
    def deploy(name,constructor=False):
        source = {'ExampleRequester':'RequestExample.sol','ExampleParticipant':'RequestExample.sol',
                  'SubscriptionActor':'Subscribe.t.sol','ExposedContractNetParticipant':'ContractNetActors.sol',
                  'OwnerGatedContractNetManager':'ContractNetActors.sol','QueuedContractNetManager':'QueuedContractNetManager.sol',
                  **{n:'ContractNetAlternatives.sol' for n in ['AuditNativeManager','AuditUniqueManager','AuditGeneratedIdManager','AuditTokenManager','AuditTokenParticipant']}}[name]
        paths=[Path(base)/'out'/source/(name+'.json')];assert paths[0].is_file(),paths
        data=json.loads(paths[0].read_text()); bytecode=data['bytecode']['object']
        code=bytecode+('00'*32 if constructor else '')
        r=send(None,code,'deploy '+name); addr=r['contractAddress']
        hashes[name]={'creation_sha256':hashlib.sha256(bytes.fromhex(bytecode[2:])).hexdigest(),
                      'runtime_sha256':hashlib.sha256(bytes.fromhex(rpc('eth_getCode',[addr,'latest'])[2:])).hexdigest()}
        deployed[name]=addr
        return addr
    def invoke(addr,name,sig,*args):return send(addr,cast('calldata',sig,*args),name)
    if kind in ['audit-native','audit-unique','audit-generated','audit-token']:
        managerName={'audit-native':'AuditNativeManager','audit-unique':'AuditUniqueManager',
            'audit-generated':'AuditGeneratedIdManager','audit-token':'AuditTokenManager'}[kind]
        q=deploy(managerName)
        p=deploy('AuditTokenParticipant' if kind=='audit-token' else 'ExposedContractNetParticipant',kind!='audit-token')
        for iteration in [1,2]:
            id=cast('keccak',f'audit-instance-{iteration}');token=BZERO;deadline=1700001000+iteration*1000
            def message(act,by=0):return f'({act},2,{id},{BZERO},{token},{by},{BZERO},0x)'
            opening=f'(7,2,{BZERO if kind=="audit-generated" else id},{BZERO},{BZERO},{deadline},{BZERO},0x)'
            receipt=invoke(q,f'{iteration} open',f'{"open" if kind=="audit-generated" else "cfp"}(address[],{TUP})',f'[{p}]',opening)
            if kind=='audit-generated':
                event=cast('keccak','GeneratedConversation(bytes32)')
                id=next(log['topics'][1] for log in receipt['logs'] if log['topics'][0]==event)
            if kind=='audit-token':token=rpc('eth_call',[{'to':q,'data':cast('calldata','token(bytes32)',id)},'latest'])
            opening=f'(7,2,{id},{token},{BZERO},{deadline},{BZERO},0x)'
            invoke(p,f'{iteration} propose',f'respond({TUP},address,{TUP})',opening,q,message(8))
            stamp=deadline+1
            invoke(q,f'{iteration} evaluate','evaluate(bytes32,address[],address[],address[])',id,f'[{p}]','[]','[]')
            invoke(p,f'{iteration} inform',f'respond({TUP},address,{TUP})',opening,q,message(4))
            assert int(rpc('eth_call',[{'to':q,'data':cast('calldata','slotOf(bytes32,address)',id,p)},'latest']),16)==0
    elif kind=='request':
        a=deploy('ExampleRequester',True);b=deploy('ExampleParticipant',True)
        invoke(a,'request inform cold','request(address,bytes32,bytes)',b,ID,'0x01')
        invoke(a,'request inform next transaction','request(address,bytes32,bytes)',b,ID,'0x01')
    elif kind=='subscribe':
        a=deploy('SubscriptionActor');b=deploy('SubscriptionActor')
        invoke(a,'subscribe open','start(address,bytes32)',b,ID)
        for addr,act,name in [(b,1,'subscribe agree'),(b,4,'subscribe notify'),(a,6,'subscribe cancel'),(b,4,'subscribe cancel ack')]:
            invoke(addr,name,'act(bytes32,uint8)',ID,str(act))
        for addr in [a,b]:
            raw=rpc('eth_call',[{'to':addr,'data':cast('calldata','subscription(bytes32)',ID)},'latest'])
            assert int(raw[2:66],16)==0
    else:
        q=deploy('QueuedContractNetManager' if kind=='queue' else 'OwnerGatedContractNetManager')
        p1=deploy('ExposedContractNetParticipant',True);p2=deploy('ExposedContractNetParticipant',True)
        opening=msg(7,1700001000)
        invoke(q,'cfp',f'cfp(address[],{TUP})',f'[{p1},{p2}]',opening)
        for i,p in enumerate([p1,p2]):invoke(p,f'propose {i+1}',f'respond({TUP},address,{TUP})',opening,q,msg(8))
        stamp=1700001001
        invoke(q,'evaluate','evaluate(bytes32,address[],address[],address[])',ID,f'[{p1}]',f'[{p2}]','[]')
        if kind=='queue':
            invoke(q,'deliver reject','deliver(bytes32,address)',ID,p2)
            invoke(q,'deliver accept','deliver(bytes32,address)',ID,p1)
        invoke(p1,'inform',f'respond({TUP},address,{TUP})',opening,q,msg(4))
        for p in [p1,p2]:
            assert int(rpc('eth_call',[{'to':q,'data':cast('calldata','slotOf(bytes32,address)',ID,p)},'latest']),16)==0
        if kind=='queue':assert int(rpc('eth_call',[{'to':q,'data':cast('calldata','pendingCount(bytes32)',ID)},'latest']),16)==0
    results[label]={'kind':kind,'receipts':receipts,'bytecode':hashes,'addresses':deployed}

OUT.mkdir(parents=True,exist_ok=True)
with tempfile.TemporaryDirectory(prefix='blade-txgas-') as d:
    base=Path(d)/'baseline';base.mkdir()
    with tarfile.open(fileobj=io.BytesIO(subprocess.check_output(['git','archive',BASE],cwd=ROOT))) as t:t.extractall(base,filter='data')
    prior=Path(d)/'prior';prior.mkdir()
    with tarfile.open(OUT/'prior-work.tar.gz') as t:t.extractall(prior,filter='data')
    # Prior archive excludes vendored libraries; use the unchanged tracked library.
    import shutil
    shutil.copytree(base/'lib',prior/'lib')
    for label,path in [('baseline',base),('prior',prior),('final',ROOT)]:
        with (OUT/f'txgas-build-{label}.txt').open('w') as log:
            subprocess.run(['forge','build','--offline','--evm-version','cancun'],cwd=path,stdout=log,stderr=subprocess.STDOUT,check=True)
    with (OUT/'anvil.txt').open('w') as log:
        node=subprocess.Popen(['anvil','--host','127.0.0.1','--port','18547','--hardfork','cancun','--chain-id','31337','--timestamp','1700000000','--silent'],stdout=log,stderr=subprocess.STDOUT)
        try:
            for _ in range(100):
                if node.poll() is not None:raise RuntimeError('Anvil failed; inspect anvil.txt')
                try:rpc('eth_chainId');break
                except OSError:time.sleep(.05)
            else:raise RuntimeError('Anvil startup timeout')
            snapshot=rpc('evm_snapshot')
            for label,path,kinds in [('prior',prior,['request','sync','queue','subscribe']),('final',ROOT,['request','sync','queue','subscribe','audit-native','audit-unique','audit-generated','audit-token'])]:
                for kind in kinds:
                    assert rpc('evm_revert',[snapshot]);snapshot=rpc('evm_snapshot')
                    campaign(path,f'{label}-{kind}',kind)
        finally:
            node.terminate();node.wait(timeout=10)
(OUT/'txgas.json').write_text(json.dumps(results,indent=2)+'\n')
print('Receipt campaign complete:',len(results),'scenarios')
