"""Integration tests of the MCP server (addons/material_maker_mcp), from a client's side.

    python test/mcp/run.py --godot <Godot 4 editor executable>    tests this checkout
    python test/mcp/run.py --exe <material_maker executable>      tests a release (material_maker_mcp.py beside it)

It starts a private Material Maker on port 8799 (--port) with a settings folder of its own, calls the tools over HTTP and
prints each check. A checkout runs from a copy (in the temporary folder, synced at each run) whose project names that
settings folder. Edits work on copies of fixtures/ and of the cookbook; nothing else is written. Python 3 and Pillow.
"""
import argparse, glob, json, os, shutil, subprocess, sys, tempfile, time, urllib.error, urllib.request
from PIL import Image, ImageChops, ImageStat

HERE = os.path.dirname(os.path.abspath(__file__))
CHECKOUT = os.path.dirname(os.path.dirname(HERE))
WORK = os.path.join(tempfile.gettempdir(), 'material_maker_mcp_tests')
SETTINGS = 'material_maker_mcp_tests'
failures = []


def check(label, condition, detail=''):
    if not condition:
        failures.append(label)
    print(f"{'ok ' if condition else 'BAD'} {label} {detail}"[:400], flush=True)


class Client:
    def __init__(self, port):
        self.url = f'http://127.0.0.1:{port}/mcp'

    def call(self, tool, **arguments):
        """The tool's result (parsed JSON or text), and whether it is an error"""
        body = json.dumps({'jsonrpc': '2.0', 'id': 1, 'method': 'tools/call', 'params': {'name': tool, 'arguments': arguments}})
        request = urllib.request.Request(self.url, body.encode(), {'Content-Type': 'application/json', 'Accept': 'application/json, text/event-stream'})
        result = json.loads(urllib.request.urlopen(request, timeout=900).read())['result']
        text = result['content'][0]['text']
        try:
            return json.loads(text), result['isError']
        except ValueError:
            return text, result['isError']

    def tools(self):
        body = json.dumps({'jsonrpc': '2.0', 'id': 1, 'method': 'tools/list'})
        request = urllib.request.Request(self.url, body.encode(), {'Content-Type': 'application/json', 'Accept': 'application/json, text/event-stream'})
        return {t['name']: t for t in json.loads(urllib.request.urlopen(request, timeout=60).read())['result']['tools']}


def sync_checkout(target):
    """Copies the checkout (without .git) to target, files whose size or time changed only, and names the settings folder"""
    for root, dirs, files in os.walk(CHECKOUT):
        dirs[:] = [d for d in dirs if d != '.git']
        relative = os.path.relpath(root, CHECKOUT)
        os.makedirs(os.path.join(target, relative), exist_ok=True)
        for f in files:
            source, copy = os.path.join(root, f), os.path.join(target, relative, f)
            if not os.path.exists(copy) or os.path.getsize(copy) != os.path.getsize(source) or os.path.getmtime(copy) < os.path.getmtime(source):
                shutil.copy2(source, copy)
    project = os.path.join(target, 'project.godot')
    text = open(project, encoding='utf-8').read()
    lines = [f'config/custom_user_dir_name="{SETTINGS}"' if line.startswith('config/custom_user_dir_name=') else line for line in text.splitlines()]
    open(project, 'w', encoding='utf-8', newline='\n').write('\n'.join(lines) + '\n')


def start(options, port):
    """Starts Material Maker and returns a function that stops it"""
    if options.godot:
        copy = os.path.join(WORK, 'checkout')
        sync_checkout(copy)
        log = open(os.path.join(WORK, 'material_maker.log'), 'w', encoding='utf-8')
        process = subprocess.Popen([options.godot, '--path', copy, '--mcp-port', str(port)], stdout=log, stderr=subprocess.STDOUT)

        def stop():
            process.terminate()
            try:
                process.wait(20)
            except subprocess.TimeoutExpired:
                subprocess.run(['taskkill', '/F', '/T', '/PID', str(process.pid)], capture_output=True)
            log.close()
        return stop
    launcher = os.path.join(os.path.dirname(options.exe), 'material_maker_mcp.py')
    subprocess.run([sys.executable, launcher, 'start', str(port)], check=True, timeout=300)
    return lambda: subprocess.run([sys.executable, launcher, 'stop', str(port)], timeout=120)


