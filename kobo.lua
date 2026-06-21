#!/usr/bin/env lua
-- kobo.lua: minimal Kobo e-reader file manager (add / list / rm)
-- Pure Lua 5.4. No external libraries. Windows-only (uses cmd's `dir`, `mkdir`, `rmdir`).

-- ---------------------------------------------------------------------------
-- Constants
-- ---------------------------------------------------------------------------

local SYSTEM_DIRS = {
  [".kobo"]                       = true,
  [".kobo-images"]                = true,
  [".adobe-digital-editions"]     = true,
  [".add"]                        = true,
  ["system volume information"]   = true,  -- stored lowercase; compare via :lower()
}

-- Longest extensions first so .kepub.epub matches before .epub
local VALID_EXTENSIONS = {
  ".kepub.epub", ".epub", ".kepub", ".pdf", ".cbz", ".txt", ".mobi"
}

local CHUNK = 1024 * 1024

-- ---------------------------------------------------------------------------
-- Utility functions
-- ---------------------------------------------------------------------------

local function die(msg)
  io.stderr:write("Error: " .. msg .. "\n")
  os.exit(1)
end

local function normalize_path(p)
  return (p:gsub("\\", "/"))
end

local function winpath(p)
  return (p:gsub("/", "\\"))
end

local function path_join(...)
  local parts = { ... }
  local result = ""
  for i, part in ipairs(parts) do
    part = normalize_path(part)
    if i == 1 then
      result = part
    else
      result = result:gsub("/+$", "") .. "/" .. part:gsub("^/+", "")
    end
  end
  return result
end

local function basename(path)
  path = normalize_path(path)
  return path:match("[^/]+$") or path
end

local function is_system_dir(name)
  return SYSTEM_DIRS[name:lower()] ~= nil
end

-- has_valid_ext: returns (true, matched_ext) or (false, last_ext_for_error)
local function has_valid_ext(name)
  for _, ext in ipairs(VALID_EXTENSIONS) do
    local elen = #ext
    if #name >= elen and name:sub(-elen):lower() == ext then
      return true, ext
    end
  end
  return false, (name:match("%.[^%.]+$") or "")
end

local function file_exists(path)
  local f = io.open(path, "r")
  if f then f:close(); return true end
  return false
end

local function file_size(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local size = f:seek("end")
  f:close()
  return size
end

-- ---------------------------------------------------------------------------
-- Windows shell helpers (replaces LuaFileSystem)
-- ---------------------------------------------------------------------------

-- Run a cmd command silently; returns true on exit code 0
local function exec_silent(cmd)
  local ok = os.execute(cmd .. " >nul 2>nul")
  return ok == true or ok == 0
end

-- Read all lines from io.popen, suppressing stderr
local function popen_lines(cmd)
  local lines = {}
  local p = io.popen(cmd .. " 2>nul", "r")
  if not p then return lines end
  for line in p:lines() do
    if line ~= "" then lines[#lines + 1] = line end
  end
  p:close()
  return lines
end

-- Quote a path for cmd (already converted to backslashes by caller)
local function q(s)
  return '"' .. s .. '"'
end

-- is_dir: trick using `if exist "<path>\."` — true only when path is a directory
local function is_dir(path)
  local cmd = 'if exist ' .. q(winpath(path) .. "\\.") .. ' (echo y)'
  for _, line in ipairs(popen_lines(cmd)) do
    if line:match("^y") then return true end
  end
  return false
end

-- list_entries: filenames inside a directory (no path prefix). Optionally only dirs (/a:d) or only files (/a:-d).
local function list_entries(path, mode)
  local flag = ""
  if mode == "dirs"  then flag = " /a:d"  end
  if mode == "files" then flag = " /a:-d" end
  return popen_lines('dir /b' .. flag .. ' ' .. q(winpath(path)))
end

local function mkdir_safe(path)
  if exec_silent('mkdir ' .. q(winpath(path))) then return true end
  return nil, "mkdir failed for " .. path
end

local function rmdir_safe(path)
  return exec_silent('rmdir ' .. q(winpath(path)))
end

-- copy_file: binary chunk copy with write-error handling and partial-file cleanup
local function copy_file(src, dst)
  local fsrc, err1 = io.open(src, "rb")
  if not fsrc then return nil, "Cannot open source: " .. (err1 or src) end

  local fdst, err2 = io.open(dst, "wb")
  if not fdst then
    fsrc:close()
    return nil, "Cannot open destination: " .. (err2 or dst)
  end

  while true do
    local chunk, rerr = fsrc:read(CHUNK)
    if chunk == nil then
      if rerr then
        fsrc:close(); fdst:close(); os.remove(dst)
        return nil, "Read error: " .. rerr
      end
      break  -- EOF
    end
    local ok, werr = fdst:write(chunk)
    if not ok then
      fsrc:close(); fdst:close(); os.remove(dst)
      return nil, "Write error: " .. (werr or "unknown")
    end
  end

  fsrc:close()
  fdst:close()
  return true
end

-- ---------------------------------------------------------------------------
-- Config loading
-- ---------------------------------------------------------------------------

local function load_config()
  local script = normalize_path(arg[0] or "kobo.lua")
  local script_dir = script:match("^(.*)/[^/]+$") or "."

  local repo_cfg = script_dir .. "/config.lua"
  local home     = os.getenv("USERPROFILE") or os.getenv("HOME") or ""
  local user_cfg = home .. "/.kobo-cli/config.lua"

  local loaded_path
  local cfg

  if file_exists(repo_cfg) then
    local ok, result = pcall(dofile, repo_cfg)
    if not ok then die("Failed to load config: " .. tostring(result)) end
    cfg, loaded_path = result, repo_cfg
  elseif file_exists(user_cfg) then
    local ok, result = pcall(dofile, user_cfg)
    if not ok then die("Failed to load config: " .. tostring(result)) end
    cfg, loaded_path = result, user_cfg
  else
    die(
      "No config.lua found. Looked in " .. repo_cfg ..
      " and " .. user_cfg ..
      ".\nCreate one with: kobo_root = \"D:\\\\\""
    )
  end

  -- Required: log which config is active (zero implicit behavior under two-location precedence)
  io.stderr:write("-- config: " .. loaded_path .. "\n")

  if type(cfg) ~= "table" then
    die("Config must return a table (got " .. type(cfg) .. ")")
  end
  if type(cfg.kobo_root) ~= "string" or cfg.kobo_root == "" then
    die("Config must set kobo_root to a non-empty string")
  end

  local kobo_root = normalize_path(cfg.kobo_root)
  kobo_root = kobo_root:gsub("/+$", "")
  if kobo_root == "" then kobo_root = "/" end
  -- Drive-letter root: keep trailing slash so D:/ stays D:/ and not D: (current dir on D:)
  if kobo_root:match("^%a:$") then kobo_root = kobo_root .. "/" end

  if not is_dir(kobo_root) then
    die("Kobo root not accessible: " .. cfg.kobo_root .. " -- is the device mounted?")
  end

  return kobo_root
end

-- ---------------------------------------------------------------------------
-- Arg parsing
-- ---------------------------------------------------------------------------

local function parse_args(args, want_author, want_positional)
  local author, positional
  local i = 2
  while i <= #args do
    if args[i] == "--author" then
      i = i + 1
      if i > #args then return nil, nil, "Missing value for --author" end
      author = args[i]
    elseif not positional then
      positional = args[i]
    end
    i = i + 1
  end

  if want_author and not author then
    return nil, nil, "Missing required --author flag"
  end
  if want_positional and not positional then
    return nil, nil, "Missing required " .. want_positional
  end
  return author, positional, nil
end

-- ---------------------------------------------------------------------------
-- Command: add
-- ---------------------------------------------------------------------------

-- add_one: copy a single source file into the author dir. Returns true or (nil, err).
local function add_one(dest_dir, author, src_path)
  local bname = basename(src_path)

  local dest_path = path_join(dest_dir, bname)

  local ok, cerr = copy_file(src_path, dest_path)
  if not ok then return nil, "Copy failed: " .. (cerr or "unknown error") end

  local src_size = file_size(src_path)
  local dst_size = file_size(dest_path)
  if src_size ~= dst_size then
    os.remove(dest_path)
    return nil, "Copy size mismatch (src=" .. tostring(src_size) ..
        " dst=" .. tostring(dst_size) .. "). Partial file removed."
  end

  print("Added: " .. author .. "/" .. bname)
  return true
end

local function cmd_add(kobo_root)
  local author, src_path, err = parse_args(arg, true, "file path")
  if err then die(err) end

  src_path = normalize_path(src_path)

  if is_system_dir(author) then
    die("Refusing to operate in system directory: " .. author)
  end

  local dest_dir = path_join(kobo_root, author)

  -- Directory source: bulk-add every valid-ext file inside (non-recursive).
  if is_dir(src_path) then
    local files = {}
    for _, child in ipairs(list_entries(src_path, "files")) do
      if has_valid_ext(child) then files[#files + 1] = child end
    end
    if #files == 0 then
      die("No supported books found in directory: " .. src_path ..
          "\nSupported: " .. table.concat(VALID_EXTENSIONS, ", "))
    end

    if not is_dir(dest_dir) then
      local ok, mkerr = mkdir_safe(dest_dir)
      if not ok then die("Failed to create author directory: " .. (mkerr or dest_dir)) end
    end

    local added, failed = 0, 0
    for _, child in ipairs(files) do
      local ok, aerr = add_one(dest_dir, author, path_join(src_path, child))
      if ok then added = added + 1
      else failed = failed + 1; io.stderr:write("Error: " .. (aerr or child) .. "\n") end
    end
    print(string.format("Done: %d added, %d failed.", added, failed))
    if failed > 0 then os.exit(1) end
    return
  end

  -- Single-file source.
  if not file_exists(src_path) then
    die("Source file not found: " .. src_path)
  end

  local valid, ext = has_valid_ext(basename(src_path))
  if not valid then
    die(
      "Unsupported file format: " .. ext ..
      ". Supported: " .. table.concat(VALID_EXTENSIONS, ", ")
    )
  end

  if not is_dir(dest_dir) then
    local ok, mkerr = mkdir_safe(dest_dir)
    if not ok then die("Failed to create author directory: " .. (mkerr or dest_dir)) end
  end

  local ok, aerr = add_one(dest_dir, author, src_path)
  if not ok then die(aerr) end
end

-- ---------------------------------------------------------------------------
-- Command: list
-- ---------------------------------------------------------------------------

local function cmd_list(kobo_root)
  local results = {}

  -- Top-level subdirectories (author dirs)
  for _, author in ipairs(list_entries(kobo_root, "dirs")) do
    if not is_system_dir(author) then
      local author_path = path_join(kobo_root, author)
      for _, child in ipairs(list_entries(author_path, "files")) do
        if has_valid_ext(child) then
          results[#results + 1] = author .. "/" .. child
        end
      end
    end
  end

  -- Top-level files (no author prefix)
  for _, fname in ipairs(list_entries(kobo_root, "files")) do
    if has_valid_ext(fname) then
      results[#results + 1] = fname
    end
  end

  table.sort(results)

  if #results == 0 then
    print("No books found on Kobo.")
  else
    for _, line in ipairs(results) do print(line) end
  end
end

-- ---------------------------------------------------------------------------
-- Command: rm
-- ---------------------------------------------------------------------------

local function cmd_rm(kobo_root)
  local author, bname, err = parse_args(arg, true, "basename")
  if err then die(err) end

  if is_system_dir(author) then
    die("Refusing to operate in system directory: " .. author)
  end

  local author_dir  = path_join(kobo_root, author)
  local target_path = path_join(author_dir, bname)

  if not file_exists(target_path) then
    die("File not found on Kobo: " .. author .. "/" .. bname)
  end

  local ok, rerr = os.remove(target_path)
  if not ok then
    die("Failed to remove file: " .. (rerr or target_path))
  end

  print("Removed: " .. author .. "/" .. bname)

  -- Auto-clean empty author dir
  if is_dir(author_dir) then
    local remaining = list_entries(author_dir)
    if #remaining == 0 then
      if rmdir_safe(author_dir) then
        print("Removed empty author directory: " .. author)
      end
    end
  end
end

-- ---------------------------------------------------------------------------
-- Usage
-- ---------------------------------------------------------------------------

local function usage()
  io.stderr:write(table.concat({
    "Usage:",
    "  lua kobo.lua add --author \"Last, First\" <path-to-book-or-dir>",
    "  lua kobo.lua list",
    "  lua kobo.lua rm  --author \"Last, First\" <basename>",
    "",
    "Examples:",
    "  lua kobo.lua add --author \"Adams, Douglas\" \"C:/downloads/Hitchhiker.kepub.epub\"",
    "  lua kobo.lua add --author \"Adams, Douglas\" \"C:/downloads/adams/\"",
    "  lua kobo.lua list",
    "  lua kobo.lua rm  --author \"Adams, Douglas\" \"Hitchhiker.kepub.epub\"",
    "",
  }, "\n"))
  os.exit(1)
end

-- ---------------------------------------------------------------------------
-- Main dispatch
-- ---------------------------------------------------------------------------

local cmd = arg[1]

if not cmd or cmd == "--help" or cmd == "-h" then
  usage()
end

local kobo_root = load_config()

if cmd == "add" then
  cmd_add(kobo_root)
elseif cmd == "list" then
  cmd_list(kobo_root)
elseif cmd == "rm" then
  cmd_rm(kobo_root)
else
  io.stderr:write("Unknown command: " .. cmd .. "\n\n")
  usage()
end
