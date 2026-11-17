-- nbin4
-- Four configurable MIDI-channel-to-n.b.-voice routes for norns.

local mod = require "core/mods"
local hook = require "core/hook"

local PARTS = 4
local CHANNELS = 16

local state = {
  nb = nil,
  devices = {},
  device_names = { "<disabled>" },
  active_device = nil,
  saved_event = nil,
  held = {},       -- held[channel][note] = stack of route batches
  active_counts = {}, -- active_counts[player][note] = number of held inputs
  voice_param_ids = {},
  voice_wrappers = {},
  ready = false,
}

local PROFILE_DIR = _path.data .. "nbin4/profiles/"
local PROFILE_SUFFIX = ".nbin4"
local refresh_pressure_options
local release_all

local function route_channel_id(part)
  return "nbin4_p" .. part .. "_channel"
end

local function route_voice_id(part)
  return "nbin4_p" .. part .. "_voice"
end

local function bend_range_id(part)
  return "nbin4_p" .. part .. "_bend_range"
end

local function pressure_id(part, index)
  return "nbin4_p" .. part .. "_pressure_" .. index
end

local function pressure_sensitivity_id(part)
  return "nbin4_p" .. part .. "_pressure_sensitivity"
end

local function clean_profile_name(name)
  if type(name) ~= "string" then return nil end
  name = name:gsub("%s+", "_"):gsub("[^%w_%-]", "_"):sub(1, 40)
  if name == "" or name == "." or name == ".." then return nil end
  return name
end

local function profile_path(name)
  local clean = clean_profile_name(name)
  if not clean then return nil end
  return PROFILE_DIR .. clean .. PROFILE_SUFFIX
end

