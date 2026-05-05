# kobo-cli

Minimal Lua CLI to load and remove books on a USB-mounted Kobo e-reader.
Copies files into author-named subdirectories; Kobo re-indexes on USB eject.

## Requirements

- Lua 5.4 (Windows). Nothing else.

The tool uses Windows' built-in `dir`, `mkdir`, and `rmdir` commands via `io.popen` /
`os.execute`, so no LuaRocks, no LuaFileSystem, no C compiler.

## Install (Windows)

1. Download Lua 5.4 binaries from <https://luabinaries.sourceforge.net/download.html>.
   - Extract to `C:\Lua54`, rename `lua54.exe` → `lua.exe`.
   - Add `C:\Lua54` to your system `PATH`.
2. Verify: `lua -v` should print `Lua 5.4.x`.

That's it.

## Config

Copy `config.example.lua` to `config.lua` (git-ignored) and set your Kobo drive letter:

```lua
return {
  kobo_root = "D:\\"
}
```

The tool looks for `config.lua` in two places (in order):

1. Same directory as `kobo.lua` (repo-local)
2. `%USERPROFILE%\.kobo-cli\config.lua` (user-global)

A line is printed to stderr showing which config file was loaded.

## Usage

```
lua kobo.lua add --author "Last, First" <path-to-book>
lua kobo.lua list
lua kobo.lua rm  --author "Last, First" <basename>
```

### Examples

```powershell
# Copy a book to the Kobo
lua kobo.lua add --author "Adams, Douglas" "C:\Downloads\Hitchhiker.kepub.epub"
# Added: Adams, Douglas/Hitchhiker.kepub.epub

# List all books on the Kobo
lua kobo.lua list
# Adams, Douglas/Hitchhiker.kepub.epub
# Pratchett, Terry/Guards Guards.kepub.epub

# Remove a book (removes empty author dir automatically)
lua kobo.lua rm --author "Adams, Douglas" "Hitchhiker.kepub.epub"
# Removed: Adams, Douglas/Hitchhiker.kepub.epub
# Removed empty author directory: Adams, Douglas
```

The `--author` flag may appear before or after the positional argument.

## Supported formats

`.kepub.epub`, `.epub`, `.kepub`, `.pdf`, `.cbz`, `.txt`, `.mobi`

## Notes

- The tool is intentionally dumb: it does no filename parsing. Pass `--author` explicitly.
- System directories (`.kobo`, `.kobo-images`, `.adobe-digital-editions`, `.add`,
  `System Volume Information`) are never touched.
- `add` validates source exists, extension is supported, and verifies copy size matches
  source before reporting success.
- Windows-only. Directory listing uses `dir /b`; filenames with non-ASCII characters
  may be affected by the active console codepage. ASCII filenames work without issue.