def wait_until_ready(client):
    deadline = time.time() + 180
    while time.time() < deadline:
        try:
            if not client.call('list_nodes', filter='x')[1]:
                return
        except (urllib.error.URLError, ConnectionError, OSError):
            pass
        time.sleep(1)
    sys.exit('Material Maker did not answer')


def image(path):
    return Image.open(path).convert('RGB')


def node(graph, path):
    for name in path.split('/'):
        graph = next(n for n in graph['nodes'] if n['name'] == name)
    return graph


def test_tools(client):
    tools = client.tools()
    for name in ('edit_files', 'verify_export', 'export_material', 'apply_edits', 'render_preview', 'load_graph', 'quit'):
        check(f'tool {name} is listed', name in tools)
    check('render_preview has the game view', 'game' in tools['render_preview']['inputSchema']['properties']['view']['enum'])


def test_round_trip(client, files):
    """A node added and removed again leaves every file byte for byte as it was"""
    before = {f: open(f, 'rb').read() for f in files}
    result, error = client.call('edit_files', files=files, save=True, edits=[{'op': 'add', 'node': 'shape', 'name': 'RoundTrip'}])
    check('a node is added to every file', not error and result['saved'] == len(files), '' if not error else result)
    result, error = client.call('edit_files', files=files, save=True, edits=[{'op': 'remove', 'node': 'RoundTrip'}])
    check('and removed again', not error and result['saved'] == len(files), '' if not error else result)
    changed = [os.path.basename(f) for f in files if open(f, 'rb').read() != before[f]]
    check(f'{len(files)} files are byte-identical afterwards', not changed, changed[:5])


def test_parameters(client, fixture):
    original = open(fixture, 'rb').read()
    result, error = client.call('edit_files', files=[fixture], edits=[{'op': 'remove_parameter', 'subgraph': 'Surface', 'name': 'Relief'}])
    check('a parameter still used by an expression is not removed', 'still used' in json.dumps(result), result)
    result, error = client.call('edit_files', files=[fixture], save=True, edits=[{'op': 'rename_parameter', 'subgraph': 'Surface', 'name': 'Relief', 'new_name': 'Height'}])
    check('rename_parameter is saved', not error and result['saved'] == 1, result)
    graph = json.load(open(fixture, encoding='utf-8'))
    check('the expression follows', node(graph, 'Surface/Scale')['parameters']['default_in2'] == '$Height*0.5')
    check('the subgraph value follows', 'Height' in node(graph, 'Surface')['parameters'] and 'Relief' not in node(graph, 'Surface')['parameters'])
    check('the linked control follows', node(graph, 'Controls')['widgets'][0]['linked_widgets'] == [{'node': 'Surface', 'widget': 'Height'}])
    open(fixture, 'wb').write(original)


def test_export(client, fixture, out):
    maps = os.path.join(out, 'maps')
    result, error = client.call('export_material', graph_path=fixture, path=os.path.join(maps, 'surface').replace(os.sep, '/'))
    names = sorted(os.path.basename(f) for f in result.get('files', [])) if not error else result
    check('export_material writes the maps and the .tres', not error and 'surface.tres' in names and 'surface_albedo.png' in names, names)
    result, error = client.call('verify_export', files=[fixture], maps=maps)
    check('verify_export finds the same export identical', not error and result['differing'] == 0, result)
    result, error = client.call('verify_export', files=[fixture], maps=maps, exact_8bit=True)
    differences = [v for v in (result['files'][0].get('files') or {}).values() if v != 'identical'] if not error else [result]
    check('the exact 8-bit export differs by at most one code', all(isinstance(v, dict) and v['max_difference'] <= 1 for v in differences), differences)
    # A node that adds 0, removed and bridged, changes no map
    original = open(fixture, 'rb').read()
    result, error = client.call('edit_files', files=[fixture], save=True, edits=[{'op': 'remove', 'subgraph': 'Surface', 'node': 'Offset', 'bridge': True}])
    graph = json.load(open(fixture, encoding='utf-8'))
    wires = [f"{c['from']}:{c['from_port']}->{c['to']}:{c['to_port']}" for c in node(graph, 'Surface')['connections']]
    check('remove with bridge rewires the consumers', not error and 'Scale:0->gen_outputs:0' in wires, wires)
    result, error = client.call('verify_export', files=[fixture], maps=maps)
    check('and the export stays identical', not error and result['differing'] == 0, result)
    open(fixture, 'wb').write(original)


