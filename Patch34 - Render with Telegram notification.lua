-- Patch34
-- Render Telegram Notifier
-- Opens REAPER's Render dialog and sends a Telegram notification when the render finishes.
--
-- https://github.com/patch-34
--
-- @description Patch34: Render with Telegram notification
-- @version 0.2.5
-- @author Aleksei Vorobev / Patch34
-- @about
--   v0.2.5 keeps the accepted Variant B backend workflow as the default and
--   adds a watcher guard so switching REAPER project tabs after opening the
--   Render dialog, but before actual render activity is observed, cannot produce
--   a false render-finished Telegram notification. Variant A direct Telegram
--   delivery remains available as an advanced fallback.

local SCRIPT_VERSION = "0.2.5"

------------------------------------------------------------
-- User settings
------------------------------------------------------------

local SETTINGS = {
  -- v0.2.5 action mode:
  --   "render_dialog_with_notification"  Normal user workflow for the REAPER action:
  --                                      Patch34: Render with Telegram notification.
  --                                      Opens REAPER's normal Render dialog, lets the user render manually,
  --                                      then sends a Telegram notification when the render finishes.
  --   "manual_test"                      Internal/manual test mode; does not render.
  --   "render_with_notification"         Legacy/fast mode: render with REAPER's most recent render settings
  --                                      via action 42230, then send a render-finished notification.
  run_mode = "render_dialog_with_notification",

  -- v0.2.5 delivery mode:
  --   "telegram_direct"          Variant A: send directly to Telegram Bot API using user-owned credentials.
  --   "patch34_backend"          Variant B: send through the shared Patch34 backend using a device token.
  delivery_mode = "patch34_backend",

  -- Variant B backend URL. Public endpoint, not a secret.
  -- Public smoke-test endpoint. This is not a secret.
  backend_endpoint = "https://patch34-render-telegram-bot.patch34.workers.dev",

  -- Variant A direct Telegram credentials.
  -- Insert your own Telegram bot token and chat_id here only when using telegram_direct mode.
  -- Do not share scripts containing real credentials.
  telegram_bot_token = "",
  telegram_chat_id = "",

  -- Default is macOS-safe. On other systems, change this to "curl" or a full executable path if needed.
  curl_executable = "/usr/bin/curl",
  curl_timeout_sec = 20,

  -- Native REAPER action:
  -- File: Render project, using the most recent render settings, auto-close render dialog
  -- This remains available for the older render_with_notification mode.
  render_action_command_id = 42230,

  -- Native REAPER action:
  -- File: Render project to disk...
  -- This opens the normal Render dialog. It is non-blocking, so this mode uses a defer watcher.
  render_dialog_action_command_id = 40015,

  -- Render-dialog watcher settings.
  -- This is a practical file-activity watcher, not a native render-finished API.
  watcher_poll_interval_sec = 1.0,
  watcher_pre_activity_poll_interval_sec = 0.15,
  watcher_post_activity_poll_interval_sec = 1.0,
  watcher_fast_watch_until_activity_sec = 120,
  watcher_stable_size_threshold_sec = 3.0,
  watcher_max_watch_sec = 300,
  verbose_watcher_log = false,

  -- Console behavior.
  -- Disabled by default for normal daily use. Set to true for debugging.
  enable_console_log = false,
  clear_console_on_start = false,
}

------------------------------------------------------------
-- Basic utilities
------------------------------------------------------------

local function log(message)
  if not SETTINGS.enable_console_log then
    return
  end

  reaper.ShowConsoleMsg("[Patch34 Render Telegram Notifier v" .. SCRIPT_VERSION .. "] " .. tostring(message) .. "\n")
end

local function is_windows()
  local os_name = reaper.GetOS()
  return os_name:find("Win", 1, true) ~= nil
end

local function is_macos()
  local os_name = reaper.GetOS()
  return os_name:find("OSX", 1, true) ~= nil or os_name:find("macOS", 1, true) ~= nil
end

local function is_linux()
  local os_name = reaper.GetOS()
  return os_name:find("Linux", 1, true) ~= nil
end

local function quote_arg(value)
  local text = tostring(value or "")

  if is_windows() then
    text = text:gsub('"', '\\"')
    return '"' .. text .. '"'
  end

  text = text
    :gsub("\\", "\\\\")
    :gsub('"', '\\"')
    :gsub("%$", "\\$")
    :gsub("`", "\\`")

  return '"' .. text .. '"'
end

