# Material Maker

This is a tool based on [Godot Engine](https://godotengine.org/) that can
be used to create textures procedurally and paint 3D models.

Its user interface is based on Godot's GraphEdit node: textures and brushes are
described as interconnected nodes.

![Screenshot](material_maker/doc/images/screenshot.png)

## Download

- **[itch.io](https://rodzilla.itch.io/material-maker)**
- **[Steam](https://store.steampowered.com/app/4110830/Material_Maker/)**

On Windows, you can also install Material Maker using [Scoop](https://scoop.sh):

```text
scoop bucket add extras
scoop install material-maker
```
... or [Chocolatey](https://chocolatey.org/) (default or portable install):
```text
choco install material-maker
```
```text
choco install material-maker.portable
```

on macOS, you can also install Material Maker using [Homebrew](https://brew.sh/):

```text
brew install material-maker
```

Can't wait for next release? Automated builds from master branch are available (use at your own risk):

[![Build Material Maker](https://github.com/RodZill4/material-maker/actions/workflows/dev-desktop-builds.yml/badge.svg?branch=master)](https://github.com/RodZill4/material-maker/actions/workflows/dev-desktop-builds.yml?query=branch%3Amaster)

## Documentation

- **[User manual](https://rodzill4.github.io/material-maker/doc/)**

## MCP server for AI agents

This fork ([releases](https://github.com/exeea/material-maker/releases)) can be driven by AI agents through the
[Model Context Protocol](https://modelcontextprotocol.io). Start Material Maker with `--mcp` (port 8790) or
`--mcp-port <port>`:

```text
material_maker.exe --mcp
./material_maker.x86_64 --mcp
open -a "Material Maker" --args --mcp
```

Then add `http://127.0.0.1:8790/mcp` to your agent as a Streamable HTTP server, for example in Claude Code:

```text
claude mcp add --transport http material-maker http://127.0.0.1:8790/mcp
```

The agent works on a tab, live: you see every change and can undo it. Tools use the current tab and the graph it
shows, or the tab and subgraph the agent names (a tab handle from `load_graph`, `new_graph` or `get_graph`, and a
path of subgraph node names), so switching tabs does not redirect its work. Add
`--mcp-examples <folder>` (repeatable) to also list a project's own `.ptex` graphs in `list_examples`, each described
by its first comment.

| Tool | What it does |
|---|---|
| `list_nodes`, `describe_node` | Search the node library; parameters, inputs and outputs of a node |
| `validate_graph` | Build a `.ptex` graph without opening it and report what Material Maker cannot create or connect |
| `load_graph`, `new_graph`, `get_graph`, `save_graph`, `close_graph` | Open, create, read (compact or as full JSON), save and close projects |
| `apply_edits` | Several edits (add, connect, disconnect, remove, set, and exposed parameters: add, update, rename, remove) in one call and one undo step |
| `add_node`, `connect_nodes`, `disconnect_nodes`, `remove_node`, `set_parameters` | Single edits |
| `render_node` | Render a node output, or a map of the Material node, as an image |
| `render_preview`, `render_sweep` | Render the material lit on a sphere or a square, or tiled 3x3 to check seams; a contact sheet across values of one parameter |
| `export_material` | Export the texture maps of a project or of a `.ptex` file |
| `verify_export` | Export projects into a temporary folder and compare them with the shipped maps and `.tres`: identical, or the texels that differ and the largest difference |
| `edit_files` | Apply the same edits to many `.ptex` files without opening them: nodes (add, connect, remove with bridging), values (also computed from each project's parameters), exposed parameters (add, rename, remove, kept consistent), comments, image paths, graph names and copies of a shared subgraph (kept in sync with a master, local edits reported); reports each file's changes and saves it in its own layout |
| `list_examples` | Example projects, including a cookbook of 55 finished materials with recipe notes |
| `quit` | Close a private instance (see below) |

The server only accepts connections from this computer. Material Maker's window must stay open, because
rendering uses the GPU.

### Several agents at once

One Material Maker runs one tool at a time, so agents sharing it wait for each other, and a tab one agent
closes is gone for the others. `material_maker_mcp.py` (next to the executable in the Windows and Linux releases,
Python 3 without other packages) starts private instances, each with its own port and settings folder, and calls
their tools for a session that has no MCP registration for that port:

```text
python material_maker_mcp.py start 8791                  returns once the instance answers
python material_maker_mcp.py 8791 --list                 its tools and their arguments
python material_maker_mcp.py 8791 load_graph '{"path": "C:/my/graphs/rock.ptex"}'
python material_maker_mcp.py stop 8791                   closes it, discarding unsaved changes
```

Tool results are printed, and images are written to PNG files whose paths are printed. A session started later can
register the instance instead (`claude mcp add --transport http material-maker-8791 http://127.0.0.1:8791/mcp`).
On Windows, `material_maker_mcp.cmd` starts the shared instance on port 8790. The first line of
`material_maker_mcp.txt` next to them is added to every start, e.g. `--mcp-examples "C:\my\graphs"`.

## Translations

Translation files can be installed using the **Install** button in the **Preferences** dialog.

- [Chinese translation](https://raw.githubusercontent.com/RodZill4/material-maker/f1be50b21a0f4991ac39e12a5362f5c5eb4c83a0/material_maker/locale/translations/zh.csv) (Created by **free_king**)

## Community

- **[Discord server](https://discord.gg/PF5V3mFwFM)**
- **[Material Maker subreddit](https://www.reddit.com/r/MaterialMaker/)**

## License

Copyright (c) 2018-present Rodolphe Suescun and contributors

Unless otherwise specified, files in this repository are licensed under the
MIT license. See [LICENSE.md](LICENSE.md) for more information.
