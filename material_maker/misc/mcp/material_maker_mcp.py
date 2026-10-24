"""Private Material Maker instances for AI agents, and calls to their MCP tools. Put it next to the executable.

    python material_maker_mcp.py start PORT        starts a private instance on PORT, with its own settings folder
    python material_maker_mcp.py stop PORT         closes it (its quit tool, else ends the process)
    python material_maker_mcp.py PORT --list       the tools and their arguments
    python material_maker_mcp.py PORT TOOL [ARGS]  calls a tool; ARGS is a JSON object, or - to read it from stdin

The first line of material_maker_mcp.txt next to this script is added to the arguments of every start, e.g.
--mcp-examples "C:\\my\\graphs". A tool call prints the text result and writes images to PNG files, whose paths
it prints; its exit code is 1 when the tool reports an error.
"""
import base64
import json
import os
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
WINDOWS = sys.platform == 'win32'
EXECUTABLE = 'material_maker.exe' if WINDOWS else 'material_maker.x86_64'
DATA_FOLDERS = ['doc', 'environments', 'examples', 'export', 'library', 'meshes', 'nodes']


def call(port, method, params=None, timeout=660):
    message = {'jsonrpc': '2.0', 'id': 1, 'method': method, 'params': params or {}}
    request = urllib.request.Request(f'http://127.0.0.1:{port}/mcp', json.dumps(message).encode(),
                                     headers={'Content-Type': 'application/json', 'Accept': 'application/json, text/event-stream'})
    # The server lets a tool run for up to 10 minutes
    with urllib.request.urlopen(request, timeout=timeout) as response:
        reply = json.loads(response.read())
    if 'error' in reply:
        sys.exit(reply['error']['message'])
    return reply['result']


def answers(port):
    try:
        call(port, 'ping', timeout=5)
        return True
    except (urllib.error.URLError, OSError):
        return False


def instance_folder(port):
    base = os.environ.get('LOCALAPPDATA') if WINDOWS else os.path.expanduser('~/.local/share')
    return os.path.join(base, 'material_maker_mcp', str(port))


def settings_folder(port):
    # Where Godot puts a custom user folder
    base = os.environ.get('APPDATA') if WINDOWS else os.path.expanduser('~/.local/share')
    return os.path.join(base, f'material_maker_mcp_{port}')


def start(port):
    if answers(port):
        sys.exit(f'Port {port} already answers: that instance is running')
    # Material Maker reads its settings folder from override.cfg next to the executable, so a private instance runs
    # from a folder of its own: a link to the executable, links to the data folders, and its override.cfg
    folder = instance_folder(port)
    os.makedirs(folder, exist_ok=True)
    for name in DATA_FOLDERS:
        target, link = os.path.join(HERE, name), os.path.join(folder, name)
        if os.path.isdir(target) and not os.path.lexists(link):
            if WINDOWS:
                subprocess.run(['cmd', '/c', 'mklink', '/j', link, target], capture_output=True, check=True)
            else:
                os.symlink(target, link, target_is_directory=True)
    # Linked again at each start, so the instance runs the current executable after an update
    executable = os.path.join(folder, EXECUTABLE)
    if os.path.lexists(executable):
        os.remove(executable)
    try:
        os.link(os.path.join(HERE, EXECUTABLE), executable)
    except OSError:
        shutil.copy2(os.path.join(HERE, EXECUTABLE), executable)
    with open(os.path.join(folder, 'override.cfg'), 'w') as f:
        f.write(f'[application]\n\nconfig/use_custom_user_dir=true\nconfig/custom_user_dir_name="material_maker_mcp_{port}"\n')
    arguments = [executable, '--mcp-port', str(port)]
    extra = os.path.join(HERE, 'material_maker_mcp.txt')
    if os.path.exists(extra):
        with open(extra) as f:
            arguments += shlex.split(f.readline(), posix=not WINDOWS)
    # Without handles of this process, so a caller that reads its output does not wait for Material Maker
    flags = subprocess.DETACHED_PROCESS | subprocess.CREATE_NEW_PROCESS_GROUP if WINDOWS else 0
    process = subprocess.Popen([a.strip('"') for a in arguments], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                               stderr=subprocess.DEVNULL, close_fds=True, creationflags=flags, start_new_session=not WINDOWS)
    with open(os.path.join(folder, 'pid'), 'w') as f:
        f.write(str(process.pid))
    deadline = time.time()+180
    while time.time() < deadline:
        if answers(port):
            print(f'Material Maker answers on http://127.0.0.1:{port}/mcp, settings in {settings_folder(port)}')
            return
        if process.poll() is not None:
            sys.exit(f'Material Maker exited with code {process.returncode}')
        time.sleep(1)
    sys.exit('Material Maker started but its MCP server did not answer within 3 minutes')


def stop(port):
    if answers(port) and not call(port, 'tools/call', {'name': 'quit', 'arguments': {}}, timeout=30).get('isError'):
        deadline = time.time()+30
        while time.time() < deadline and answers(port):
            time.sleep(1)
    pid_file = os.path.join(instance_folder(port), 'pid')
    if answers(port) and os.path.exists(pid_file):
        with open(pid_file) as f:
            pid = int(f.read())
        if WINDOWS:
            subprocess.run(['taskkill', '/f', '/pid', str(pid)], capture_output=True)
        else:
            os.kill(pid, 9)
        # Its recovery files would make the next start wait for an answer
        recovery = os.path.join(settings_folder(port), 'unsaved_projects')
        for name in os.listdir(recovery) if os.path.isdir(recovery) else []:
            if name.endswith('.mmcr'):
                os.remove(os.path.join(recovery, name))
    print(f'Port {port} is free' if not answers(port) else f'Port {port} still answers')


def call_tool(port, tool, text):
    if tool == '--list':
        for t in call(port, 'tools/list')['tools']:
            print(f"{t['name']}({', '.join(t['inputSchema'].get('properties', {}))}): {t['description']}")
        return
    arguments = json.loads(sys.stdin.read() if text == '-' else text)
    result = call(port, 'tools/call', {'name': tool, 'arguments': arguments})
    for i, item in enumerate(result['content']):
        if item['type'] == 'text':
            print(item['text'])
        elif item['type'] == 'image':
            path = os.path.join(tempfile.gettempdir(), f'material_maker_{port}_{tool}_{os.getpid()}_{i}.png')
            with open(path, 'wb') as f:
                f.write(base64.b64decode(item['data']))
            print('image:', path)
    sys.exit(1 if result.get('isError') else 0)


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    if sys.argv[1] == 'start':
        start(int(sys.argv[2]))
    elif sys.argv[1] == 'stop':
        stop(int(sys.argv[2]))
    else:
        call_tool(int(sys.argv[1]), sys.argv[2], sys.argv[3] if len(sys.argv) > 3 else '{}')


if __name__ == '__main__':
    main()