local function write_temp_file(contents)
  local path = os.tmpname()

  if not path or path == "" then
    return nil, "os.tmpname() did not return a usable path"
  end

  local file, open_err = io.open(path, "wb")
  if not file then
    return nil, "Could not open temp file: " .. tostring(open_err)
  end

  file:write(tostring(contents or ""))
  file:close()

  return path, nil
end

local function remove_temp_file(path)
  if path and path ~= "" then
    os.remove(path)
  end
end

local EXTSTATE_SECTION = "Patch34_Render_Telegram_Notifier"
local EXTSTATE_BACKEND_ENDPOINT_KEY = "backend_endpoint"
local EXTSTATE_BACKEND_DEVICE_TOKEN_KEY = "backend_device_token"

local function get_extstate_value(key)
  local value = reaper.GetExtState(EXTSTATE_SECTION, key)
  return tostring(value or "")
end

local function set_extstate_value(key, value)
  reaper.SetExtState(EXTSTATE_SECTION, key, tostring(value or ""), true)
end

local function show_message(title, message)
  reaper.MB(tostring(message or ""), tostring(title or "Patch34 Render Telegram Notifier"), 0)
end

local function trim(value)
  return tostring(value or ""):match("^%s*(.-)%s*$")
end

local function is_blank(value)
  return trim(value) == ""
end

local function truncate(value, max_len)
  local text = tostring(value or "")
  max_len = max_len or 500

  if #text <= max_len then
    return text
  end

  return text:sub(1, max_len - 3) .. "..."
end

local function format_timestamp(epoch)
  if not epoch then
    return "(not available)"
  end

  return os.date("%Y-%m-%d %H:%M:%S", epoch)
end

local function format_duration(seconds)
  if type(seconds) ~= "number" then
    return "(not available)"
  end

  return string.format("%.1f sec", seconds)
end

local function get_project_path()
  local _, project_path = reaper.EnumProjects(-1, "")
  project_path = tostring(project_path or "")

  if project_path == "" then
    return "(unsaved project)"
  end

  return project_path
end

local function get_project_name()
  local project_path = get_project_path()

  if project_path == "(unsaved project)" then
    return "(unsaved project)"
  end

  local name = project_path:match("([^/\\]+)$")
  return name or project_path
end

local function get_render_targets()
  local ok, targets = reaper.GetSetProjectInfo_String(0, "RENDER_TARGETS", "", false)

  if not ok then
    return nil
  end

  targets = trim(targets)

  if targets == "" then
    return nil
  end

  return targets
end

local function split_render_targets(targets)
  local result = {}
  targets = trim(targets)

  if targets == "" then
    return result
  end

  for target in targets:gmatch("([^;]+)") do
    target = trim(target)
    if target ~= "" then
      table.insert(result, target)
    end
  end

  return result
end

local function get_first_render_target(targets)
  local list = split_render_targets(targets)
  return list[1], #list
end

local function get_file_size(path)
  if is_blank(path) then
    return nil
  end

  local file = io.open(path, "rb")
  if not file then
    return nil
  end

  local size = file:seek("end")
  file:close()

  return size
end

local function extract_last_timestamp_number(exec_output)
  local text = trim(exec_output)
  local result = nil

  for number_text in text:gmatch("%-?%d+") do
    local number_value = tonumber(number_text)

    -- Ignore process return codes such as 0/1 and keep only plausible Unix
    -- timestamp-sized values. This also avoids accidentally treating a failed
    -- stat process return code as a valid mtime.
    if number_value and number_value >= 100000000 then
      result = number_value
    end
  end

  return result
end

local function get_file_mtime(path)
  if is_blank(path) then
    return nil
  end

  if is_windows() then
    if SETTINGS.verbose_watcher_log then
      log("Target file mtime unavailable: Windows fallback path")
    end
    return nil
  end

  local command
  if is_macos() then
    command = table.concat({
      "stat",
      "-f",
      "%m",
      quote_arg(path),
    }, " ")
  elseif is_linux() then
    command = table.concat({
      "stat",
      "-c",
      "%Y",
      quote_arg(path),
    }, " ")
  else
    if SETTINGS.verbose_watcher_log then
      log("Target file mtime unavailable: unsupported OS")
    end
    return nil
  end

  local output = reaper.ExecProcess(command, 1000)

  if SETTINGS.verbose_watcher_log then
    log("Raw mtime command output: " .. truncate(output, 500))
  end

  local mtime = extract_last_timestamp_number(output)

  if SETTINGS.verbose_watcher_log then
    log("Parsed mtime value: " .. tostring(mtime or "(not available)"))
  end

  return mtime
