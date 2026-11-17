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
  ready = false,
}

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

local function release_all()
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

local function refresh_pressure_options(part)
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

  local count = 2 + PARTS * 7
  params:add_group("nbin4_group", "NBIN 4", count)
  params:add_option("nbin4_input", "MIDI input", state.device_names, 1)
  params:set_action("nbin4_input", select_input)
  params:add_trigger("nbin4_panic", "All notes off")
  params:set_action("nbin4_panic", release_all)

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
mod.hook.register("script_post_init", "nbin4 add parameters", add_params)
mod.hook.register("script_post_cleanup", "nbin4 cleanup", cleanup)
mod.hook.register("system_pre_shutdown", "nbin4 shutdown cleanup", cleanup)

return {
  release_all = release_all,
  cleanup = cleanup,
}
