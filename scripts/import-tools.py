#!/usr/bin/env python3
"""Normalize the supported subset of a pinned compiled Mason registry; never used at runtime."""
import argparse
import hashlib
import json
import re
from pathlib import Path
from urllib.parse import unquote, urlsplit, parse_qs


def expand(value, context):
    if isinstance(value, dict):
        return {k: expand(v, context) for k, v in value.items()}
    if isinstance(value, list):
        return [expand(v, context) for v in value]
    if not isinstance(value, str):
        return value
    def replace(match):
        key = match.group(1).strip()
        if '| strip_prefix "v"' in key:
            return context['version'].removeprefix('v')
        return str(context[key])
    result = re.sub(r'{{\s*(.*?)\s*}}', replace, value)
    assert '{{' not in result
    return result


def archive(filename):
    for suffix, kind in [('.tar.gz', 'tar'), ('.tar.xz', 'tar'), ('.tgz', 'tar'),
                         ('.zip', 'zip'), ('.vsix', 'zip'), ('.gz', 'gzip')]:
        if filename.endswith(suffix):
            return kind
    return 'file'


def convert(entry):
    source = entry['source']
    identifier = source['id']
    body, _, query = identifier.partition('?')
    package, version = body.rsplit('@', 1)
    scheme, package = package.split('/', 1)
    package = unquote(package)
    context = {'version': version}
    result = {'version': version, 'bin': {}}
    if scheme == 'pkg:npm':
        result.update(kind='npm', package=package, extras=source.get('extra_packages', []))
        # Pin upstream's unversioned Vue plugin to the matching language-tools release.
        result['extras'] = [f'{v}@{version}' if v == '@vue/typescript-plugin' else v for v in result['extras']]
        if package == '@vue/language-server':
            pinned = next(v.split('@')[-1] for v in result['extras'] if v.startswith('typescript@'))
            result['overrides'] = {'typescript': pinned}
            result['external_resources'] = {'server': {'executable': 'vue-language-server', 'package': package}}

        if entry['name'] == 'vue-language-server':
            result['resources'] = {'server': 'node_modules/@vue/language-server'}
    elif scheme == 'pkg:pypi':
        extras = parse_qs(query).get('extra', [])
        result.update(kind='pypi', package=package + ('[' + ','.join(extras) + ']' if extras else ''))
        result['resources'] = {'python': 'venv/bin/python'}
    elif scheme == 'pkg:cargo':
        result.update(kind='cargo', package=package, repository=parse_qs(query)['repository_url'][0])
    elif scheme == 'pkg:github' and 'build' in source:
        assert entry['name'] == 'matlab-language-server', 'Review new source build explicitly'
        result.update(kind='npm-build', repository='https://github.com/' + package, revision=version)
    else:
        assert scheme in ('pkg:github', 'pkg:generic')
        result.update(kind='download', assets={})
        for asset in source.get('asset', source.get('download', [])):
            targets = asset['target'] if isinstance(asset['target'], list) else [asset['target']]
            contexts = dict(context)
            contexts.update({'source.asset.' + k: v for k, v in expand(asset, context).items()})
            if isinstance(asset.get('bin'), dict):
                contexts.update({'source.asset.bin.' + k: expand(v, context) for k, v in asset['bin'].items()})
            bins = {}
            for key, value in entry.get('bin', {}).items():
                value = expand(value, contexts)
                bins[key] = descriptor(value, 'payload/')
                if entry['name'] == 'lua-language-server':
                    bins[key]['args'] = ['--logpath={state}/lua-language-server/log',
                                         '--metapath={cache}/lua-language-server/meta']
                if entry['name'] == 'jdtls':
                    bins[key]['args'] = ['-configuration', '{cache}/jdtls/{instance}/configuration']
            for target in targets:
                if target.startswith('win_'):
                    continue
                files = []
                if scheme == 'pkg:github':
                    filename = expand(asset['file'], context)
                    filename, _, destination = filename.partition(':')
                    files.append({'url': f'https://github.com/{package}/releases/download/{version}/{filename}',
                                  'name': filename, 'archive': archive(filename), 'destination': destination})
                else:
                    for filename, url in asset['files'].items():
                        # The registry uses a floating Lombok URL. Pin a known release explicitly.
                        if filename == 'lombok.jar':
                            url = 'https://projectlombok.org/downloads/lombok-1.18.48.jar'
                        files.append({'url': expand(url, context), 'name': filename,
                                      'archive': archive(filename), 'destination': ''})
                result['assets'][target] = {'files': files, 'bin': bins}
                if 'config' in asset:
                    result['assets'][target]['config'] = asset['config']
        if entry['name'] == 'codelldb':
            result['resources'] = {'lldb': 'payload/extension/lldb'}
        if entry['name'] == 'jdtls':
            result['resources'] = {'config': 'payload/config', 'plugins': 'payload/plugins', 'lombok': 'payload/lombok.jar'}
        # Platform-specific paths are selected by the installer, not a template interpreter.
        result['bin'] = next(iter(result['assets'].values()))['bin']
        return result
    for key, value in entry.get('bin', {}).items():
        result['bin'][key] = descriptor(value, '')
    if entry['name'] == 'mmdc':
        result['bin']['mmdc']['env'] = {'PUPPETEER_CACHE_DIR': '{root}/browser'}
        result['resources'] = {'browser': 'browser'}
    return result


def descriptor(value, prefix):
    if value.startswith(('npm:', 'pypi:', 'pyvenv:', 'cargo:', 'node:', 'python:', 'exec:')):
        kind, value = value.split(':', 1)
        if kind == 'npm':
            return {'path': 'node_modules/.bin/' + value}
        if kind == 'pypi':
            return {'path': 'venv/bin/' + value}
        if kind == 'pyvenv':
            return {'path': 'venv/bin/python', 'interpreter': 'python', 'module': value}
        if kind == 'cargo':
            return {'path': 'payload/bin/' + value}
        if kind == 'node':
            return {'path': 'payload/' + value, 'interpreter': 'node'}
        if kind == 'python':
            return {'path': prefix + value, 'interpreter': 'python3'}
    return {'path': prefix + value}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('registry', type=Path)
    parser.add_argument('--info', type=Path, required=True)
    parser.add_argument('--output', type=Path, default=Path('data/tools.json'))
    args = parser.parse_args()
    existing = json.loads(args.output.read_text())
    additions = json.loads((Path(__file__).resolve().parents[1] / 'data/tool-additions.json').read_text())
    names = set(existing['packages']) - set(additions)
    source = json.loads(args.registry.read_text())
    packages = {v['name']: convert(v) for v in source if v['name'] in names}
    assert names == set(packages), names - set(packages)
    packages.update(additions)
    info = json.loads(args.info.read_text())
    value = {'schema': 1, 'upstream': {'repository': 'https://github.com/mason-org/mason-registry',
             'version': info['version'], 'sha256': hashlib.sha256(args.registry.read_bytes()).hexdigest()},
             'packages': packages}
    args.output.write_text(json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + '\n')


if __name__ == '__main__':
    main()