end

local function get_file_fingerprint(path)
  local size = get_file_size(path)
  local mtime = get_file_mtime(path)

  return {
    file_exists = size ~= nil,
    size = size,
    mtime = mtime,
  }
end

local function file_fingerprint_changed(previous_fingerprint, current_fingerprint)
  if not previous_fingerprint or not current_fingerprint then
    return false
  end

  if not current_fingerprint.file_exists then
    return false
  end

  local size_changed = previous_fingerprint.size ~= nil
    and current_fingerprint.size ~= nil
    and current_fingerprint.size ~= previous_fingerprint.size

  local mtime_changed = previous_fingerprint.mtime ~= nil
    and current_fingerprint.mtime ~= nil
    and current_fingerprint.mtime ~= previous_fingerprint.mtime

  return size_changed or mtime_changed
end

local function describe_file_fingerprint(fingerprint)
  if not fingerprint then
    return "(not available)"
  end

  return "exists=" .. (fingerprint.file_exists and "yes" or "no")
    .. ", size=" .. tostring(fingerprint.size or "(not available)")
    .. ", mtime=" .. tostring(fingerprint.mtime or "(not available)")
end

------------------------------------------------------------
-- Notification payload builder
-- This layer is intentionally independent from Telegram.
------------------------------------------------------------

local function build_notification_payload(args)
  args = args or {}

  return {
    event_type = args.event_type or "unknown",
    render_status = args.render_status or "unknown",
    project_name = args.project_name or get_project_name(),
    project_path = args.project_path or get_project_path(),
    render_path = args.render_path or get_render_targets(),
    started_at = args.started_at,
    finished_at = args.finished_at,
    duration_sec = args.duration_sec,
    script_version = SCRIPT_VERSION,
  }
end

------------------------------------------------------------
-- Message formatter
-- This layer converts a payload into human-readable text only.
-- It does not send the message.
------------------------------------------------------------

local function extract_basename_from_path(path)
  local text = trim(path)

  if text == "" then
    return nil
  end

  local basename = text:match("([^/\\]+)$")
  basename = trim(basename)

  if basename == "" then
    return nil
  end

  return basename
end

local function extract_first_render_target_path(render_path)
  local first_target = get_first_render_target(render_path)
  first_target = trim(first_target)

  if first_target == "" then
    return nil
  end

  return first_target
end

local function escape_telegram_html(text)
  text = tostring(text or "")
  text = text:gsub("&", "&amp;")
  text = text:gsub("<", "&lt;")
  text = text:gsub(">", "&gt;")
  return text
end

local function format_notification_message(payload)
  payload = payload or {}

  if payload.event_type == "manual_test" then
    return "Telegram test ✅"
  end

  if payload.event_type == "render_finished" then
    local first_target = extract_first_render_target_path(payload.render_path)
    local filename = extract_basename_from_path(first_target) or "render"
    return "<b>" .. escape_telegram_html(filename) .. "</b> finished ✅"
  end

  return "Telegram notification ✅"
end

local function get_payload_filename(payload)
  payload = payload or {}

  if payload.event_type == "manual_test" then
    return "Telegram test"
  end

  local first_target = extract_first_render_target_path(payload.render_path)
  return extract_basename_from_path(first_target) or "render"
end

------------------------------------------------------------
-- Backend persistence and HTTP helpers
------------------------------------------------------------

local function normalize_backend_endpoint(endpoint)
  local text = trim(endpoint)

  if text == "" then
    return ""
  end

  text = text:gsub("/+$", "")

  return text
end

local function get_saved_backend_endpoint()
  return normalize_backend_endpoint(get_extstate_value(EXTSTATE_BACKEND_ENDPOINT_KEY))
end

local function get_saved_backend_device_token()
  return trim(get_extstate_value(EXTSTATE_BACKEND_DEVICE_TOKEN_KEY))
end

local function get_configured_backend_endpoint()
  local endpoint = normalize_backend_endpoint(SETTINGS.backend_endpoint)

  if endpoint ~= "" then
    set_extstate_value(EXTSTATE_BACKEND_ENDPOINT_KEY, endpoint)
    return endpoint
  end

  return get_saved_backend_endpoint()
end

