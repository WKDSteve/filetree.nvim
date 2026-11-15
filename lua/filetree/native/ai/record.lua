---@module 'filetree.native.ai.record'
---@brief Record a spoken request from the microphone into a WAV file: ffmpeg or sox, until silence or stop.
---@description
--- One recording at a time. It ends by itself after `silence` seconds without speech (or after
--- `max_seconds`), or when `stop()` is called (the second click on the microphone). The file is 16 kHz
--- mono, what the whisper engines of media.nvim read.
---
--- Key responsibilities:
--- - `tool(opts)`: which recorder is there (`ffmpeg`, `sox`), or why none
--- - `argv(tool, out, opts)`: the command line, pure (specs read it)
--- - `start(opts, on_done)`: record; `on_done(path)` once, or `on_done(nil, err)`
---
--- sox stops on silence by itself (its `silence` effect). ffmpeg reports silence on stderr
--- (`silencedetect`) and is told to stop with `q` on stdin, which also ends a stop by click cleanly.

local M = {}

---@class Filetree.Ai.RecordOpts
---@field tool? "auto"|"ffmpeg"|"sox"  Default "auto": ffmpeg, else sox.
---@field device? string  The input device. ffmpeg on Windows needs it (`ffmpeg -list_devices true -f dshow -i dummy` lists them).
---@field silence? number  Seconds of silence that end the recording (default 2).
---@field max_seconds? integer  The longest recording (default 30).

---@class Filetree.Ai.Recording
---@field stop fun()  End the recording now; `on_done` still gets the file.
---@field tool string

---@return string
local function os_name()
  if vim.fn.has("win32") == 1 then return "windows" end
  if vim.fn.has("mac") == 1 then return "mac" end
  return "linux"
end

---Which recorder this machine has.
---@param opts? Filetree.Ai.RecordOpts
---@return string|nil tool
---@return string|nil reason  Why there is none.
function M.tool(opts)
  local want = (opts or {}).tool or "auto"
  local order = want == "auto" and { "ffmpeg", "sox" } or { want }
  for _, tool in ipairs(order) do
    if (tool == "ffmpeg" or tool == "sox") and vim.fn.executable(tool) == 1 then
      if tool == "ffmpeg" and os_name() == "windows" and not (opts or {}).device then
        -- dshow has no default device: without a name ffmpeg cannot record here, sox can
        if want ~= "auto" then
          return nil, "ffmpeg on Windows needs native.ai.record.device (an audio device name)"
        end
      else
        return tool, nil
      end
    end
  end
  if want ~= "auto" and want ~= "ffmpeg" and want ~= "sox" then
    return nil, ("unknown recorder %q (ffmpeg or sox)"):format(tostring(want))
  end
  return nil, "no recorder: install ffmpeg or sox"
end

---The command line of a recording.
---@param tool "ffmpeg"|"sox"
---@param out string  The WAV file to write.
---@param opts? Filetree.Ai.RecordOpts
---@param system? "windows"|"mac"|"linux"  Default: this machine.
---@return string[]
function M.argv(tool, out, opts, system)
  opts = opts or {}
  system = system or os_name()
  local silence = tostring(tonumber(opts.silence) or 2)
  local max = tostring(math.floor(tonumber(opts.max_seconds) or 30))
  if tool == "sox" then
    local input = { "-d" }
    if opts.device then
      input = { "-t", system == "windows" and "waveaudio" or "alsa", opts.device }
    end
    local argv = { "sox", "-q" }
    vim.list_extend(argv, input)
    -- 16 kHz mono; start at the first sound, stop after `silence` seconds below 1 %; at most `max`
    vim.list_extend(argv, { "-c", "1", "-r", "16000", out })
    vim.list_extend(argv, { "silence", "1", "0.1", "1%", "1", silence, "1%", "trim", "0", max })
    return argv
  end
  local input
  if system == "windows" then
    input = { "-f", "dshow", "-i", "audio=" .. (opts.device or "") }
  elseif system == "mac" then
    input = { "-f", "avfoundation", "-i", ":" .. (opts.device or "0") }
  else
    input = { "-f", "pulse", "-i", opts.device or "default" }
  end
  local argv = { "ffmpeg", "-hide_banner", "-nostats", "-loglevel", "info" }
  vim.list_extend(argv, input)
  vim.list_extend(argv, {
    "-ac",
    "1",
    "-ar",
    "16000",
    "-t",
    max,
    "-af",
    "silencedetect=noise=-35dB:d=" .. silence,
    "-y",
    out,
  })
  return argv
end

---Whether a line of ffmpeg's stderr says the person has stopped speaking: silence that begins after
---some sound, or the end of a first silence followed by another one.
---@param line string
---@param state { spoke?: boolean }
---@return boolean stop
function M.silence_says_stop(line, state)
  if line:find("silence_end", 1, true) then
    state.spoke = true
    return false
  end
  local at = tonumber(line:match("silence_start:%s*([%d%.]+)"))
  if at == nil then return false end
  -- silence from the very start is the pause before speaking, not its end
  if state.spoke or at > 0.5 then return true end
  return false
end

---Record until silence or `stop()`.
---@param opts? Filetree.Ai.RecordOpts
---@param on_done fun(path: string|nil, err: string|nil)  Once, on the main loop.
---@return Filetree.Ai.Recording|nil recording
---@return string|nil err
function M.start(opts, on_done)
  opts = opts or {}
  local tool, why = M.tool(opts)
  if not tool then return nil, why end
  local out = vim.fn.tempname() .. ".wav"
  local argv = M.argv(tool, out, opts)
  local finished, stopping = false, false
  local proc = nil
  local state = {}
  local function stop()
    if stopping or not proc then return end
    stopping = true
    if tool == "ffmpeg" then
      pcall(proc.write, proc, "q")
    else
      pcall(proc.kill, proc, "sigint")
    end
  end
  local ok, started = pcall(vim.system, argv, {
    stdin = tool == "ffmpeg",
    text = true,
    stderr = tool == "ffmpeg" and function(_, data)
      if not data then return end
      for line in data:gmatch("[^\r\n]+") do
        if M.silence_says_stop(line, state) then
          vim.schedule(stop)
          return
        end
      end
    end or nil,
  }, function(result)
    vim.schedule(function()
      if finished then return end
      finished = true
      local stat = vim.uv.fs_stat(out)
      -- a WAV header alone is 44 bytes: nothing was recorded
      if stat and stat.size > 44 then
        on_done(out, nil)
      else
        pcall(vim.fn.delete, out)
        on_done(nil, ("%s recorded nothing (exit %s)"):format(tool, tostring(result.code)))
      end
    end)
  end)
  if not ok then return nil, ("%s did not start: %s"):format(tool, tostring(started)) end
  proc = started
  return { stop = stop, tool = tool }, nil
end

return M
