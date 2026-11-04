#!/usr/bin/env python3
"""Run actual migrated tools without loading either Neovim or Mason."""
import argparse
import json
import os
from pathlib import Path
import queue
import signal
import socket
import subprocess
import tempfile
import threading
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--store', type=Path, required=True)
parser.add_argument('--java-home', type=Path)
options = parser.parse_args()
STORE = options.store
def root(name):
    pointer = json.loads((STORE / 'current' / (name + '.json')).read_text())
    return STORE / 'versions' / name / pointer['version']
def binary(name, command=None):
    return str(root(name) / 'bin' / (command or name))
def run(args, **kwargs):
    p = subprocess.run(args, capture_output=True, text=True, timeout=120, **kwargs)
    assert p.returncode == 0, (args, p.returncode, p.stdout[-2000:], p.stderr[-3000:])
    return p.stdout

class Protocol:
    def __init__(self, command, port=None):
        self.process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, start_new_session=True)
        self.messages = queue.Queue()
        self.diagnostics = bytearray()
        def stderr():
            for block in iter(lambda: self.process.stderr.read(4096), b''):
                self.diagnostics.extend(block)
        threading.Thread(target=stderr, daemon=True).start()
        self.sock = None
        if port:
            deadline = time.monotonic() + 30
            while True:
                try:
                    self.sock = socket.create_connection(('127.0.0.1',port), timeout=1)
                    self.sock.settimeout(None)
                    break
                except OSError:
                    if time.monotonic()>deadline: raise
                    time.sleep(.05)
            self.input = self.sock.makefile('wb',buffering=0)
            self.output = self.sock.makefile('rb')
        else:
            self.input,self.output=self.process.stdin,self.process.stdout
        def reader():
            try:
                while True:
                    length=None
                    while True:
                        line=self.output.readline()
                        if not line: return
                        if line in (b'\r\n',b'\n'): break
                        if line.lower().startswith(b'content-length:'): length=int(line.split(b':',1)[1])
                    if length is not None:
                        self.messages.put(json.loads(self.output.read(length)))
            except Exception as e:self.messages.put({'reader_error':repr(e)})
        threading.Thread(target=reader,daemon=True).start()
    def send(self,value):
        data=json.dumps(value).encode()
        self.input.write(('Content-Length: %d\r\n\r\n'%len(data)).encode()+data);self.input.flush()
    def until(self,predicate,seconds=45):
        deadline=time.monotonic()+seconds
        while time.monotonic()<deadline:
            try:message=self.messages.get(timeout=max(.01,deadline-time.monotonic()))
            except queue.Empty:break
            if predicate(message):return message
        raise AssertionError(('Protocol timeout',self.process.args,self.process.poll(),self.diagnostics.decode(errors='replace')[-3000:]))
    def close(self):
        if self.sock:self.sock.close()
        if self.process.poll() is None:
            os.killpg(self.process.pid,signal.SIGTERM)
        try:self.process.wait(timeout=5)
        except subprocess.TimeoutExpired:os.killpg(self.process.pid,signal.SIGKILL);self.process.wait()

for name,command,args in [
    ('cmakelang','cmake-format',['--version']),('gdscript-formatter',None,['--version']),
    ('gdtoolkit','gdlint',['--version']),('jdtls',None,['--help']),('miss_hit','mh_style',['--version']),
    ('mmdc',None,['--version']),('nil',None,['--version']),('shfmt',None,['--version']),
    ('stylua',None,['--version']),('verible','verible-verilog-ls',['--version']),
]:
    result=run([binary(name,command)]+args)
    print('PASS entrypoint',name,result.splitlines()[0][:120] if result.splitlines() else '',flush=True)

with tempfile.TemporaryDirectory(prefix='toolchain-process-') as temp:
    directory=Path(temp)
    for name,command in [('json-lsp','vscode-json-language-server'),('lua-language-server',None),('matlab-language-server',None),('nil',None)] + ([('jdtls', None)] if options.java_home else []):
        args=[binary(name,command)]
        if name=='json-lsp':args.append('--stdio')
        if name=='matlab-language-server':args.append('--stdio')
        if name=='jdtls':args += ['--java-executable',str(options.java_home/'bin/java'),'-data',str(directory/'jdtls-data')]
        protocol=Protocol(args)
        try:
            protocol.send({'jsonrpc':'2.0','id':1,'method':'initialize','params':{'processId':os.getpid(),'rootUri':directory.as_uri(),'capabilities':{}}})
            reply=protocol.until(lambda m:m.get('id')==1)
            assert 'result' in reply and 'capabilities' in reply['result'],reply
            protocol.send({'jsonrpc':'2.0','method':'initialized','params':{}})
            protocol.send({'jsonrpc':'2.0','id':2,'method':'shutdown','params':None})
            protocol.until(lambda m:m.get('id')==2)
            protocol.send({'jsonrpc':'2.0','method':'exit','params':None})
            print('PASS actual LSP initialize/shutdown',name,flush=True)
        finally:protocol.close()

    source=directory/'program.py';source.write_text('value = 41\nprint(value + 1)\n')
    c=directory/'program.c';c.write_text('#include <stdio.h>\nint main(void) { int value = 41; printf("%d\\n", value + 1); return 0; }\n')
    exe=directory/'program';run(['clang','-g','-O0',str(c),'-o',str(exe)])
    for name in ['debugpy','codelldb']:
        port=None
        if name=='debugpy':
            python=str(root(name)/'venv/bin/python')
            args=[python,'-m','debugpy.adapter']
            launch={'name':'migration-test','type':'python','request':'launch','program':str(source),'python':[python],'console':'internalConsole','stopOnEntry':True,'justMyCode':True}
        else:
            with socket.socket() as s:s.bind(('127.0.0.1',0));port=s.getsockname()[1]
            args=[binary(name),'--port',str(port)]
            launch={'name':'migration-test','type':'lldb','request':'launch','program':str(exe),'cwd':temp,'stopOnEntry':True}
        protocol=Protocol(args,port)
        try:
            def request(seq,cmd,arguments):protocol.send({'seq':seq,'type':'request','command':cmd,'arguments':arguments})
            request(1,'initialize',{'clientID':'toolchain-tools-test','adapterID':'python' if name=='debugpy' else 'lldb','linesStartAt1':True,'columnsStartAt1':True,'pathFormat':'path'})
            reply=protocol.until(lambda m:m.get('type')=='response' and m.get('request_seq')==1)
            assert reply.get('success'),reply
            request(2,'launch',launch)
            protocol.until(lambda m:m.get('event')=='initialized')
            request(3,'configurationDone',{})
            stopped=protocol.until(lambda m:m.get('event')=='stopped')
            assert stopped.get('body',{}).get('threadId'),stopped
            request(4,'disconnect',{'terminateDebuggee':True})
            print('PASS actual DAP launch/stop/disconnect',name,flush=True)
        finally:protocol.close()

    mermaid=directory/'diagram.mmd';mermaid.write_text('flowchart LR\n A --> B\n')
    svg=directory/'diagram.svg'
    run([binary('mmdc'),'-i',str(mermaid),'-o',str(svg),'--quiet'])
    assert '<svg' in svg.read_text()
    print('PASS actual Mermaid browser rendering',flush=True)