local function prompt_for_backend_endpoint()
  local ok, values = reaper.GetUserInputs(
    "Patch34 backend setup",
    1,
    "Backend endpoint URL:",
    get_saved_backend_endpoint()
  )

  if not ok then
    return nil, "Backend setup cancelled"
  end

  local endpoint = normalize_backend_endpoint(values)

  if endpoint == "" then
    return nil, "Backend endpoint is empty"
  end

  if not endpoint:match("^https?://") then
    return nil, "Backend endpoint must start with http:// or https://"
  end

  set_extstate_value(EXTSTATE_BACKEND_ENDPOINT_KEY, endpoint)

  return endpoint, nil
end

local function prompt_for_pairing_code()
  local ok, values = reaper.GetUserInputs(
    "Patch34 Telegram setup",
    1,
    "Pairing code from Telegram bot:",
    ""
  )

  if not ok then
    return nil, "Backend pairing cancelled"
  end

  local code = trim(values):upper():gsub("%s+", "")

  if code == "" then
    return nil, "Pairing code is empty"
  end

  return code, nil
end

local function json_escape(value)
  local text = tostring(value or "")

  text = text:gsub("\\", "\\\\")
  text = text:gsub('"', '\\"')
  text = text:gsub("\b", "\\b")
  text = text:gsub("\f", "\\f")
  text = text:gsub("\n", "\\n")
  text = text:gsub("\r", "\\r")
  text = text:gsub("\t", "\\t")
  text = text:gsub("[%z\1-\31]", function(char)
    return string.format("\\u%04x", char:byte())
  end)

  return text
end

local function build_json_object(fields)
  local parts = {}

  for _, pair in ipairs(fields or {}) do
    local key = pair[1]
    local value = pair[2]
    table.insert(parts, '"' .. json_escape(key) .. '":"' .. json_escape(value) .. '"')
  end

  return "{" .. table.concat(parts, ",") .. "}"
end

local function post_json(endpoint, path, body)
  endpoint = normalize_backend_endpoint(endpoint)
  path = tostring(path or "")

  if endpoint == "" then
    return false, "Backend endpoint is empty"
  end

  local body_file, body_file_err = write_temp_file(body)
  if not body_file then
    return false, body_file_err
  end

  local url = endpoint .. path
  local command = table.concat({
    quote_arg(SETTINGS.curl_executable),
    "-sS",
    "--max-time", tostring(SETTINGS.curl_timeout_sec),
    "--request", "POST",
    quote_arg(url),
    "--header", quote_arg("content-type: application/json"),
    "--data-binary", quote_arg("@" .. body_file),
  }, " ")

  local timeout_sec = math.max(1, tonumber(SETTINGS.curl_timeout_sec) or 20)
  local timeout_ms = timeout_sec * 1000
  local output = reaper.ExecProcess(command, timeout_ms)

  remove_temp_file(body_file)

  output = tostring(output or "")

  if output == "" then
    return false, "Backend returned no response"
  end

  return true, output
end

local function response_has_ok_true(response)
  return tostring(response or ""):find('"ok"%s*:%s*true') ~= nil
end

local function extract_json_string(response, key)
  response = tostring(response or "")
  key = tostring(key or "")

  local pattern = '"' .. key:gsub("([^%w_])", "%%%1") .. '"%s*:%s*"([^"]*)"'
  local value = response:match(pattern)

  if not value then
    return nil
  end

  value = value
    :gsub("\\/", "/")
    :gsub('\\"', '"')
    :gsub("\\\\", "\\")

  return value
end

local function pair_with_backend(endpoint, pairing_code)
  local body = build_json_object({
    { "pairing_code", pairing_code },
    { "device_name", "REAPER" },
  })

  local ok, response_or_error = post_json(endpoint, "/pair", body)
  if not ok then
    return false, response_or_error
  end

  local response = response_or_error

  if not response_has_ok_true(response) then
    return false, "Backend pairing failed: " .. truncate(response, 1000)
  end

  local device_token = extract_json_string(response, "device_token")
  device_token = trim(device_token)

  if device_token == "" then
    return false, "Backend pairing response did not include device_token"
  end

  set_extstate_value(EXTSTATE_BACKEND_DEVICE_TOKEN_KEY, device_token)

  return true, device_token
end

local function ensure_patch34_backend_ready()
  local endpoint = get_configured_backend_endpoint()

  if endpoint == "" then
    local endpoint_value, endpoint_err = prompt_for_backend_endpoint()

    if not endpoint_value then
      return false, endpoint_err
    end

    endpoint = endpoint_value
  end

  local device_token = get_saved_backend_device_token()

  if device_token ~= "" then
    return true, "Backend device token is available"
  end

  local pairing_code, code_err = prompt_for_pairing_code()

  if not pairing_code then
    return false, code_err
  end

  return pair_with_backend(endpoint, pairing_code)
