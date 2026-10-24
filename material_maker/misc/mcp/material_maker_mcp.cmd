@echo off
rem Starts Material Maker with its MCP server for AI agents, on http://127.0.0.1:8790/mcp.
rem The first line of material_maker_mcp.txt next to this file is added to the arguments,
rem e.g. --mcp-examples "C:\my\graphs". Private instances: python material_maker_mcp.py start <port>
setlocal
set "EXTRA="
if exist "%~dp0material_maker_mcp.txt" set /p EXTRA=<"%~dp0material_maker_mcp.txt"
start "" "%~dp0material_maker.exe" --mcp %EXTRA%
