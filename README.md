# fs-ide-linux-patch

Patches the GIANTS "Farming Simulator IDE Support" VS Code extension to work on Linux and sets up the matching VS Code settings.

<img width="1155" height="896" alt="image" src="https://github.com/user-attachments/assets/d360fb15-d5f5-4bad-9971-d01df68404cc" />

## Why

The official GIANTS VS Code extension ships its Lua language server only as a Windows `.exe`. On Linux, this breaks Lua IntelliSense, diagnostics and stub generation. This script makes the extension work on Linux. It was tested on Kubuntu with Steam/Proton and Bottles.

## What it does

1. **Finds the extension.** It searches the usual VS Code extension folders (native, Insiders, VSCodium, Flatpak, portable) and lets you pick one or enter a custom path.
2. **Installs the Linux language server.** It reads the bundled LuaLS version and downloads the matching official Linux binary from the [LuaLS GitHub releases](https://github.com/LuaLS/lua-language-server/releases). GIANTS' customized server scripts are left unchanged.
3. **Patches `out/extension.js`** so that on Linux it:
   - starts the Linux binary instead of `lua-language-server.exe`
   - extracts `gameSource.zip` with `unzip` instead of PowerShell

   A backup is saved as `extension.js.orig`, and running the script again is safe.
4. **Detects your paths.** It looks for the game folder, `log.txt` and the GIANTS Editor in Steam (all library folders, including Flatpak Steam), Bottles and Wine prefixes.
5. **Recommends settings** and can write them into your `settings.json`. It asks before each change, keeps comments and formatting, and creates a timestamped backup first.

| Setting | Recommended value |
| --- | --- |
| `fsLua.gamePath` | Game folder (contains `data/`) |
| `fsLua.gameLogPath` | The `log.txt` file itself (a folder does not work) |
| `fsLua.editorPath` | GIANTS Editor folder, e.g. inside a Bottles prefix |
| `fsLua.maxPreload` | `10000` (default `2500`) |
| `fsLua.preloadFileSize` | `2048` (default `500`) |
| `Lua.workspace.maxPreload` | `10000` (only if the sumneko Lua extension is installed or the setting already exists) |

## Requirements

- `bash`, `curl`, `tar`, `python3`, `unzip`
- `node` (optional, used for the syntax check of the patched `extension.js`)
- Internet access to GitHub for the LuaLS download

## Usage

```bash
bash fs-ide-linux-patch.sh                     # search known locations and ask
bash fs-ide-linux-patch.sh /path/to/extension  # patch a specific extension folder
NO_COLOR=1 bash fs-ide-linux-patch.sh          # without colors
```

Afterwards, restart VS Code or run **FS Lua: Restart Language Server**.

## Notes

- **Run it again after every extension update.** Updates replace the patched files. If GIANTS changes the code the script patches, it stops with a message instead of patching blindly.
- **Launching from VS Code:** Starting the game or the GIANTS Editor directly from VS Code is not supported on Linux, because both are Windows programs. For debugging:
  1. Start the game through Steam/Proton (or Bottles) with these launch options:
     ```
     -autoConnectDebugger -debuggerAddress localhost:<port>
     ```
  2. Use the extension's attach mode.
- **Undo:**
  - Restore `out/extension.js.orig` to `out/extension.js` and delete `server/lua-language-server/bin/lua-language-server`.
  - Restore `settings.json` from the `settings.json.bak-<timestamp>` file next to it.