end

------------------------------------------------------------
-- Delivery provider layer
------------------------------------------------------------

local function validate_telegram_settings()
  local token = trim(SETTINGS.telegram_bot_token)
  local chat_id = trim(SETTINGS.telegram_chat_id)

  if token == "" then
    return false, "SETTINGS.telegram_bot_token is empty"
  end

  if chat_id == "" then
    return false, "SETTINGS.telegram_chat_id is empty"
  end

  if token:find("[%s\"'<>]") then
    return false, "SETTINGS.telegram_bot_token contains invalid characters"
  end

  if chat_id:find("[%c\"'<>]") then
    return false, "SETTINGS.telegram_chat_id contains invalid characters"
  end

  return true, nil
end

local function send_telegram_direct(payload)
  local ok, validation_error = validate_telegram_settings()
  if not ok then
    return false, validation_error
  end

  local message = format_notification_message(payload)
  local chat_file, chat_file_err = write_temp_file(trim(SETTINGS.telegram_chat_id))
  if not chat_file then
    return false, chat_file_err
  end

  local text_file, text_file_err = write_temp_file(message)
  if not text_file then
    remove_temp_file(chat_file)
    return false, text_file_err
  end

  local token = trim(SETTINGS.telegram_bot_token)
  local url = "https://api.telegram.org/bot" .. token .. "/sendMessage"

  local command = table.concat({
    quote_arg(SETTINGS.curl_executable),
    "-sS",
    "--max-time", tostring(SETTINGS.curl_timeout_sec),
    "--request", "POST",
    quote_arg(url),
    "--data-urlencode", quote_arg("chat_id@" .. chat_file),
    "--data-urlencode", quote_arg("text@" .. text_file),
    "--data-urlencode", quote_arg("parse_mode=HTML"),
    "--data-urlencode", quote_arg("disable_web_page_preview=true"),
  }, " ")

  local timeout_sec = math.max(1, tonumber(SETTINGS.curl_timeout_sec) or 20)
  local timeout_ms = timeout_sec * 1000
  local output = reaper.ExecProcess(command, timeout_ms)

  remove_temp_file(chat_file)
  remove_temp_file(text_file)

  output = tostring(output or "")

  if output:find('"ok"%s*:%s*true') then
    return true, "Telegram API returned ok=true"
  end

  if output == "" then
    return false, "curl/Telegram returned no response"
  end

  return false, "Telegram response did not contain ok=true: " .. truncate(output, 1000)
end

local function send_patch34_backend(payload)
  local ready, ready_result = ensure_patch34_backend_ready()

  if not ready then
    return false, ready_result
  end

  local endpoint = get_configured_backend_endpoint()
  local device_token = get_saved_backend_device_token()

  if endpoint == "" then
    return false, "Backend endpoint is empty"
  end

  if device_token == "" then
    return false, "Backend device token is empty"
  end

  local filename = get_payload_filename(payload)
  local body = build_json_object({
    { "device_token", device_token },
    { "filename", filename },
  })

  local ok, response_or_error = post_json(endpoint, "/notify", body)
  if not ok then
    return false, response_or_error
  end

  local response = response_or_error

  if response_has_ok_true(response) then
    return true, "Backend returned ok=true"
  end

  return false, "Backend notify response did not contain ok=true: " .. truncate(response, 1000)
end

local function ensure_delivery_ready()
  if SETTINGS.delivery_mode == "patch34_backend" then
    local ok, result = ensure_patch34_backend_ready()

    if not ok then
      local message = tostring(result or "")

      if message:find("pair", 1, true) or message:find("Pair", 1, true) then
        message = message .. "\n\nThe pairing code may be invalid, expired, or already used. Request a new code from the Patch34 Telegram bot with /start and run the script again."
      end

      show_message("Patch34 Telegram setup failed", message)
    end

    return ok, result
  end

  return true, "Delivery provider is ready"
end

local function send_notification(payload)
  local mode = SETTINGS.delivery_mode

  log("Notification send requested. delivery_mode=" .. tostring(mode) .. ", event_type=" .. tostring(payload and payload.event_type or "unknown"))

  if mode == "telegram_direct" then
    return send_telegram_direct(payload)
  end

  if mode == "patch34_backend" then
    return send_patch34_backend(payload)
  end

  return false, "Unsupported delivery_mode: " .. tostring(mode)
end

local function show_render_notification_failure(result)
  show_message(
    "Patch34 Render Telegram Notifier",
    "Render finished, but the Telegram notification could not be sent.\n\n" .. tostring(result or "Unknown error")
  )