local function profile_names()
  util.make_dir(PROFILE_DIR)
  local names = {}
  for _, filename in ipairs(util.scandir(PROFILE_DIR) or {}) do
    local name = filename:match("^(.*)" .. PROFILE_SUFFIX:gsub("%.", "%%.") .. "$")
    if name and name ~= "" then names[#names + 1] = name end
  end
  table.sort(names, function(a, b) return a:lower() < b:lower() end)
  return names
end

local function refresh_profile_options(selected)
  local parameter = params:lookup_param("nbin4_profile")
  if not parameter then return end
  local options = { "<none>" }
  for _, name in ipairs(profile_names()) do options[#options + 1] = name end
  parameter.options = options
  parameter.count = #options
  local selected_index = 1
  for index, name in ipairs(options) do
    if name == selected then selected_index = index break end
  end
  params:set("nbin4_profile", selected_index, true)
end

local function add_voice_param_id(voice_name, id)
  if type(voice_name) ~= "string" or type(id) ~= "string" then return end
  state.voice_param_ids[voice_name] = state.voice_param_ids[voice_name] or {}
  state.voice_param_ids[voice_name][id] = true
end

local function restore_voice_wrappers()
  for _, wrapped in ipairs(state.voice_wrappers) do
    if wrapped.voice then wrapped.voice.add_params = wrapped.original end
  end
  state.voice_wrappers = {}
end

local function track_voice_params()
  restore_voice_wrappers()
  state.voice_param_ids = {}
  if type(note_players) ~= "table" then return end

  for voice_name, voice in pairs(note_players) do
    if type(voice) == "table" and type(voice.add_params) == "function" then
      local tracked_voice_name = voice_name
      local original = voice.add_params
      state.voice_wrappers[#state.voice_wrappers + 1] = { voice = voice, original = original }
      voice.add_params = function(player, ...)
        local first_new_param = params.count + 1
        local result = original(player, ...)
        for index = first_new_param, params.count do
          local parameter = params.params[index]
          local id = parameter and parameter.id
          if id and parameter.save and parameter.t ~= params.tTRIGGER
              and parameter.t ~= params.tSEPARATOR and parameter.t ~= params.tGROUP then
            add_voice_param_id(tracked_voice_name, id)
          end
        end
        return result
      end
    end
  end
end

local function voice_param_ids(voice_name)
  local ids = {}
  for id in pairs(state.voice_param_ids[voice_name] or {}) do ids[id] = true end

  local voice = type(note_players) == "table" and note_players[voice_name] or nil
  if voice and voice.describe then
    local ok, description = pcall(voice.describe, voice)
    if ok and description and type(description.params) == "table" then
      for _, id in ipairs(description.params) do ids[id] = true end
    end
  end
  return ids
end

local function selected_voice_name(part)
  local id = route_voice_id(part)
  local hidden_id = id .. "_hidden_string"
  local hidden = params:lookup_param(hidden_id)
  if hidden then
    local value = hidden:get()
    if type(value) == "string" and value ~= "" then return value end
  end
  local ok, value = pcall(params.string, params, id)
  if ok then return value end
  return "none"
end

local function collect_profile()
  local profile = { format = 1, parts = {}, voice_params = {}, midi_input = { port = 0, name = "" } }
  local input_value = params:get("nbin4_input")
  local port = input_value - 1
  if port > 0 and state.devices[port] then
    profile.midi_input = { port = port, name = state.devices[port].name or "" }
  end

  local selected_voices = {}
  for part = 1, PARTS do
    local voice_name = selected_voice_name(part)
    profile.parts[part] = {
      channel = params:get(route_channel_id(part)),
      voice = voice_name,
      bend_range = params:get(bend_range_id(part)),
      pressure = params:string(pressure_id(part, 1)),
      more_pressure = params:string(pressure_id(part, 2)),
      pressure_sensitivity = params:get(pressure_sensitivity_id(part)),
    }
    if voice_name and voice_name ~= "none" then selected_voices[voice_name] = true end
  end

  for voice_name in pairs(selected_voices) do
    local values = {}
    for id in pairs(voice_param_ids(voice_name)) do
      local ok, parameter = pcall(params.lookup_param, params, id)
      if ok and parameter and parameter.save and parameter.t ~= params.tTRIGGER
          and parameter.t ~= params.tSEPARATOR and parameter.t ~= params.tGROUP then
        local value = { type = parameter.t, value = parameter:get() }
        if parameter.t == params.tOPTION then value.label = parameter:string() end
        values[id] = value
      end
    end
    profile.voice_params[voice_name] = values
  end
  return profile
end

local function set_option_by_name(id, name)
  local parameter = params:lookup_param(id)
  if not parameter then return false end
  for index, option in ipairs(parameter.options or {}) do
    if option == name then
      params:set(id, index)
      return true
    end
  end
  return false
end

local function set_voice(part, voice_name)
  local id = route_voice_id(part)
  local selector = params:lookup_param(id)
  local available = false
  local selected_index = 1
  if selector then
    for index, option in ipairs(selector.options or {}) do
      if option == voice_name then available = true; selected_index = index; break end
    end
  end
  if not available then
    if voice_name ~= "none" then print("nbin4: profile voice is not installed: " .. tostring(voice_name)) end
    voice_name = "none"
    selected_index = 1
  end

  params:set(id .. "_hidden_string", voice_name)
  params:set(id, selected_index, true)
  refresh_pressure_options(part)
end

local function set_profile_value(id, saved)
  local ok, parameter = pcall(params.lookup_param, params, id)
  if not ok or not parameter or type(saved) ~= "table" then return false end

  if parameter.t == params.tOPTION and saved.label then
    for index, option in ipairs(parameter.options or {}) do
      if option == saved.label then
        params:set(id, index)
        return true
      end
    end
  elseif parameter.t == params.tTEXT then
    params:set(id, saved.value)
    return true
  else
    params:set(id, saved.value)
    return true
  end
  return false
end

local function save_profile(name)
  local clean = clean_profile_name(name)
  if not clean then
    print("nbin4: enter a profile name using letters, numbers, spaces, _ or -")
    return
  end
  util.make_dir(PROFILE_DIR)
  local path = profile_path(clean)
  local ok, err = pcall(tab.save, collect_profile(), path)
  if not ok or not util.file_exists(path) then
    print("nbin4: could not save profile " .. clean .. ": " .. tostring(err))
    return
  end
  refresh_profile_options(clean)
  print("nbin4: saved complete profile " .. clean)
end

local function load_profile(name)
  local path = profile_path(name)
  if not path or not util.file_exists(path) then
    print("nbin4: profile not found")
    return
  end
  local ok, profile = pcall(tab.load, path)
  if not ok or type(profile) ~= "table" or profile.format ~= 1 then
    print("nbin4: could not read profile " .. tostring(name))
    return
  end

  release_all()
  for part = 1, PARTS do
    local saved = profile.parts and profile.parts[part]
    if saved then set_voice(part, saved.voice or "none") end
  end
  for part = 1, PARTS do
    local saved = profile.parts and profile.parts[part]
    if saved then
      params:set(route_channel_id(part), saved.channel or part)
      params:set(bend_range_id(part), saved.bend_range or 12)
      if not set_option_by_name(pressure_id(part, 1), saved.pressure or "none") then
        params:set(pressure_id(part, 1), 1)
      end
      if not set_option_by_name(pressure_id(part, 2), saved.more_pressure or "none") then
        params:set(pressure_id(part, 2), 1)
      end
      params:set(pressure_sensitivity_id(part), saved.pressure_sensitivity or 0)
    end
  end

  for voice_name, values in pairs(profile.voice_params or {}) do
    if type(note_players) == "table" and note_players[voice_name] then
      for id, saved in pairs(values) do
        if not set_profile_value(id, saved) then
          print("nbin4: skipped unavailable voice parameter " .. tostring(id))
        end
      end
    else
      print("nbin4: skipped parameters for unavailable voice " .. tostring(voice_name))
    end
  end

  local saved_input = profile.midi_input or {}
  local selected_port = 1
  if (saved_input.port or 0) > 0 then
    local candidate = state.devices[saved_input.port]
    if candidate and candidate.name == saved_input.name then
      selected_port = saved_input.port + 1
    else
      for port, device in pairs(state.devices) do
        if device and device.name == saved_input.name then selected_port = port + 1; break end
      end
    end
    if selected_port == 1 then
      print("nbin4: saved MIDI input is not connected; input set to <disabled>")
    end
  end
  params:set("nbin4_input", selected_port)
  refresh_profile_options(name)
  print("nbin4: loaded complete profile " .. tostring(name))
end

local function delete_profile(name)
  local path = profile_path(name)
  if not path or not util.file_exists(path) then return end
  local ok = os.remove(path)
  if ok then
    refresh_profile_options("<none>")
    print("nbin4: deleted profile " .. tostring(name))
  else
    print("nbin4: could not delete profile " .. tostring(name))
  end
end

release_all = function()
  for _, notes in pairs(state.active_counts) do
    for note, entry in pairs(notes) do
      if entry.player and entry.player.note_off and entry.count > 0 then
        pcall(entry.player.note_off, entry.player, note)
      end
    end
  end
  state.active_counts = {}
  state.held = {}
end

local function restore_input()
  if state.active_device then
    state.active_device.event = state.saved_event
  end
  state.active_device = nil
  state.saved_event = nil
end

local function player_for(part)
  local ok, selector = pcall(params.lookup_param, params, route_voice_id(part))
  if not ok or not selector or not selector.get_player then return nil end
  local player_ok, player = pcall(selector.get_player, selector)
  if player_ok then return player end
  return nil
end

local function channel_parts(channel)
  local parts = {}
  for part = 1, PARTS do
    local ok, assigned = pcall(params.get, params, route_channel_id(part))
    if ok and assigned == channel then parts[#parts + 1] = part end
  end
  return parts
end

local function voice_key(player)
  return player and (player.name or player) or nil
end

local function increment_note(player, note)
  local key = voice_key(player)
  if key == nil then return end
  state.active_counts[key] = state.active_counts[key] or {}
  local entry = state.active_counts[key][note]
  if not entry then
    entry = { count = 0, player = player }
    state.active_counts[key][note] = entry
  end
  entry.count = entry.count + 1
end

local function decrement_note(player, note)
  local key = voice_key(player)
  local notes = key and state.active_counts[key]
  local entry = notes and notes[note]
  if not entry then return end
  entry.count = entry.count - 1
  if entry.count <= 0 then
    notes[note] = nil
    if entry.player and entry.player.note_off then
      pcall(entry.player.note_off, entry.player, note)
    end
  end
  if next(notes) == nil then state.active_counts[key] = nil end
end

local function send_note_off(channel, note)
  local notes = state.held[channel]
  local batches = notes and notes[note]
  local batch = batches and table.remove(batches)
  if not batch then return end

  for _, target in ipairs(batch) do
    decrement_note(target.player, note)
  end
  if #batches == 0 then notes[note] = nil end
  if next(notes) == nil then state.held[channel] = nil end
end

local function pressure_values(value, sensitivity)
  local normalized = (value or 0) / 127
  local more = 2 * math.max(0, math.min(0.5, normalized - 0.5))
  return normalized, more * sensitivity
end

local function modulate_note(target, note, value)
  local part = target.part
  local player = target.player
  if not player or not player.modulate_note then return end

  local first = params:string(pressure_id(part, 1))
  local second = params:string(pressure_id(part, 2))
  local sensitivity = params:get(pressure_sensitivity_id(part))
  local normal, more = pressure_values(value, sensitivity)

  if first ~= "none" then pcall(player.modulate_note, player, note, first, normal) end
  if second ~= "none" then pcall(player.modulate_note, player, note, second, more) end
end

local function notes_for_channel(channel, only_note)
  local result = {}
  local notes = state.held[channel]
  if not notes then return result end

  for note, batches in pairs(notes) do
    if only_note == nil or note == only_note then
      for _, batch in ipairs(batches) do
        for _, target in ipairs(batch) do
          result[#result + 1] = { note = note, target = target }
        end
      end
    end
  end
  return result
end

local function handle_message(data)
  local ok, message = pcall(midi.to_msg, data)
  if not ok or type(message) ~= "table" or not message.ch then return end

  local channel = message.ch
  if message.type == "note_on" and (message.vel or 0) > 0 then
    local batch = {}
    for _, part in ipairs(channel_parts(channel)) do
      local player = player_for(part)
      if player and player.note_on then
        local played = pcall(player.note_on, player, message.note, message.vel / 127)
        if played then
          batch[#batch + 1] = { player = player, part = part }
          increment_note(player, message.note)
        end
      end
    end
    if #batch > 0 then
      state.held[channel] = state.held[channel] or {}
      state.held[channel][message.note] = state.held[channel][message.note] or {}
      table.insert(state.held[channel][message.note], batch)
    end

  elseif message.type == "note_off" or (message.type == "note_on" and (message.vel or 0) == 0) then
    send_note_off(channel, message.note)

  elseif message.type == "pitchbend" then
    local bend_value = ((math.floor((message.val or 8192) / 2 + 0.5)) / 8192) * 2 - 1
    for _, active in ipairs(notes_for_channel(channel)) do
      local target = active.target
      local range = params:get(bend_range_id(target.part))
      if target.player and target.player.pitch_bend then
        pcall(target.player.pitch_bend, target.player, active.note, bend_value * range)
      end
    end

  elseif message.type == "channel_pressure" then
    for _, active in ipairs(notes_for_channel(channel)) do
      modulate_note(active.target, active.note, message.val)
    end

  elseif message.type == "key_pressure" then
    for _, active in ipairs(notes_for_channel(channel, message.note)) do
      modulate_note(active.target, active.note, message.val)
    end
  end
end

local function input_event(data)
  -- Preserve the script's handler for the selected port, then add nbin4's route.
  if state.saved_event then pcall(state.saved_event, data) end
  handle_message(data)
end

local function select_input(value)
  restore_input()
  release_all()

  local port = (value or 1) - 1
  if port < 1 then return end

  local device = state.devices[port]
  if not device then return end
  state.active_device = device
  state.saved_event = device.event
  device.event = input_event
end

refresh_pressure_options = function(part)
  local player = player_for(part)
  local targets = {}
  local ok, description
  if player and player.describe then
    ok, description = pcall(player.describe, player)
  end

  if ok and description and type(description.note_mod_targets) == "table" then
    for _, name in ipairs(description.note_mod_targets) do
      targets[#targets + 1] = name
    end
  end

  local options = { "none" }
  for _, name in ipairs(targets) do options[#options + 1] = name end

  for index = 1, 2 do
    local id = pressure_id(part, index)
    local parameter = params:lookup_param(id)
    if parameter then
      parameter.options = options
      parameter.count = #options
      if parameter:get() > #options then parameter:set(1) end
    end
  end
  if _menu and _menu.rebuild_params then pcall(_menu.rebuild_params) end
end

local function add_profile_params()
  params:add_separator("nbin4_profiles_separator", "NBIN 4 profiles")
  params:add_option("nbin4_profile", "Profile", { "<none>" }, 1)
  params:add_trigger("nbin4_save_profile", "Save complete profile")
  params:add_trigger("nbin4_load_profile", "Load selected profile")
  params:add_trigger("nbin4_delete_profile", "Delete selected profile")

  refresh_profile_options("<none>")

  params:set_action("nbin4_save_profile", function()
    local textentry = require "textentry"
    textentry.enter(function(name)
      if name then save_profile(name) end
    end, "", "Save nbin4 profile")
  end)
  params:set_action("nbin4_load_profile", function()
    local name = params:string("nbin4_profile")
    if name ~= "<none>" then load_profile(name) end
  end)
  params:set_action("nbin4_delete_profile", function()
    local name = params:string("nbin4_profile")
    if name ~= "<none>" then delete_profile(name) end
  end)
end

local function add_part_params(part)
  params:add_option(route_channel_id(part), "P" .. part .. " MIDI channel", {
    "01", "02", "03", "04", "05", "06", "07", "08",
    "09", "10", "11", "12", "13", "14", "15", "16",
  }, part)

  state.nb:add_param(route_voice_id(part), "P" .. part .. " n.b. voice")
  local selector = params:lookup_param(route_voice_id(part))
  if selector then
    local original_action = selector.action
    params:set_action(route_voice_id(part), function(value)
      if original_action then original_action(value) end
      refresh_pressure_options(part)
    end)
  end

  params:add_number(bend_range_id(part), "P" .. part .. " bend range", 2, 24, 12)
  params:add_option(pressure_id(part, 1), "P" .. part .. " pressure", { "none" }, 1)
  params:add_option(pressure_id(part, 2), "P" .. part .. " more pressure", { "none" }, 1)
  params:add_control(pressure_sensitivity_id(part), "P" .. part .. " pressure sensitivity", controlspec.BIPOLAR)
end

local function add_params()
  local nb_ok, nb = pcall(require, "nbout/lib/nb/lib/nb")
  if not nb_ok then nb_ok, nb = pcall(require, "nb/lib/nb") end
  if not nb_ok or type(nb) ~= "table" then
    state.nb = nil
    print("nbin4: could not load the n.b. library")
    return
  end

  state.nb = nb
  local initialized, init_error = pcall(nb.init, nb)
  if not initialized then
    print("nbin4: n.b. initialization failed: " .. tostring(init_error))
    state.nb = nil
    return
  end

  local count = 2 + 5 + PARTS * 7
  params:add_group("nbin4_group", "NBIN 4", count)
  params:add_option("nbin4_input", "MIDI input", state.device_names, 1)
  params:set_action("nbin4_input", select_input)
  params:add_trigger("nbin4_panic", "All notes off")
  params:set_action("nbin4_panic", release_all)

  add_profile_params()

  for part = 1, PARTS do add_part_params(part) end
  if nb.add_player_params then
    local players_ok, players_error = pcall(nb.add_player_params, nb)
    if not players_ok then print("nbin4: could not add n.b. voice parameters: " .. tostring(players_error)) end
  end
  state.ready = true

  -- Apply this mod's saved selections after script init has finished loading its
  -- own pset. Voice selectors also refresh the available MPE pressure targets.
  clock.run(function()
    clock.sleep(1.25)
    for part = 1, PARTS do
      local selector = params:lookup_param(route_voice_id(part))
      if selector and selector.bang then selector:bang() end
    end
    local input = params:lookup_param("nbin4_input")
    if input and input.bang then input:bang() end
  end)
end

local function prepare_devices()
  restore_input()
  release_all()
  state.devices = {}
  state.device_names = { "<disabled>" }

  for port = 1, #midi.vports do
    local device = midi.connect(port)
    state.devices[port] = device
    local name = device and device.name or "MIDI port " .. port
    table.insert(state.device_names, "port " .. port .. ": " .. util.trim_string_to_width(name, 40))
  end
end

local function cleanup()
  release_all()
  restore_input()
  restore_voice_wrappers()
  state.ready = false
  state.nb = nil
end

local function register_post_init_compat()
  if hook.script_post_init ~= nil or mod.hook.patched then return end

  mod.hook.patched = true
  local original_register = mod.hook.register
  local callbacks = {}

  mod.hook.register = function(event, name, callback)
    if event == "script_post_init" then
      callbacks[name] = callback
    else
      original_register(event, name, callback)
    end
  end

  mod.hook.register("script_pre_init", "!nbin4 post-init compatibility", function()
    local original_init = init
    init = function(...)
      original_init(...)
      local names = {}
      for name in pairs(callbacks) do names[#names + 1] = name end
      table.sort(names)
      for _, name in ipairs(names) do
        local ok, err = pcall(callbacks[name])
        if not ok then print("nbin4: post-init hook failed: " .. tostring(err)) end
      end
    end
  end)
end

register_post_init_compat()

mod.hook.register("script_pre_init", "nbin4 prepare MIDI", prepare_devices)
mod.hook.register("script_pre_init", "~nbin4 capture voice params", track_voice_params)
mod.hook.register("script_post_init", "nbin4 add parameters", add_params)
mod.hook.register("script_post_cleanup", "nbin4 cleanup", cleanup)
mod.hook.register("system_pre_shutdown", "nbin4 shutdown cleanup", cleanup)

return {
  release_all = release_all,
  cleanup = cleanup,
}
