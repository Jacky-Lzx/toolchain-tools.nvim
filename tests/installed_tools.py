"""Run actual migrated tools without loading either Neovim or Mason."""
import argparse
import json
import os
import socket
import tempfile
from pathlib import Path

from tool_protocols import Protocol, run

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
            def request(seq,cmd,arguments,protocol=protocol):protocol.send({'seq':seq,'type':'request','command':cmd,'arguments':arguments})
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