end

------------------------------------------------------------
-- Render/event layer
-- This layer does not construct Telegram URLs and does not know
-- Telegram API details.
------------------------------------------------------------

local function run_manual_test_notification()
  local now = os.time()

  local payload = build_notification_payload({
    event_type = "manual_test",
    render_status = "test",
    started_at = now,
    finished_at = now,
    duration_sec = 0,
  })

  log("Manual test notification path selected.")
  local ok, result = send_notification(payload)

  if ok then
    log("Notification succeeded: " .. tostring(result))
  else
    log("Notification failed: " .. tostring(result))
    if SETTINGS.delivery_mode == "patch34_backend" then
      show_message("Patch34 backend notification failed", result)
    end
  end
end

local function run_render_dialog_with_notification()
  local delivery_ready, delivery_ready_result = ensure_delivery_ready()
  if not delivery_ready then
    log("Render dialog aborted before opening because delivery provider is not ready: " .. tostring(delivery_ready_result))
    return
  end

  local opened_project = reaper.EnumProjects(-1)
  local opened_epoch = os.time()
  local opened_precise = reaper.time_precise()
  local initial_targets = get_render_targets()
  local initial_first_target, initial_target_count = get_first_render_target(initial_targets)
  local initial_fingerprint = get_file_fingerprint(initial_first_target)
  local initial_size = initial_fingerprint.size
  local initial_mtime = initial_fingerprint.mtime

  local state = {
    opened_project = opened_project,
    opened_epoch = opened_epoch,
    opened_precise = opened_precise,
    initial_targets = initial_targets,
    initial_first_target = initial_first_target,
    initial_target_count = initial_target_count,
    current_targets = initial_targets,
    current_first_target = initial_first_target,
    current_target_count = initial_target_count,
    initial_size = initial_size,
    initial_mtime = initial_mtime,
    initial_fingerprint = initial_fingerprint,
    last_fingerprint = initial_fingerprint,
    last_size = initial_size,
    last_mtime = initial_mtime,
    last_size_change_precise = opened_precise,
    last_poll_precise = 0,
    activity_seen = false,
    render_started_seen = false,
    project_changed_before_render_logged = false,
    activity_start_epoch = nil,
    activity_start_precise = nil,
    notification_sent = false,
    timed_out = false,
    stopped = false,
  }

  log("Render-dialog-with-notification path selected.")
  log("Opening normal REAPER Render dialog command_id=" .. tostring(SETTINGS.render_dialog_action_command_id))

  if initial_targets then
    log("Initial render target(s): " .. initial_targets)
  else
    log("Initial render target(s): not available from RENDER_TARGETS")
  end

  if initial_mtime then
    log("Initial first target mtime: " .. tostring(initial_mtime))
  elseif initial_first_target then
    log("Initial first target mtime: unavailable")
  end

  if SETTINGS.verbose_watcher_log then
    log("Initial first target fingerprint: " .. describe_file_fingerprint(initial_fingerprint))
  end

  reaper.Main_OnCommand(SETTINGS.render_dialog_action_command_id, 0)

  log("Render dialog action returned immediately/non-blocking. Starting defer watcher.")

  local function mark_activity(now_epoch, now_precise, reason)
    state.render_started_seen = true

    if not state.activity_seen then
      state.activity_seen = true
      state.activity_start_epoch = now_epoch
      state.activity_start_precise = now_precise
      log("Render activity signal detected: " .. tostring(reason))
    end
  end

  local function finish_with_notification(now_epoch, now_precise, stable_for_sec)
    if not state.render_started_seen then
      log("Completion candidate ignored because no real render activity was observed.")
      return
    end

    state.notification_sent = true

    local finished_epoch = now_epoch
    local started_epoch = state.activity_start_epoch or state.opened_epoch
    local started_precise = state.activity_start_precise or state.opened_precise
    local duration_sec = now_precise - started_precise

    log("Completion candidate reached: file size stable for " .. string.format("%.3f", stable_for_sec) .. " sec after activity signal.")
    log("Sending render-finished notification and stopping watcher.")

    local payload = build_notification_payload({
      event_type = "render_finished",
      render_status = "finished",
      render_path = state.current_targets or state.initial_targets,
      started_at = started_epoch,
      finished_at = finished_epoch,
      duration_sec = duration_sec,
    })

    local ok, result = send_notification(payload)

    if ok then
      log("Notification succeeded: " .. tostring(result))
    else
      log("Notification failed: " .. tostring(result))
      show_render_notification_failure(result)
    end

    state.stopped = true
    log("Render-dialog watcher stopped after notification attempt.")
  end

  local function watcher_loop()
    if state.stopped or state.notification_sent or state.timed_out then
      return
    end

    local now_precise = reaper.time_precise()
    local now_epoch = os.time()
    local elapsed_sec = now_precise - state.opened_precise

    if elapsed_sec >= SETTINGS.watcher_max_watch_sec then
      state.timed_out = true
      state.stopped = true
      log("Render-dialog watcher timed out after " .. string.format("%.3f", elapsed_sec) .. " sec. No notification was sent.")
      log("Render-dialog watcher stopped after timeout.")
      show_message("Patch34 Render Telegram Notifier", "Render notification timed out. No Telegram message was sent.")
      return
    end

    local poll_interval
    if state.activity_seen then
      poll_interval = tonumber(SETTINGS.watcher_post_activity_poll_interval_sec)
        or tonumber(SETTINGS.watcher_poll_interval_sec)
        or 1.0
    elseif elapsed_sec <= (tonumber(SETTINGS.watcher_fast_watch_until_activity_sec) or 120) then
      poll_interval = tonumber(SETTINGS.watcher_pre_activity_poll_interval_sec)
        or tonumber(SETTINGS.watcher_poll_interval_sec)
        or 0.15
    else
      poll_interval = tonumber(SETTINGS.watcher_post_activity_poll_interval_sec)
        or tonumber(SETTINGS.watcher_poll_interval_sec)
        or 1.0
    end

    poll_interval = math.max(0.05, poll_interval)

    if SETTINGS.verbose_watcher_log then
      log("watch polling interval selected: " .. string.format("%.3f", poll_interval) .. " sec")
    end

    if state.last_poll_precise == 0 or (now_precise - state.last_poll_precise) >= poll_interval then
      state.last_poll_precise = now_precise

      -- Guard against false positives caused by switching REAPER project tabs
      -- after opening the Render dialog but before any real render activity has
      -- been observed. While another project tab is active, RENDER_TARGETS may
      -- describe a different project and must not be treated as render activity.
      local active_project = reaper.EnumProjects(-1)
      if not state.render_started_seen and active_project ~= state.opened_project then
        if not state.project_changed_before_render_logged then
          log("Active REAPER project changed before render activity was observed. Watcher polling is ignored until the original project tab is active again; no notification will be sent for this state change.")
          state.project_changed_before_render_logged = true
        end
        reaper.defer(watcher_loop)
        return
      elseif state.project_changed_before_render_logged and active_project == state.opened_project then
        log("Original REAPER project tab is active again before render activity. Watcher polling resumed.")
        state.project_changed_before_render_logged = false
      end

      local current_targets = get_render_targets()
      local first_target, target_count = get_first_render_target(current_targets)
      local targets_changed = current_targets ~= state.current_targets
      local first_target_changed = first_target ~= state.current_first_target
      local current_fingerprint = get_file_fingerprint(first_target)
      local size = current_fingerprint.size
      local current_mtime = current_fingerprint.mtime
      local file_exists = current_fingerprint.file_exists
      local previous_fingerprint = state.last_fingerprint
      local previous_size = state.last_size
      local previous_mtime = state.last_mtime
      local size_changed = size ~= nil and previous_size ~= nil and size ~= previous_size
      local mtime_changed = current_mtime ~= nil and previous_mtime ~= nil and current_mtime ~= previous_mtime
      local fingerprint_changed = file_fingerprint_changed(previous_fingerprint, current_fingerprint)
      local file_appeared = file_exists and (not previous_fingerprint or not previous_fingerprint.file_exists)

      if targets_changed then
        log("RENDER_TARGETS changed: " .. tostring(current_targets or "(not available)"))
        state.current_targets = current_targets
      end

      if first_target_changed then
        log("First render target changed: " .. tostring(first_target or "(not available)"))
        state.current_first_target = first_target
        state.current_target_count = target_count
        state.last_fingerprint = current_fingerprint
        state.last_size = size
        state.last_mtime = current_mtime
        state.last_size_change_precise = now_precise
        previous_fingerprint = current_fingerprint
        previous_size = size
        previous_mtime = current_mtime
        size_changed = false
        mtime_changed = false
        fingerprint_changed = false
        file_appeared = file_exists
      end

      if file_appeared then
        log("Target file appeared or became readable. size_bytes=" .. tostring(size))
        mark_activity(now_epoch, now_precise, "target file appeared")
        state.last_size_change_precise = now_precise
      elseif fingerprint_changed then
        log("Target file fingerprint changed: " .. describe_file_fingerprint(current_fingerprint))
        if size_changed then
          log("Target file size changed. size_bytes=" .. tostring(size))
          mark_activity(now_epoch, now_precise, "target file size changed")
        elseif mtime_changed then
          log("Target file modification time changed. mtime=" .. tostring(current_mtime))
          mark_activity(now_epoch, now_precise, "target file modification time changed")
        else
          mark_activity(now_epoch, now_precise, "target file fingerprint changed")
        end
        state.last_size_change_precise = now_precise
      end

      state.last_fingerprint = current_fingerprint
      state.last_size = size
      state.last_mtime = current_mtime

      local stable_for_sec = now_precise - state.last_size_change_precise
      if SETTINGS.verbose_watcher_log then
        log("watch elapsed_sec=" .. string.format("%.3f", elapsed_sec)
          .. ", target_count=" .. tostring(target_count)
          .. ", first_target=" .. tostring(first_target or "(not available)")
          .. ", file_exists=" .. (file_exists and "yes" or "no")
          .. ", size_bytes=" .. tostring(size or "(not available)")
          .. ", mtime=" .. tostring(current_mtime or "(not available)")
          .. ", fingerprint=" .. describe_file_fingerprint(current_fingerprint)
          .. ", activity_seen=" .. (state.activity_seen and "yes" or "no")
          .. ", render_started_seen=" .. (state.render_started_seen and "yes" or "no")
          .. ", stable_for_sec=" .. string.format("%.3f", stable_for_sec))
      end

      local stable_threshold = math.max(0.5, tonumber(SETTINGS.watcher_stable_size_threshold_sec) or 3.0)
      if state.render_started_seen and state.activity_seen and file_exists and stable_for_sec >= stable_threshold then
        finish_with_notification(now_epoch, now_precise, stable_for_sec)
        return
      end
    end

    reaper.defer(watcher_loop)
  end

  reaper.defer(watcher_loop)