def test_live(client, fixture, out):
    result, error = client.call('load_graph', path=fixture)
    check('load_graph opens a tab', not error, result)
    tab = result['tab']
    result, error = client.call('apply_edits', tab=tab, subgraph='Surface', edits=[{'op': 'rename_parameter', 'name': 'Relief', 'new_name': 'Height'}])
    graph = client.call('get_graph', tab=tab, subgraph='', full=True)[0]['graph']
    check('a live rename reaches the expression', not error and node(graph, 'Surface/Scale')['parameters']['default_in2'] == '$Height*0.5', result)
    for view in ('sphere', 'plane', 'tiled', 'game'):
        path = os.path.join(out, f'{view}.png').replace(os.sep, '/')
        result, error = client.call('render_preview', tab=tab, view=view, size=256, path=path)
        check(f'render_preview {view}', not error and min(ImageStat.Stat(image(path)).stddev) > 2, '' if not error else result)
    grid_off = os.path.join(out, 'game-no-grid.png').replace(os.sep, '/')
    client.call('render_preview', tab=tab, view='game', size=256, path=grid_off, game={'grid': False})
    check('the game view draws the hex grid', ImageChops.difference(image(os.path.join(out, 'game.png')), image(grid_off)).getbbox() is not None)

    def game(name, settings, **view):
        client.call('set_parameters', tab=tab, subgraph='', node='Material', parameters=settings)
        path = os.path.join(out, f'game-{name}.png').replace(os.sep, '/')
        client.call('render_preview', tab=tab, view='game', size=256, path=path, game=dict(view, grid=False))
        return image(path)

    def brightness(picture):
        return sum(ImageStat.Stat(picture).mean)

    # The .tres settings the game applies: emission, the heightmap's parallax, the albedo tint
    lit, dark = game('lit', {'emission_energy': 1.0}), game('dark', {'emission_energy': 0.0})
    check('the game view adds the emission map', brightness(lit) > brightness(dark) * 1.1, [brightness(lit), brightness(dark)])
    flat, tilted = game('flat', {'depth_scale': 0.0}), game('tilted', {'depth_scale': 0.0}, tilt=60)
    check('the parallax moves nothing seen from straight above', ImageChops.difference(flat, game('flat-deep', {'depth_scale': 2.0})).getbbox() is None)
    check('and moves the ground at a tilt', ImageChops.difference(tilted, game('tilted-deep', {'depth_scale': 2.0}, tilt=60)).getbbox() is not None)
    tinted = game('tinted', {'albedo_color': {'type': 'Color', 'r': .25, 'g': .25, 'b': .25, 'a': 1}})
    check('the game view applies the albedo tint', brightness(tinted) < brightness(game('untinted', {'albedo_color': {'type': 'Color', 'r': 1, 'g': 1, 'b': 1, 'a': 1}})) * .6)
    result, error = client.call('close_graph', tab=tab, discard=True)
    check('close_graph discards the edits', not error and open(fixture, 'rb').read() == open(os.path.join(HERE, 'fixtures', 'surface.ptex'), 'rb').read(), result)


def main():
    arguments = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    group = arguments.add_mutually_exclusive_group(required=True)
    group.add_argument('--godot', help='Godot 4 editor executable, to test this checkout')
    group.add_argument('--exe', help='material_maker executable of a release')
    arguments.add_argument('--port', type=int, default=8799, help='a port no other Material Maker uses, default 8799')
    options = arguments.parse_args()
    out = os.path.join(WORK, 'files')
    shutil.rmtree(out, ignore_errors=True)
    os.makedirs(out)
    fixture = os.path.join(out, 'surface.ptex')
    shutil.copy(os.path.join(HERE, 'fixtures', 'surface.ptex'), fixture)
    cookbook = os.path.join(out, 'cookbook')
    shutil.copytree(os.path.join(CHECKOUT, 'material_maker', 'examples', 'cookbook'), cookbook)
    port = options.port
    stop = start(options, port)
    try:
        client = Client(port)
        wait_until_ready(client)
        test_tools(client)
        test_round_trip(client, sorted(glob.glob(os.path.join(cookbook, '*', '*.ptex'))) + [fixture])
        test_parameters(client, fixture)
        test_export(client, fixture, out)
        test_live(client, fixture, out)
    finally:
        stop()
    print('FAILURES:', failures or 'none')
    sys.exit(1 if failures else 0)


if __name__ == '__main__':
    main()
