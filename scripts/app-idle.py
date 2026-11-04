#!/usr/bin/env python3
"""Sample the native application only. No traffic interception or settings changes."""
import argparse, importlib.util, json, pathlib, socket, subprocess, time
root=pathlib.Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('integration',root/'scripts/integration.py')
module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
parser=argparse.ArgumentParser()
parser.add_argument('--settle-seconds',type=float,default=8)
parser.add_argument('--sample-seconds',type=float,default=20)
parser.add_argument('--profile',action='store_true')
settings=parser.parse_args()
assert 3 <= settings.settle_seconds <= 30 and 5 <= settings.sample_seconds <= 60
report={}
for mode in ['disabled','enabled']:
    port=module.free_port()
    args=[str(root/'build/release/MacDPI.app/Contents/MacOS/MacDPI'),'--ui-testing','--test-port',str(port)]
    if mode=='enabled': args+=['--benchmark-enabled']
    process=subprocess.Popen(args,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    try:
        time.sleep(settings.settle_seconds)
        assert process.poll() is None,'Native app exited'
        if mode=='enabled':
            with socket.create_connection(('127.0.0.1',port),timeout=2): pass
        time.sleep(1)
        before=module.sample(process);start=time.monotonic();time.sleep(settings.sample_seconds);after=module.sample(process)
        elapsed=time.monotonic()-start
        report[mode]={'interval_seconds':elapsed,'cpu_percent':round((after['cpu_seconds']-before['cpu_seconds'])/elapsed*100,3),'rss_mib':round(after['rss_kib']/1024,2),'settle_seconds':settings.settle_seconds+1}
        if settings.profile and mode=='enabled':
            result=subprocess.run(['/usr/bin/sample',str(process.pid),'3','10','-file',str(root/'build/reports/app-sample.txt')],stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,timeout=10)
            report[mode]['sample_exit_code']=result.returncode
            if result.returncode: (root/'build/reports/app-sample-error.txt').write_text(result.stdout)
    finally:
        process.terminate();process.wait(timeout=5)
(root/'build/reports/app-idle.json').write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps(report,indent=2))