end

local function run_render_with_notification()
  local delivery_ready, delivery_ready_result = ensure_delivery_ready()
  if not delivery_ready then
    log("Render action aborted before starting because delivery provider is not ready: " .. tostring(delivery_ready_result))
    return
  end

  local started_epoch = os.time()
  local started_precise = reaper.time_precise()
  local render_targets_before = get_render_targets()

  log("Render-with-notification path selected.")
  log("Starting REAPER render action command_id=" .. tostring(SETTINGS.render_action_command_id))

  if render_targets_before then
    log("Current render target(s): " .. render_targets_before)
  else
    log("Current render target(s): not available from RENDER_TARGETS")
  end

  reaper.Main_OnCommand(SETTINGS.render_action_command_id, 0)

  local finished_epoch = os.time()
  local duration_sec = reaper.time_precise() - started_precise
  local render_targets_after = get_render_targets()

  log("Render action returned. Building render-finished notification.")

  local payload = build_notification_payload({
    event_type = "render_finished",
    render_status = "finished",
    render_path = render_targets_after or render_targets_before,
    started_at = started_epoch,
    finished_at = finished_epoch,
    duration_sec = duration_sec,
  })

  local ok, result = send_notification(payload)

  if ok then
    log("Notification succeeded: " .. tostring(result))
  else
    log("Notification failed: " .. tostring(result))
    show_render_notification_failure(result)
  end
end

------------------------------------------------------------
-- Entrypoint
------------------------------------------------------------

local function main()
  if SETTINGS.enable_console_log and SETTINGS.clear_console_on_start then
    reaper.ClearConsole()
  end

  log("Started. version=" .. SCRIPT_VERSION
    .. ", run_mode=" .. tostring(SETTINGS.run_mode)
    .. ", delivery_mode=" .. tostring(SETTINGS.delivery_mode)
    .. ", verbose_watcher_log=" .. tostring(SETTINGS.verbose_watcher_log))

  if SETTINGS.run_mode == "manual_test" then
    run_manual_test_notification()
    return
  end

  if SETTINGS.run_mode == "render_with_notification" then
    run_render_with_notification()
    return
  end

  if SETTINGS.run_mode == "render_dialog_with_notification" then
    run_render_dialog_with_notification()
    return
  end

  log("Unsupported run_mode: " .. tostring(SETTINGS.run_mode))
  log('Use SETTINGS.run_mode = "manual_test", "render_with_notification", or "render_dialog_with_notification".')
end

main()
