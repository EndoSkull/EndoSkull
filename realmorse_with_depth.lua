--###########################################################################
-- Stormworks Global Morse Code Addon - OPTIMIZED (Vehicle-specific channel storage)
-- Version 2.6.14 (Physical Button "setTelegraph" for Dial Channel Set)
--   Channel is now stored per vehicle instead of per player.
--   Channel is set from "telegraph" dial when a physical vehicle button named "setTelegraph" is pressed by the radioman.
--   Removed '?setTelegraph' chat command.
--   DEFAULT_CHANNEL remains 0 (addon functions disabled if vehicle's channel is 0).
-- 
-- Timings updated for ~25 WPM (experienced operator speed)
-- OPTIMIZED VERSION with performance improvements
--###########################################################################

--=========================================================================  
-- Localize frequently used functions for performance
--=========================================================================  
local table_insert = table.insert
local table_remove = table.remove
local table_concat = table.concat
local math_floor = math.floor
local math_min = math.min
local math_max = math.max
local math_random = math.random
local string_format = string.format
local string_sub = string.sub
local string_match = string.match
local string_gmatch = string.gmatch
local string_lower = string.lower
local pairs = pairs
local ipairs = ipairs
local type = type
local tostring = tostring
local tonumber = tonumber

--=========================================================================  
--  Script-level state variables
--  These tables and variables store the addon's state throughout its lifecycle.
--=========================================================================  
local is_initialized              = false     -- Flag to indicate if the addon has completed its initial setup.
local initialization_delay_start_time = 0       -- Timestamp (ms) when the initialization delay period began.
local INITIALIZATION_DELAY_SECONDS  = 10        -- Duration (seconds) to wait after onCreate before fully initializing.
local new_world_create_flag_for_init = false    -- Flag passed from onCreate to indicate if the world is new.

-- local player_virtual_channel    = {}        -- (Removed: channel is now vehicle-specific)
local player_addon_enabled          = {}        -- Stores if the Morse addon is enabled for each player_id. e.g., player_addon_enabled[pid] = true
local pending_morse_text_displays   = {}        -- Queue for messages/UI updates that need to be displayed after a delay or sequence of events.
local seat_occupants                = {}        -- Tracks which player_id is in which seat of which vehicle_id. e.g., seat_occupants[vid][seat_name] = pid
local debug_echo                    = false     -- Global flag to enable/disable verbose debug messages to chat.
local channel_logs                  = {}        -- Stores logs of Morse messages for each channel. e.g., channel_logs[channel_num] = {log_entry1, ...}
local player_log_cursor             = {}        -- Stores the current log viewing position for each player on each channel. e.g., player_log_cursor[pid][channel_num] = log_index
local morse_button_pulses           = {}        -- Queue for scheduled Morse code button presses on vehicles.
local pressVehicleButton_is_broken  = false     -- Flag to indicate if server.pressVehicleButton is detected as non-functional.

-- OPTIMIZATION: Lookup tables for O(1) access
local player_to_vehicle             = {}        -- Direct mapping: pid -> vehicle_id
local radioman_players              = {}        -- Set of pids who are radiomen
local player_cache                  = {}        -- Cache for player data when needed (updated on sit/unsit)

-- Vehicle-specific channel storage (new)
local vehicle_virtual_channel       = {}        -- Stores channel per vehicle_id. e.g., vehicle_virtual_channel[vid] = 44

--=========================================================================  
--  Timing constants and other fixed values
--  Defines base values for Morse code timings, limits, and default settings.
--=========================================================================  
-- Target: ~25 WPM for an experienced operator.
-- 1 WPM (PARIS standard) = 50 dot units per minute.
-- 25 WPM = 1250 dot units per minute.
-- Time per dot unit = 60,000 ms / 1250 units = 48 ms.
-- So, MORSE_BASE_UNIT_SECONDS = 0.048 seconds.
local MORSE_BASE_UNIT_SECONDS     = 0.048 -- The duration of one "dit" or base time unit in seconds (0.048s for ~25 WPM).
local MORSE_UNIT_TIME_MS          = MORSE_BASE_UNIT_SECONDS * 1000 -- Base time unit in milliseconds.
local DOT_TIME_MS                 = MORSE_UNIT_TIME_MS * 2  -- Duration of a "dit" signal (48 ms).
local DASH_TIME_MS                = MORSE_UNIT_TIME_MS * 5  -- Duration of a "dah" signal (144 ms).
local INTRA_CHAR_SPACE_MS         = MORSE_UNIT_TIME_MS * 1  -- Space between dits and dahs within a single character (48 ms).
local INTER_CHAR_SPACE_MS         = MORSE_UNIT_TIME_MS * 3  -- Space between Morse characters (144 ms).
local WORD_SPACE_MS               = MORSE_UNIT_TIME_MS * 7  -- Space between Morse words (often represented by '/') (336 ms).

local LOG_LIMIT                   = 50        -- Maximum number of messages to store per channel log.
local DEFAULT_CHANNEL             = 0         -- Default Morse channel. Channel 0 means addon is effectively disabled for the vehicle.
local TRANSLATION_DELAY_PER_CHAR_MS = 300       -- Artificial delay (ms) per character for displaying translated text, simulating effort.
local COMMAND_LIST_TEXT           = "?m <morse> | ?msgs | ?mprev | ?mnext" -- Text displaying available commands. (?setTelegraph removed)

--=========================================================================  
--  New configuration for depth limits and dial name
--=========================================================================  
local RADIO_DEPTH_DIAL_NAME       = "radioDepth"
local MAX_SEND_DEPTH              = 15  -- Maximum depth (meters) allowed to send messages
local MAX_RECEIVE_DEPTH           = 30  -- Maximum depth (meters) allowed to receive messages

--=========================================================================  
--  Morse dictionary
--  Maps Morse code patterns to their corresponding alphanumeric characters.
--  Unchanged from previous versions.
--=========================================================================  
local morse_to_text_dict = {
  [".-"]="A", ["-..."]="B", ["-.-."]="C", ["-.."]="D", ["."]="E", ["..-."]="F",
  ["--."]="G", ["...."]="H", [".."]="I", [".---"]="J", ["-.-"]="K", [".-.."]="L",
  ["--"]="M", ["-."]="N", ["---"]="O", [".--."]="P", ["--.-"]="Q", [".-."]="R",
  ["..."]="S", ["-"]="T", ["..-"]="U", ["...-"]="V", [".--"]="W", ["-..-"]="X",
  ["-.--"]="Y", ["--.."]="Z", ["-----"]="0", [".----"]="1", ["..---"]="2",
  ["...--"]="3", ["....-"]="4", ["....."]="5", ["-...."]="6", ["--..."]="7",
  ["---.."]="8", ["----."]="9", [".-.-.-"]=".", ["--..--"]=",", ["..--.."]="?",
  [".----."]="'", ["-.-.--"]="!", ["-..-."]="/", ["-.--."]="(", ["-.--.-"]=")",
  [".-..."]="&", ["---..."]=":", ["-.-.-."]=";", ["-...-"]="=", [".-.-."]="+",
  ["-....-"]="-", ["..--.-"]="_", [".-..-."]='"', ["...-..-"]="$", [".--.-."]="@" }

-- OPTIMIZATION: Valid morse characters lookup for O(1) validation
local valid_morse_chars = {['.'] = true, ['-'] = true, [' '] = true, ['/'] = true}

--=========================================================================  
--  Utility helper functions
--  General-purpose functions used throughout the script.
--=========================================================================  

-- Removes leading and trailing whitespace from a string.
-- @param s: The input string.
-- @return string: The trimmed string.
local function trim(s)
  return string_match(s, "^%s*(.-)%s*$")
end

-- Splits a string by spaces into a table of words.
-- @param str: The input string.
-- @return table: A table containing the words from the string.
local function split_by_spaces(str)
    local t = {}
    for w in string_gmatch(str, "%S+") do 
        table_insert(t, w)
    end
    return t
end

-- OPTIMIZED: Checks if a string contains only valid Morse code characters ('.', '-', '/', space).
-- @param s: The input string.
-- @return boolean: True if the string is a valid Morse pattern, false otherwise.
local function isValidMorsePattern(s)
    for i = 1, #s do
        if not valid_morse_chars[string_sub(s, i, i)] then
            return false
        end
    end
    return true
end

-- Generates a random string of Morse code characters. Used for testing/placeholders.
-- @return string: A randomly generated Morse code string.
local function generateRandomMorse()
    -- GUARD: ensure valid_morse_chars exists
    if type(valid_morse_chars) ~= "table" then valid_morse_chars = {['.']=true,['-']=true,[' ']=true,['/']=true} end

    local mc = {".", "-"}
    local out = {}
    for i = 1, math_random(3, 15) do
        if i > 1 and math_random() < 0.3 then 
            table_insert(out, " ")
        end
        table_insert(out, mc[math_random(2)])
    end
    return table_concat(out)
end

-- PATCH ? robust single-word handling (from v2.6.x)
-- Translates a Morse code string into plain text.
-- Handles Morse code with or without explicit word separators ('/').
-- @param code: The Morse code string.
-- @return string: The translated plain text. Unknown Morse characters are replaced with '?'.
local function morseToText(code)
    local out = {}
    local words = {}
    for w in string_gmatch(code, "[^/]+") do 
        table_insert(words, trim(w))
    end
    if #words == 0 then words = { trim(code) } end 

    for i, w_idx in ipairs(words) do
        if i > 1 then table_insert(out, " ") end 
        local chars = split_by_spaces(w_idx) 
        if #chars == 0 and w_idx ~= "" then chars = { w_idx } end
        for _, c in ipairs(chars) do
            table_insert(out, morse_to_text_dict[c] or "?")
        end
    end
    return table_concat(out)
end
-- /PATCH -------------------------------------------------------------------

-- Retrieves the player's name using their peer_id. Falls back to a generic name.
-- @param pid: The player's peer_id.
-- @return string: The player's name or a generic "Player<pid>".
local function getPlayerName(pid)
  return server.getPlayerName(pid) or ("Player" .. pid)
end

-- PATCH ? HH:MM (from v2.6.x)
-- Formats a millisecond timestamp into an [HH:MM] string.
-- @param timestamp_ms: The timestamp in milliseconds.
-- @return string: The formatted time string, e.g., "[14:32]", or "[??:??]" if input is invalid.
local function format_timestamp_hhmm(timestamp_ms)
    if not timestamp_ms or timestamp_ms == 0 then return "[??:??]" end
    local total_seconds_epoch = math_floor(timestamp_ms / 1000)
    local hh = math_floor(total_seconds_epoch / 3600) % 24 
    local mm = math_floor(total_seconds_epoch / 60) % 60   
    return string_format("[%02d:%02d]", hh, mm)
end
-- /PATCH -------------------------------------------------------------------

--=========================================================================  
--  UI / Announce helper functions
--=========================================================================  

-- Displays the list of available Morse addon commands to a player.
-- @param pid: The peer_id of the player to show commands to.
local function display_commands(pid)
    if not is_initialized or not pid then return end 
    server.announce("-", "------------------------------------------------", pid)
    server.announce("[Commands:]", COMMAND_LIST_TEXT, pid)
    server.announce("-", "------------------------------------------------", pid)
end

--=========================================================================  
--  Player and addon state initialization/management functions
--=========================================================================  

-- Initializes the state for a specific player if it hasn't been set up yet.
-- @param pid: The peer_id of the player.
local function init_player_state(pid)
    if not pid then 
        if debug_echo then server.announce("[Morse DIAG]", "init_player_state called with nil pid. Aborting.", -1) end
        return
    end
    if not is_initialized then return end 
    if player_addon_enabled[pid] == nil then
        player_addon_enabled[pid] = true
    end
end

-- Initializes or resets the global state of the addon.
-- @param new_world: Boolean, true if this is a new world, false if addon is reloaded.
local function initialize_addon_state(new_world)
    -- GUARD: ensure all tables are actually tables
    if type(player_addon_enabled) ~= "table" then player_addon_enabled = {} end
    if type(pending_morse_text_displays) ~= "table" then pending_morse_text_displays = {} end
    if type(seat_occupants) ~= "table" then seat_occupants = {} end
    if type(channel_logs) ~= "table" then channel_logs = {} end
    if type(player_log_cursor) ~= "table" then player_log_cursor = {} end
    if type(morse_button_pulses) ~= "table" then morse_button_pulses = {} end

    debug_echo                  = false 
    pressVehicleButton_is_broken = false 
    
    -- OPTIMIZATION: Clear lookup tables
    player_to_vehicle = {}
    radioman_players = {}
    player_cache = {}
    vehicle_virtual_channel = {}

    server.announce("[Morse Addon]", "Loading v2.6.14 - OPTIMIZED") -- Updated version
    server.announce("[Morse Addon]", new_world and "World Created - Ready!" or "Addon Reloaded - Ready!")
    server.announce("[Morse Addon]", "IMPORTANT: Radioman seat required to send/receive messages. Vehicle channel defaults to 0 (disabled).")
end

--=========================================================================  
--  Stormworks Engine Entry Point: onCreate
--=========================================================================  
function onCreate(new_world)
    is_initialized              = false 
    initialization_delay_start_time = server.getTimeMillisec() 
    new_world_create_flag_for_init  = new_world 

    -- GUARD: ensure tables are reinitialized early
    pending_morse_text_displays   = {} 
    morse_button_pulses           = {} 

    server.announce("[Morse Addon]", "Scheduling initialization in " .. INITIALIZATION_DELAY_SECONDS .. "s")
end

--=========================================================================  
--  Vehicle and seat helper functions
--=========================================================================  

-- OPTIMIZED: Gets the vehicle ID a player is currently in.
-- @param pid: The player's peer_id.
-- @return number|nil: The vehicle_id if found, otherwise nil.
local function getPlayerVehicle(pid)
    if not is_initialized or not pid then return nil end
    if type(player_to_vehicle) ~= "table" then player_to_vehicle = {} end
    return player_to_vehicle[pid]
end

-- Helper function to determine vehicle ID prefix based on channel number digits
-- @param channel_num: The channel number.
-- @return string: The prefix ("U-" or "SS-"). Returns "U-" if channel is 0 or invalid.
local function getPrefixForChannelNumber(channel_num)
    if not channel_num or channel_num == 0 then return "U-" end 
    local ch_str = tostring(channel_num)
    if #ch_str == 3 then return "U-"
    elseif #ch_str == 2 then return "SS-"
    else return "U-" 
    end
end

-- Gets the player's current Morse channel and the corresponding vehicle ID prefix.
-- @param pid: The peer_id of the player.
-- @return channel_number, id_prefix_string
local function getPlayerCurrentChannelAndPrefix(pid)
    if not pid then 
        if debug_echo then server.announce("[Morse DIAG]", "getPlayerCurrentChannelAndPrefix called with nil pid. Returning channel 0 defaults.", -1) end
        return 0, getPrefixForChannelNumber(0) 
    end

    init_player_state(pid) 

    local veh_id = getPlayerVehicle(pid)
    local current_channel = DEFAULT_CHANNEL
    if veh_id and type(vehicle_virtual_channel) == "table" and vehicle_virtual_channel[veh_id] then
        current_channel = vehicle_virtual_channel[veh_id]
    end
    local determined_prefix = getPrefixForChannelNumber(current_channel)
   
    return current_channel, determined_prefix
end

-- Formats a log entry for display in the chat when browsing logs (?mprev, ?mnext).
-- @param entry: The log entry table.
-- @param viewing_vid: The vehicle_id of the player viewing the log (to determine SENT/RECV).
-- @param now_ms: Current server time in milliseconds (for calculating age).
-- @param id_prefix: The vehicle ID prefix ("U-" or "SS-") to use for this channel.
-- @return string: A formatted string representing the log entry.
local function fmtChannelEntry(entry, viewing_vid, now_ms, id_prefix)
    if not entry then return "Error: missing log entry" end

    local direction = "RECV" 
    local vehicle_id_string = id_prefix .. tostring(entry.sender_vehicle_id or "N/A")

    if entry.sender_vehicle_id and viewing_vid and entry.sender_vehicle_id == viewing_vid then
        direction = "SENT"
        vehicle_id_string = id_prefix .. tostring(viewing_vid) 
    end

    local time_string = format_timestamp_hhmm(entry.when or 0) 
    local age_ms = now_ms - (entry.when or 0) 
    local age_minutes = math_floor(age_ms / 60000)
    local age_string
    if age_minutes < 1 then age_string = "(<1m ago)"
    elseif age_minutes < 60 then age_string = "(" .. age_minutes .. "m ago)"
    elseif age_minutes < 1440 then age_string = "(" .. math_floor(age_minutes / 60) .. "h ago)" 
    else age_string = "(" .. math_floor(age_minutes / 1440) .. "d ago)" end 

    return string_format("%s %s %s %s '%s'", direction, time_string, vehicle_id_string, age_string, entry.text or "?")
end

-- OPTIMIZED: Checks if a player is currently sitting in a seat named "radioman".
-- @param pid: The player's peer_id.
-- @return boolean: True if the player is in a radioman seat, false otherwise.
local function isPlayerRadioman(pid)
    if not is_initialized or not pid then return false end
    if type(radioman_players) ~= "table" then radioman_players = {} end
    return radioman_players[pid] == true
end

-- Queues a follow-up display for a log entry that is still being "received" (pulses ongoing).
-- @param pid: The peer_id of the player viewing the log.
-- @param entry: The log entry table (which is currently in progress).
-- @param ch: The channel number of the log.
-- @param prefix_chat_announce: The chat prefix to use for the follow-up messages.
local function queue_log_follow_up(pid, entry, ch, prefix_chat_announce)
    if not entry or not entry.pulse_expected_end_time then return end 

    if type(pending_morse_text_displays) ~= "table" then pending_morse_text_displays = {} end

    for _, t_item in ipairs(pending_morse_text_displays) do
        if t_item.is_log_follow_up and t_item.target_pid == pid and t_item.channel_for_display == ch and
            t_item.pulses_end_time_ms == entry.pulse_expected_end_time and t_item.morse_to_display == entry.morse then
            if debug_echo then server.announce("[Morse DIAG]", "Duplicate log follow-up suppressed for P" .. pid, pid) end
            return 
        end
    end

    table_insert(pending_morse_text_displays, {
        is_log_follow_up            = true, 
        target_pid                  = pid,
        sender_name_for_display     = entry.sender_name,
        sender_vehicle_id_original  = entry.sender_vehicle_id, 
        channel_for_display         = ch,
        morse_to_display            = entry.morse,
        text_to_display             = entry.text,
        stage                       = "log_wait_for_pulse_end", 
        pulses_end_time_ms          = entry.pulse_expected_end_time,
        text_display_time_ms        = 0, 
        log_display_prefix_chat     = prefix_chat_announce 
    })
end

-- Core logic for showing the latest message (sent or received) to a player for ?msgs or seat join.
-- @param pid_to_show: The peer_id of the player to show the message to.
local function execute_show_latest_received_logic(pid_to_show)
    if not is_initialized then return end
    if not pid_to_show then if debug_echo then server.announce("[Morse DIAG]", "execute_show_latest_received_logic called with nil pid_to_show.", -1) end return end

    local current_channel_val, id_prefix = getPlayerCurrentChannelAndPrefix(pid_to_show)
    local viewing_vehicle_id = getPlayerVehicle(pid_to_show)

    if not isPlayerRadioman(pid_to_show) then
        server.announce("[Message Logs]", "Radioman seat required to view messages!", pid_to_show)
        return
    end

    if current_channel_val == 0 then
        server.announce("[Message Logs]", "Channel 0 is disabled. No messages will be shown. Use ?morse_channel or press 'setTelegraph' button on vehicle.", pid_to_show)
        return
    end
   
    if current_channel_val == nil then 
        server.announce("[Message Logs]", "Error: Channel not set. Please use ?morse_channel or press 'setTelegraph' button on vehicle.", pid_to_show)
        return
    end

    if type(channel_logs) ~= "table" then channel_logs = {} end
    channel_logs[current_channel_val] = channel_logs[current_channel_val] or {}
    local current_channel_log = channel_logs[current_channel_val]

    if #current_channel_log == 0 then
        server.announce("[Message Logs]", "No messages on Ch:" .. current_channel_val .. " yet.", pid_to_show)
        return
    end

    local latest_completed_entry = nil
    local latest_completed_entry_index = -1
    local current_server_time_exec = server.getTimeMillisec()

    for i = #current_channel_log, 1, -1 do
        local entry = current_channel_log[i]
        if not (entry.pulse_expected_end_time and current_server_time_exec < entry.pulse_expected_end_time) then
            latest_completed_entry = entry
            latest_completed_entry_index = i
            break 
        end
    end

    if latest_completed_entry then
        local display_direction_header
        local display_source_dest_header
        local message_text_body = latest_completed_entry.text or "???"

        if latest_completed_entry.sender_vehicle_id == viewing_vehicle_id then
            display_direction_header = "SENT Ch:" .. current_channel_val
            display_source_dest_header = "To: (Broadcast)" 
        else
            display_direction_header = "RECV Ch:" .. current_channel_val
            display_source_dest_header = "From: " .. id_prefix .. tostring(latest_completed_entry.sender_vehicle_id or "N/A")
        end

        local time_body = "Time: " .. format_timestamp_hhmm(latest_completed_entry.when or 0)
        server.announce(display_direction_header, time_body, pid_to_show)
        server.announce(display_source_dest_header, message_text_body, pid_to_show)

        if type(player_log_cursor) ~= "table" then player_log_cursor = {} end
        player_log_cursor[pid_to_show] = player_log_cursor[pid_to_show] or {}
        player_log_cursor[pid_to_show][current_channel_val] = latest_completed_entry_index
    else
        local found_in_progress_to_display = false
        for i = #current_channel_log, 1, -1 do
            local entry = current_channel_log[i]
            local is_truly_incoming_from_other_vehicle = not viewing_vehicle_id or (entry.sender_vehicle_id and entry.sender_vehicle_id ~= viewing_vehicle_id) or not entry.sender_vehicle_id

            if is_truly_incoming_from_other_vehicle then
                if (entry.pulse_expected_end_time and current_server_time_exec < entry.pulse_expected_end_time) then
                    local header_ch_prog = "RECV Ch:" .. current_channel_val 
                    local time_str_log_prog = format_timestamp_hhmm(entry.when or 0)
                    local time_remaining_ms_prog = entry.pulse_expected_end_time - current_server_time_exec
                    local body_prog = string_format("Time: %s Receiving from %s%s (Completes in %.1fs)",
                        time_str_log_prog,
                        id_prefix, 
                        tostring(entry.sender_vehicle_id or "N/A"),
                        time_remaining_ms_prog / 1000
                    )
                    server.announce(header_ch_prog, body_prog, pid_to_show)
                    queue_log_follow_up(pid_to_show, entry, current_channel_val, header_ch_prog) 

                    if type(player_log_cursor) ~= "table" then player_log_cursor = {} end
                    player_log_cursor[pid_to_show] = player_log_cursor[pid_to_show] or {}
                    player_log_cursor[pid_to_show][current_channel_val] = i
                    found_in_progress_to_display = true
                    break 
                end
            end
        end

        if not found_in_progress_to_display then
            server.announce("[Message Logs]", "No new messages on Ch:" .. current_channel_val .. ".", pid_to_show)
            if #current_channel_log > 0 then
                if type(player_log_cursor) ~= "table" then player_log_cursor = {} end
                player_log_cursor[pid_to_show] = player_log_cursor[pid_to_show] or {}
                if not player_log_cursor[pid_to_show][current_channel_val] or player_log_cursor[pid_to_show][current_channel_val] > #current_channel_log or player_log_cursor[pid_to_show][current_channel_val] < 1 then
                     player_log_cursor[pid_to_show][current_channel_val] = #current_channel_log
                end
            end
        end
    end
end

--=========================================================================  
--  Stormworks Engine Entry Point: onTick
--  Called every game tick. Main loop for time-based actions.
--  HEAVILY OPTIMIZED
--  Modified: Removed per-tick player_cache rebuild; player_cache is now updated only on sit/unsit.
--=========================================================================  
function onTick()
    if not is_initialized then
        if server.getTimeMillisec() < initialization_delay_start_time + (INITIALIZATION_DELAY_SECONDS * 1000) then
            return 
        end
        initialize_addon_state(new_world_create_flag_for_init)
        is_initialized = true 
    end

    local now_ms = server.getTimeMillisec()

    -- GUARD: Ensure critical tables exist before indexing
    if type(pending_morse_text_displays) ~= "table" then pending_morse_text_displays = {} end
    if type(morse_button_pulses) ~= "table" then morse_button_pulses = {} end
    if type(seat_occupants) ~= "table" then seat_occupants = {} end

    -- Process pending morse text displays
    local i = 1
    while type(pending_morse_text_displays) == "table" and i <= #pending_morse_text_displays do
        local task = pending_morse_text_displays[i]
        local handled_this_iteration = false 

        if task.is_sender_confirmation then
            if now_ms >= task.display_time_ms then 
                if task.target_pid then server.announce(task.tag_text, task.body_text, task.target_pid) end
                table_remove(pending_morse_text_displays, i) 
                handled_this_iteration = true
                if task.target_pid then display_commands(task.target_pid) end
            end
        elseif task.is_recipient_message then
            local id_prefix_for_task = getPrefixForChannelNumber(task.channel_for_display) 
            if task.stage == "incoming" then 
                if not task.incoming_announced then 
                    -- Use updated player_cache for recipients
                    if type(player_cache) ~= "table" then player_cache = {} end
                    for p_id_display, p_data in pairs(player_cache) do
                        if p_id_display ~= task.original_sender_pid and
                           p_data.vehicle == task.vehicle_id and
                           p_data.channel == task.channel_for_display and 
                           p_data.channel ~= 0 and
                           p_data.enabled and
                           p_data.is_radioman then
                            local header = "[RECV Ch:" .. task.channel_for_display .. "]"
                            local time_str_start = format_timestamp_hhmm(task.message_start_time_original or 0)
                            local time_remaining_s = (task.pulses_end_time_ms - now_ms) / 1000
                            if time_remaining_s < 0 then time_remaining_s = 0 end
                            local body = string_format("%s Receiving from %s %s%s (Completes in %.1fs)",
                                time_str_start,
                                task.sender_name_for_display or "Unknown",
                                id_prefix_for_task, 
                                tostring(task.sender_vehicle_id_original or "N/A"),
                                time_remaining_s
                            )
                            server.announce(header, body, p_id_display)
                        end
                    end
                    task.incoming_announced = true 
                end
                if now_ms >= task.pulses_end_time_ms then 
                    task.stage = "display_morse" 
                end

            elseif task.stage == "display_morse" then 
                if now_ms >= task.pulses_end_time_ms then 
                    -- Use updated player_cache for final Morse display
                    if type(player_cache) ~= "table" then player_cache = {} end
                    for p_id_display, p_data in pairs(player_cache) do
                        if p_id_display ~= task.original_sender_pid and
                           p_data.vehicle == task.vehicle_id and
                           p_data.channel == task.channel_for_display and
                           p_data.channel ~= 0 and
                           p_data.enabled and
                           p_data.is_radioman then
                            local morse_header = "[RECV Ch:"..task.channel_for_display.." "..task.sender_name_for_display.."]"
                            server.announce(morse_header, task.morse_to_display, p_id_display)
                            server.announce(morse_header, "Translating...", p_id_display)
                        end
                    end
                    local translation_delay_ms = (#task.text_to_display * TRANSLATION_DELAY_PER_CHAR_MS)
                    if #task.text_to_display == 0 then translation_delay_ms = 500 end 
                    task.text_display_time_ms = now_ms + translation_delay_ms
                    task.stage = "display_text" 
                end

            elseif task.stage == "display_text" then 
                if now_ms >= task.text_display_time_ms then 
                    if type(player_cache) ~= "table" then player_cache = {} end
                    for p_id_display, p_data in pairs(player_cache) do
                        if p_id_display ~= task.original_sender_pid and
                           p_data.vehicle == task.vehicle_id and
                           p_data.channel == task.channel_for_display and
                           p_data.channel ~= 0 and
                           p_data.enabled and
                           p_data.is_radioman then
                            local translated_text_header = "RECV " .. id_prefix_for_task .. tostring(task.sender_vehicle_id_original or "N/A")
                            server.announce(translated_text_header, "'"..task.text_to_display.."'", p_id_display)
                            display_commands(p_id_display) 
                        end
                    end
                    table_remove(pending_morse_text_displays, i) 
                    handled_this_iteration = true
                end
            end

        elseif task.is_log_follow_up then
            local id_prefix_for_log_task = getPrefixForChannelNumber(task.channel_for_display)
            if task.stage == "log_wait_for_pulse_end" then 
                if now_ms >= task.pulses_end_time_ms then
                    if task.target_pid then
                        local morse_header_log = task.log_display_prefix_chat or "[RECV Ch:"..task.channel_for_display.."]" 
                        server.announce(morse_header_log, task.morse_to_display, task.target_pid)
                        server.announce(morse_header_log, "Translating...", task.target_pid)
                    end
                    local translation_delay_ms = (#task.text_to_display * TRANSLATION_DELAY_PER_CHAR_MS)
                    if #task.text_to_display == 0 then translation_delay_ms = 500 end
                    task.text_display_time_ms = now_ms + translation_delay_ms
                    task.stage = "log_display_final_text" 
                end
            elseif task.stage == "log_display_final_text" then 
                if now_ms >= task.text_display_time_ms then
                    if task.target_pid then
                        local translated_text_header_log = "RECV " .. id_prefix_for_log_task .. tostring(task.sender_vehicle_id_original or "N/A")
                        server.announce(translated_text_header_log, "'"..task.text_to_display.."'", task.target_pid)
                        display_commands(task.target_pid)
                    end
                    table_remove(pending_morse_text_displays, i) 
                    handled_this_iteration = true
                end
            end

        elseif task.is_deferred_sit_display then
            if now_ms >= task.display_time_ms then 
                if task.target_pid then
                    execute_show_latest_received_logic(task.target_pid) 
                    display_commands(task.target_pid) 
                end
                table_remove(pending_morse_text_displays, i)
                handled_this_iteration = true
            end

        elseif task.is_simple_announce_task then
            if now_ms >= task.display_time_ms then
                if task.target_pid then server.announce(task.prefix, task.body, task.target_pid) end
                table_remove(pending_morse_text_displays, i)
                handled_this_iteration = true
            end

        elseif task.is_deferred_display_commands_after_sit then 
            if now_ms >= task.display_time_ms then
                if task.target_pid then display_commands(task.target_pid) end
                table_remove(pending_morse_text_displays, i)
                handled_this_iteration = true
            end
        end

        if not handled_this_iteration then
            i = i + 1 
        end
    end

    -- Process morse button pulses
    if type(morse_button_pulses) == "table" and #morse_button_pulses > 0 then
        local k = 1
        while k <= #morse_button_pulses and morse_button_pulses[k].action_time <= now_ms do
            local pulse = morse_button_pulses[k]
            
            if debug_echo then
                local pulse_processed_for_player_debug = false
                local press_button_func_type_dbg = "nil"
                if server and server.pressVehicleButton then press_button_func_type_dbg = type(server.pressVehicleButton) end
                local can_call_pressvehiclebutton_debug = (server and type(server.pressVehicleButton) == "function")
                
                -- Use updated player_cache for debug messages
                if type(player_cache) ~= "table" then player_cache = {} end
                for p_id_pulse, p_data in pairs(player_cache) do
                    if p_data.vehicle == pulse.vehicle_id then
                        if not pulse_processed_for_player_debug then
                            local status_msg = can_call_pressvehiclebutton_debug and "Attempting momentary press." or "ERROR: pressVehicleButton NOT AVAILABLE."
                            local debug_msg_content = string_format("Veh:%d, Btn:%s, Sched:%d, Now:%d, FuncType:%s. %s",
                                pulse.vehicle_id, pulse.button_name,
                                pulse.action_time, now_ms, press_button_func_type_dbg, status_msg)
                            server.announce("[PULSE EXEC]", debug_msg_content, p_id_pulse)
                            pulse_processed_for_player_debug = true
                        end
                    end
                end
            end

            local can_call_pressvehiclebutton = (server and type(server.pressVehicleButton) == "function")
            if can_call_pressvehiclebutton then
                if pressVehicleButton_is_broken then 
                    server.announce("[Morse Pulse System]", "server.pressVehicleButton is NOW AVAILABLE again.", -1)
                    pressVehicleButton_is_broken = false
                end
                server.pressVehicleButton(pulse.vehicle_id, pulse.button_name)
            else
                if not pressVehicleButton_is_broken then 
                    local press_button_func_type_error = "nil"
                    if server and server.pressVehicleButton then press_button_func_type_error = type(server.pressVehicleButton) end
                    local error_msg_content = string_format("CRITICAL: server.pressVehicleButton is %s. Button pulsing will be disabled. First detected for Veh:%d, Btn:%s",
                        press_button_func_type_error, pulse.vehicle_id, pulse.button_name)
                    server.announce("[Morse Pulse Error]", error_msg_content, -1)
                    pressVehicleButton_is_broken = true 
                end
            end
            table_remove(morse_button_pulses, k) 
        end
    end
end

-- Schedules the sequence of button presses on a target vehicle to transmit Morse code.
-- @param target_vehicle_id: The vehicle_id to send pulses to.
-- @param morse_code_string: The Morse code to transmit.
-- @param translated_text: The plain text translation of the Morse code.
-- @param sender_name_for_display: Name of the original sender.
-- @param original_sender_pid: Peer_id of the original sender.
-- @param original_sender_vehicle_id: Vehicle_id of the original sender.
-- @param channel_for_display: The Morse channel the message is on.
-- @param command_start_time: The server time (ms) when the send command was initiated.
-- @return number: The total duration (ms) of the scheduled Morse pulse sequence.
local function scheduleMorsePulses(target_vehicle_id, morse_code_string, translated_text, sender_name_for_display, original_sender_pid, original_sender_vehicle_id, channel_for_display, command_start_time)
    if not is_initialized then return 0 end
    if not target_vehicle_id then if debug_echo then server.announce("[PulseDBG Adm]", "scheduleMorsePulses called with nil target_vehicle_id.", -1) end return 0 end

    -- GUARD: ensure morse_button_pulses is a table before inserting
    if type(morse_button_pulses) ~= "table" then morse_button_pulses = {} end

    if debug_echo then
        server.announce("[PulseDBG Adm]", "scheduleMorsePulses for VehID: " .. target_vehicle_id .. ", SenderVeh: " .. tostring(original_sender_vehicle_id) .. ", Morse: [" .. morse_code_string .. "] relative to " .. command_start_time .. " from P" .. original_sender_pid, -1)
    end

    local final_pulse_offset_ms = 0         
    local original_pulse_count = #morse_button_pulses 
    local current_scheduling_offset_ms = 0  

    for i = 1, #morse_code_string do
        local char = string_sub(morse_code_string, i, i)
        local button_to_pulse = nil
        local signal_time_advance = 0

        if char == '.' then 
            button_to_pulse = "mdot" 
            signal_time_advance = DOT_TIME_MS
        elseif char == '-' then 
            button_to_pulse = "mdash" 
            signal_time_advance = DASH_TIME_MS
        elseif char == ' ' then 
            current_scheduling_offset_ms = current_scheduling_offset_ms + INTER_CHAR_SPACE_MS
        elseif char == '/' then 
            current_scheduling_offset_ms = current_scheduling_offset_ms + WORD_SPACE_MS
        end

        if button_to_pulse then
            table_insert(morse_button_pulses, {
                vehicle_id = target_vehicle_id,
                button_name = button_to_pulse,
                action_time = command_start_time + current_scheduling_offset_ms 
            })
            current_scheduling_offset_ms = current_scheduling_offset_ms + signal_time_advance 

            if i < #morse_code_string then
                local next_char_in_string = string_sub(morse_code_string, i + 1, i + 1)
                if next_char_in_string ~= ' ' and next_char_in_string ~= '/' then
                    current_scheduling_offset_ms = current_scheduling_offset_ms + INTRA_CHAR_SPACE_MS
                end
            end
        end
    end
    final_pulse_offset_ms = current_scheduling_offset_ms 

    -- OPTIMIZATION: Sort pulses after bulk insert (GUARD against non-table)
    if type(morse_button_pulses) == "table" then
        table.sort(morse_button_pulses, function(a, b) return a.action_time < b.action_time end)
    else
        morse_button_pulses = {}
    end

    if debug_echo then
        local new_pulses_generated = #morse_button_pulses - original_pulse_count
        server.announce("[PulseDBG Adm]", "Generated " .. new_pulses_generated .. " pulse actions for VehID: " .. target_vehicle_id .. ". Total pulse queue: " .. #morse_button_pulses, -1)
    end

    if type(pending_morse_text_displays) ~= "table" then pending_morse_text_displays = {} end

    table_insert(pending_morse_text_displays, {
        is_recipient_message        = true,
        vehicle_id                  = target_vehicle_id, 
        original_sender_pid         = original_sender_pid,
        sender_vehicle_id_original  = original_sender_vehicle_id, 
        message_start_time_original = command_start_time,
        morse_to_display            = morse_code_string,
        text_to_display             = translated_text,
        sender_name_for_display     = sender_name_for_display,
        channel_for_display         = channel_for_display,
        stage                       = "incoming", 
        pulses_end_time_ms          = command_start_time + final_pulse_offset_ms, 
        text_display_time_ms        = 0, 
        incoming_announced          = false 
    })

    if debug_echo then
        server.announce("[PulseDBG Adm]", "Queued recipient display for VehID: " .. target_vehicle_id .. ". Pulses end at " .. (command_start_time + final_pulse_offset_ms) .. ". Display queue: " .. #pending_morse_text_displays, -1)
    end

    return final_pulse_offset_ms 
end

-- Adds a message to the specified channel's log.
-- @param channel_id_val: The channel number to log to.
-- @param sender_pid: Peer_id of the sender.
-- @param sender_name: Name of the sender.
-- @param sender_vehicle_id: Vehicle_id of the sender.
-- @param text: The translated plain text of the message.
-- @param morse_code: The raw Morse code of the message.
-- @param message_start_time: Server time (ms) when the message transmission started.
-- @param message_duration_ms: Total duration (ms) of the Morse transmission.
local function logToChannel(channel_id_val, sender_pid, sender_name, sender_vehicle_id, text, morse_code, message_start_time, message_duration_ms)
    if not is_initialized then return end
    if not channel_id_val or channel_id_val == 0 then 
        if debug_echo then server.announce("[Morse LOG]", "Attempted to log to channel 0 or nil channel. Logging skipped.", -1) end 
        return 
    end

    if type(channel_logs) ~= "table" then channel_logs = {} end
    channel_logs[channel_id_val] = channel_logs[channel_id_val] or {} 
    local log = channel_logs[channel_id_val]
    local log_entry_time = server.getTimeMillisec() 

    table_insert(log, {
        when                        = log_entry_time, 
        sender_pid                  = sender_pid,
        sender_name                 = sender_name,
        sender_vehicle_id           = sender_vehicle_id, 
        text                        = text,
        morse                       = morse_code,
        pulse_duration              = message_duration_ms, 
        pulse_expected_end_time     = message_start_time + message_duration_ms 
    })

    if #log > LOG_LIMIT then
        table_remove(log, 1) 
    end
end

-- Handler for the ?msgs command. Shows the latest received message to the player.
-- @param pid: The peer_id of the player issuing the command.
local function showLatestReceived(pid)
    if not is_initialized then return end
    if not pid then if debug_echo then server.announce("[Morse CMD]", "?msgs called with nil pid.", -1) end return end
    execute_show_latest_received_logic(pid) 
    display_commands(pid)                 
end

--=========================================================================  
--  Stormworks Event Handler: onPlayerSit
--  Called when a player sits in a vehicle seat.
--=========================================================================  
function onPlayerSit(peer_id, vehicle_id, seat_name)
    if not is_initialized then return end
    if not peer_id then if debug_echo then server.announce("[Morse Event]", "onPlayerSit event with nil peer_id.", -1) end return end
    if not vehicle_id then if debug_echo then server.announce("[Morse Event]", "onPlayerSit event with nil vehicle_id for P"..peer_id, -1) end return end

    -- GUARD: ensure seat_occupants and related tables exist
    if type(seat_occupants) ~= "table" then seat_occupants = {} end
    if type(player_to_vehicle) ~= "table" then player_to_vehicle = {} end
    if type(radioman_players) ~= "table" then radioman_players = {} end
    if type(player_cache) ~= "table" then player_cache = {} end
    if type(vehicle_virtual_channel) ~= "table" then vehicle_virtual_channel = {} end
    if type(player_addon_enabled) ~= "table" then player_addon_enabled = {} end
    if type(pending_morse_text_displays) ~= "table" then pending_morse_text_displays = {} end

    init_player_state(peer_id)

    -- Preserve previous vehicle's channel if player was in another vehicle
    local old_vehicle = player_to_vehicle[peer_id]
    local old_channel = nil
    if old_vehicle and type(vehicle_virtual_channel) == "table" then
        old_channel = vehicle_virtual_channel[old_vehicle]
    end

    seat_name = (seat_name or ""):lower() 

    if debug_echo then
        server.announce("[Morse DBG Sit]", "onPlayerSit: Storing P" .. peer_id .. " (Type: " .. type(peer_id) .. ") in Veh" .. vehicle_id .. " Seat '" .. seat_name .. "'", -1)
    end

    -- Update seat occupants
    seat_occupants[vehicle_id] = seat_occupants[vehicle_id] or {}
    if type(seat_occupants[vehicle_id]) ~= "table" then seat_occupants[vehicle_id] = {} end
    seat_occupants[vehicle_id][seat_name] = peer_id
    
    -- OPTIMIZATION: Update lookup tables
    player_to_vehicle[peer_id] = vehicle_id
    if seat_name == "radioman" then
        radioman_players[peer_id] = true
    end

    -- If new vehicle has no channel yet, inherit old channel (if any)
    if not vehicle_virtual_channel[vehicle_id] and old_channel and old_channel ~= 0 then
        vehicle_virtual_channel[vehicle_id] = old_channel
    end

    -- UPDATE player_cache entry for this player
    local current_channel = DEFAULT_CHANNEL
    if type(vehicle_virtual_channel) == "table" and vehicle_virtual_channel[vehicle_id] then
        current_channel = vehicle_virtual_channel[vehicle_id]
    end
    player_cache[peer_id] = {
        vehicle    = vehicle_id,
        channel    = current_channel,
        enabled    = player_addon_enabled[peer_id] or true,
        is_radioman= (seat_name == "radioman"),
        name       = getPlayerName(peer_id)
    }

    if seat_name == "radioman" then
        -- Check receive depth limit before showing messages
        local dial_name = RADIO_DEPTH_DIAL_NAME
        local depth_result = server.getVehicleDial(vehicle_id, dial_name)
        local depth_value, depth_success = nil, false
        if type(depth_result) == "table" then
            if type(depth_result.value) == "number" then
                depth_value = depth_result.value
                depth_success = true
            elseif type(depth_result[1]) == "number" then
                depth_value = depth_result[1]
                depth_success = true
            else
                depth_success = false
            end
        else
            if type(depth_result) == "number" then
                depth_value = depth_result
                depth_success = true
            end
        end

        if depth_success and depth_value > MAX_RECEIVE_DEPTH then
            server.announce("[Morse]", "Too Deep To Send or RECV Messages", peer_id)
        else
            if type(pending_morse_text_displays) ~= "table" then pending_morse_text_displays = {} end
            table_insert(pending_morse_text_displays, {
                is_deferred_sit_display = true,
                target_pid              = peer_id,
                display_time_ms         = server.getTimeMillisec() 
            })
            -- Immediately show in-progress or new incoming if it exists
            execute_show_latest_received_logic(peer_id)
            display_commands(peer_id)
        end
    end
end

--=========================================================================  
--  Stormworks Event Handler: onCharacterUnsit
--  Called when a character (which could be a player) unsits from a seat.
--=========================================================================  
function onCharacterUnsit(character_id, vehicle_id_event, seat_name_event)
    if not is_initialized then return end
    if not character_id then if debug_echo then server.announce("[Morse Event]", "onCharacterUnsit event with nil character_id.", -1) end return end

    -- GUARD: ensure seat_occupants exists
    if type(seat_occupants) ~= "table" then seat_occupants = {} end

    if debug_echo then
        server.announce("[Morse DBG Unsit Start]", "onCharacterUnsit called. CharID_event: " .. character_id .. ", VehID_event: " .. (vehicle_id_event or "nil") .. ", Seat_event: " .. (seat_name_event or "nil"), -1)
    end

    local peer_id_unsitting = nil
    local all_players_unsit = server.getPlayers()
    if type(all_players_unsit) == "table" then
        for _, p_info in pairs(all_players_unsit) do
            if p_info and p_info.id and server.getPlayerCharacterID(p_info.id) == character_id then
                peer_id_unsitting = p_info.id
                break
            end
        end
    end

    if not peer_id_unsitting then
        if debug_echo then
            server.announce("[Morse DBG Unsit PeerNotFound]", "Could not find peer_id for char_id: " .. character_id .. ". This can happen for NPCs.", -1)
        end
        return 
    end

    if debug_echo then
        server.announce("[Morse DBG Unsit FoundPeer]", "Found peer_id_unsitting: " .. peer_id_unsitting .. " (Type: " .. type(peer_id_unsitting) .. ") for CharID " .. character_id, -1)
    end

    -- OPTIMIZATION: Update lookup tables
    if type(player_to_vehicle) ~= "table" then player_to_vehicle = {} end
    player_to_vehicle[peer_id_unsitting] = nil
    if type(radioman_players) ~= "table" then radioman_players = {} end
    radioman_players[peer_id_unsitting] = nil

    -- REMOVE from player_cache
    if type(player_cache) == "table" then
        player_cache[peer_id_unsitting] = nil
    end

    local vehicles_to_check_for_emptiness = {} 
    for v_id, seats_in_seat in pairs(seat_occupants) do
        if type(seats_in_seat) == "table" then
            local vehicle_modified_this_iteration = false
            for seat_n, occupant_pid_in_seat in pairs(seats_in_seat) do
                if occupant_pid_in_seat == peer_id_unsitting then
                    if debug_echo then
                        server.announce("[Morse DBG Unsit Clearing]", "Attempting to clear P" .. occupant_pid_in_seat .. " from Veh" .. v_id .. " Seat '" .. seat_n .. "'", -1)
                    end
                    seat_occupants[v_id][seat_n] = nil 
                    vehicle_modified_this_iteration = true
                end
            end
            if vehicle_modified_this_iteration then
                vehicles_to_check_for_emptiness[v_id] = true
            end
        end
    end

    for v_id_to_check, _ in pairs(vehicles_to_check_for_emptiness) do
        if seat_occupants[v_id_to_check] then
            local is_vehicle_entry_empty = true
            for _, occupant_check in pairs(seat_occupants[v_id_to_check]) do
                if occupant_check ~= nil then
                    is_vehicle_entry_empty = false
                    break
                end
            end
            if is_vehicle_entry_empty then
                if debug_echo then
                    server.announce("[Morse DBG Unsit EmptyVeh]", "Vehicle entry for Veh" .. v_id_to_check .. " is now empty of occupants, but KEPT in seat_occupants for future pulsing.", -1)
                end
            else
                if debug_echo then
                     server.announce("[Morse DBG Unsit NotEmptyVeh]", "Vehicle entry for Veh" .. v_id_to_check .. " still has occupants.", -1)
                end
            end
        end
    end
end

-- Handles the ?m <morse_code> command to send a Morse message.
-- @param pid: The peer_id of the player sending the message.
-- @param payload: The Morse code string input by the player.
local function handleMorseCommand(pid, payload)
    if not is_initialized then server.announce("[Morse]", "Addon not yet initialized. Please wait.", pid); return end
    if not pid then if debug_echo then server.announce("[Morse CMD]", "?m called with nil pid.", -1) end return end

    local current_channel_val, id_prefix = getPlayerCurrentChannelAndPrefix(pid) 
    local is_sender_radioman = isPlayerRadioman(pid)
    local sender_vehicle_id = getPlayerVehicle(pid)
    local command_start_time = server.getTimeMillisec() 

    if not is_sender_radioman then server.announce("[Morse]", "Sit in radioman seat to send messages!", pid); return end
    if not sender_vehicle_id then server.announce("[Morse Error]", "Could not determine your vehicle to send message.", pid); return end

    -- Check send depth limit before sending messages
    local depth_result = server.getVehicleDial(sender_vehicle_id, RADIO_DEPTH_DIAL_NAME)
    local depth_value, depth_success = nil, false
    if type(depth_result) == "table" then
        if type(depth_result.value) == "number" then
            depth_value = depth_result.value
            depth_success = true
        elseif type(depth_result[1]) == "number" then
            depth_value = depth_result[1]
            depth_success = true
        end
    else
        if type(depth_result) == "number" then
            depth_value = depth_result
            depth_success = true
        end
    end

    if depth_success and depth_value > MAX_SEND_DEPTH then
        server.announce("[Morse]", "Too Deep", pid)
        return
    end

    if current_channel_val == 0 then
        server.announce("[Morse Error]", "Channel 0 is disabled. Please set a channel (1-999) using ?morse_channel or by pressing the 'setTelegraph' button on your vehicle.", pid)
        display_commands(pid)
        return
    end

    if debug_echo then
        local radioman_occupant_pid_str = "not_found_or_nil"; local radioman_occupant_type_str = "not_found_or_nil"
        if sender_vehicle_id and type(seat_occupants) == "table" and type(seat_occupants[sender_vehicle_id]) == "table" and seat_occupants[sender_vehicle_id]["radioman"] then
            local occupant = seat_occupants[sender_vehicle_id]["radioman"]; radioman_occupant_pid_str = tostring(occupant); radioman_occupant_type_str = type(occupant)
        end
        server.announce("[Morse Pre-Check]", string_format("P%d(Name:%s, Type:%s): isRadiomanResult=%s, CurrentVehID=%s, EffectiveCh=%s (Prefix:%s). RadiomanSeatVal=%s (Type:%s) @ %d", pid, getPlayerName(pid), type(pid), tostring(is_sender_radioman), tostring(sender_vehicle_id or "nil"), tostring(current_channel_val), id_prefix, radioman_occupant_pid_str, radioman_occupant_type_str, command_start_time), pid)
    end

    local sender_name = getPlayerName(pid)
    local morse_input, translated_text

    if payload ~= "" and isValidMorsePattern(payload) then
        morse_input = payload
        translated_text = morseToText(payload)
    else
        server.announce("[Morse Error]", "Invalid input. Message not sent. Please use only '.', '-', '/', and spaces.", pid)
        display_commands(pid)
        return
    end

    local outgoing_tag = "[Ch:" .. current_channel_val .. " Outgoing]"
    server.announce(outgoing_tag, morse_input, pid)
    server.announce(outgoing_tag, "Sending Message...", pid) 

    -- OPTIMIZED: Calculate morse duration inline
    local message_total_duration_ms_for_log = 0
    for k_idx = 1, #morse_input do
        local char_k = string_sub(morse_input, k_idx, k_idx)
        local sig_time_adv = 0
        if char_k == '.' then sig_time_adv = DOT_TIME_MS
        elseif char_k == '-' then sig_time_adv = DASH_TIME_MS
        elseif char_k == ' ' then message_total_duration_ms_for_log = message_total_duration_ms_for_log + INTER_CHAR_SPACE_MS
        elseif char_k == '/' then message_total_duration_ms_for_log = message_total_duration_ms_for_log + WORD_SPACE_MS end
        if sig_time_adv > 0 then
            message_total_duration_ms_for_log = message_total_duration_ms_for_log + sig_time_adv
            if k_idx < #morse_input then
                local next_c = string_sub(morse_input, k_idx + 1, k_idx + 1)
                if next_c ~= ' ' and next_c ~= '/' then 
                    message_total_duration_ms_for_log = message_total_duration_ms_for_log + INTRA_CHAR_SPACE_MS 
                end
            end
        end
    end

    logToChannel(current_channel_val, pid, sender_name, sender_vehicle_id, translated_text, morse_input, command_start_time, message_total_duration_ms_for_log)

    if debug_echo then server.announce("[PulseDBG Sender]", "Processing receivers for morse pulses & text...", pid) end

    local vehicles_to_pulse_map = {}          
    local players_to_get_raw_morse_text_map = {} 

    if debug_echo then server.announce("[PulseDBG Sender]", "Targeting ALL known vehicles (from seat_occupants) for button pulses.", pid) end
    if type(seat_occupants) == "table" then
        for veh_id_known, _ in pairs(seat_occupants) do
            if veh_id_known then vehicles_to_pulse_map[veh_id_known] = true end
        end
    end

    -- FIX: Must use server.getPlayers() here, not player_cache (which only exists in onTick)
    local all_players_in_command = server.getPlayers()
    if type(all_players_in_command) == "table" then
        for _, p_info in pairs(all_players_in_command) do
            local p_id_iter = p_info.id
            if p_id_iter then
                local iter_player_channel, _ = getPlayerCurrentChannelAndPrefix(p_id_iter) 

                local is_on_sender_channel = (iter_player_channel == current_channel_val) and (current_channel_val ~= 0) 
                local is_addon_enabled_for_iter_player = player_addon_enabled[p_id_iter] 
                local iter_player_vehicle_id = getPlayerVehicle(p_id_iter)
                local is_iter_player_radioman = isPlayerRadioman(p_id_iter)
                local text_action_msg = ""

                if is_on_sender_channel and is_addon_enabled_for_iter_player and p_id_iter ~= pid then 
                    if iter_player_vehicle_id and is_iter_player_radioman then
                        text_action_msg = "Eligible for staged display (radioman in other veh)."
                        -- Note: Staged display is handled elsewhere, not here
                    elseif not iter_player_vehicle_id then
                        -- FIX: Players NOT in vehicles should NOT get messages
                        text_action_msg = "Not in vehicle - no messages."
                    else
                        -- Player is in a vehicle but not radioman
                        text_action_msg = "In vehicle but not radioman - no messages."
                    end
                elseif p_id_iter == pid then
                    text_action_msg = "Is sender."
                else
                    text_action_msg = "Channel/Addon check FAILED for raw text or staged display."
                end
                if debug_echo then
                    local debug_player_info = string_format("        P%d(%s): EffectiveCh=%s, OnSenderChOK=%s, AddonOK=%s, InVeh=%s, IsRadio=%s.", p_id_iter, getPlayerName(p_id_iter), tostring(iter_player_channel), tostring(is_on_sender_channel), tostring(is_addon_enabled_for_iter_player), tostring(iter_player_vehicle_id or "nil"), tostring(is_iter_player_radioman))
                    server.announce("[PulseDBG Sender]", debug_player_info .. " -> " .. text_action_msg, pid)
                end
            end
        end
    end

    -- FIX: Remove the section that sends messages to players not in vehicles
    -- This entire block should be removed or only send to radiomen
    if debug_echo then
        local raw_morse_count = 0
        if type(players_to_get_raw_morse_text_map) == "table" then
            for _ in pairs(players_to_get_raw_morse_text_map) do
                raw_morse_count = raw_morse_count + 1
            end
        end
        if raw_morse_count > 0 then
            server.announce("[PulseDBG Sender]", "WARNING: " .. raw_morse_count .. " players would have received raw morse without being in radioman seat (now blocked)", pid)
        end
    end
    -- REMOVED: The actual sending of messages to non-radioman players

    local pulse_targets_summary_msg = "Vehicles scheduled for pulses & staged display: "
    local actual_pulse_targets_count = 0
    local message_total_duration_ms_from_schedule = 0 

    for vehicle_id_to_pulse, _ in pairs(vehicles_to_pulse_map) do
        local duration_for_this_vehicle = scheduleMorsePulses(vehicle_id_to_pulse, morse_input, translated_text, sender_name, pid, sender_vehicle_id, current_channel_val, command_start_time)
        message_total_duration_ms_from_schedule = math_max(message_total_duration_ms_from_schedule, duration_for_this_vehicle)
        if debug_echo then pulse_targets_summary_msg = pulse_targets_summary_msg .. vehicle_id_to_pulse .. " " end
        actual_pulse_targets_count = actual_pulse_targets_count + 1
    end

    if actual_pulse_targets_count > 0 then
        if type(pending_morse_text_displays) ~= "table" then pending_morse_text_displays = {} end
        table_insert(pending_morse_text_displays, {
            is_sender_confirmation = true,
            target_pid             = pid,
            tag_text               = "[Ch:" .. current_channel_val .. " Outgoing]",
            body_text              = "Message Sent...",
            display_time_ms        = command_start_time + message_total_duration_ms_from_schedule 
        })
        if debug_echo then server.announce("[PulseDBG Sender]", "Sender confirmation 'Message Sent' queued for " .. (command_start_time + message_total_duration_ms_from_schedule), pid) end
    elseif debug_echo then
        server.announce("[PulseDBG Sender]", "No vehicles targeted by seat_occupants. 'Message Sent' confirmation not queued based on pulse duration.", pid)
    end

    if debug_echo then
        if actual_pulse_targets_count == 0 then pulse_targets_summary_msg = pulse_targets_summary_msg .. "None (seat_occupants empty or no vehicles known)." end
        server.announce("[PulseDBG Sender]", pulse_targets_summary_msg, pid)
    end
end

-- Handles the ?mveh command to list known vehicles and player eligibility for messages.
-- @param pid_issuer: The peer_id of the player issuing the command.
local function handleListMorseVehicles(pid_issuer)
    if not is_initialized then server.announce("[Morse]", "Addon not yet initialized. Please wait.", pid_issuer); return end
    if not pid_issuer then if debug_echo then server.announce("[Morse CMD]", "?mveh called with nil pid_issuer.", -1) end return end
   
    local issuer_channel, issuer_prefix = getPlayerCurrentChannelAndPrefix(pid_issuer)

    if issuer_channel == 0 then
        server.announce("[Morse Veh List]", "Channel 0 is disabled. Set a channel (1-999) to list vehicle eligibility.", pid_issuer)
        return
    end
    if not issuer_channel then server.announce("[Morse Veh List]", "Could not determine your current channel.", pid_issuer); return end

    server.announce("[Morse Veh List]", "--- Vehicles known to script (via seat_occupants) ---", pid_issuer)
    local known_vehicles_from_seats = {}
    local total_known_vehicles = 0

    -- GUARD: ensure seat_occupants is a table
    if type(seat_occupants) ~= "table" then seat_occupants = {} end

    for veh_id, seats in pairs(seat_occupants) do
        if veh_id and type(seats) == "table" then
            total_known_vehicles = total_known_vehicles + 1
            known_vehicles_from_seats[veh_id] = { occupants_details = {} }
            for seat_name, player_id_in_seat in pairs(seats) do
                if player_id_in_seat then
                    table_insert(known_vehicles_from_seats[veh_id].occupants_details, getPlayerName(player_id_in_seat) .. " (in " .. seat_name .. ")")
                end
            end
        end
    end

    if total_known_vehicles == 0 then
        server.announce("[Morse Veh List]", "No vehicles currently known to seat_occupants. These vehicles would not be pulsed.", pid_issuer)
    else
        server.announce("[Morse Veh List]", "The following " .. total_known_vehicles .. " vehicle(s) are known via seat_occupants and WILL BE TARGETED FOR PULSES & staged display if you send a message:", pid_issuer)
        for veh_id, data in pairs(known_vehicles_from_seats) do
            local occupants_str = #data.occupants_details > 0 and table_concat(data.occupants_details, ", ") or "No listed occupants in seat_occupants"
            server.announce("[Morse Veh List]", "    VehID: " .. veh_id .. " - Known Occupants (from seat_occupants): " .. occupants_str, pid_issuer)
        end
    end

    server.announce("[Morse Veh List]", "--- Staged text display eligibility for players in those vehicles (on your effective channel " .. issuer_channel .. " with prefix " .. issuer_prefix .. "):", pid_issuer)
    if total_known_vehicles > 0 then
        -- FIX: Must use server.getPlayers() here, not player_cache
        local all_players_in_list_cmd = server.getPlayers()
        if type(all_players_in_list_cmd) == "table" then
            for veh_id_check, _ in pairs(known_vehicles_from_seats) do
                local players_in_this_vehicle_for_text_display = {}
                for _, p_info_scan in pairs(all_players_in_list_cmd) do
                    local p_id_scan = p_info_scan.id
                    if p_id_scan then
                        local p_scan_channel, _ = getPlayerCurrentChannelAndPrefix(p_id_scan)
                        if getPlayerVehicle(p_id_scan) == veh_id_check then 
                            if p_scan_channel == issuer_channel and player_addon_enabled[p_id_scan] and p_scan_channel ~= 0 then
                                local detail = getPlayerName(p_id_scan)
                                if isPlayerRadioman(p_id_scan) then
                                    detail = detail .. " (Radioman - gets full staged display)"
                                else
                                    detail = detail .. " (On Ch - no staged display, not radioman)"
                                end
                                table_insert(players_in_this_vehicle_for_text_display, detail)
                            end
                        end
                    end
                end
                local player_list_str = #players_in_this_vehicle_for_text_display > 0 and table_concat(players_in_this_vehicle_for_text_display, "; ") or "None on your channel/addon enabled in this vehicle."
                server.announce("[Morse Veh List]", "    VehID: " .. veh_id_check .. " - Players for staged display: " .. player_list_str, pid_issuer)
            end
        end
    else
        server.announce("[Morse Veh List]", "No known vehicles to check for staged display eligibility.", pid_issuer)
    end
end

-- Handles ?mprev and ?mnext commands to navigate and display message logs.
-- @param pid: The peer_id of the player.
-- @param step: Integer, -1 for previous, 1 for next message in log.
local function showLog(pid, step)
    if not is_initialized then server.announce("[Morse]", "Addon not yet initialized. Please wait.", pid); return end
    if not pid then if debug_echo then server.announce("[Morse CMD]", "showLog called with nil pid.", -1) end return end

    local current_channel_val, id_prefix = getPlayerCurrentChannelAndPrefix(pid) 
    local viewing_vehicle_id = getPlayerVehicle(pid)

    if not isPlayerRadioman(pid) then server.announce("[Message Logs]", "Radioman seat required!", pid); display_commands(pid); return end
   
    if current_channel_val == 0 then
        server.announce("[Message Logs]", "Channel 0 is disabled. Cannot view logs. Set a channel (1-999).", pid)
        display_commands(pid)
        return
    end
    if current_channel_val == nil then server.announce("[Message Logs]", "Unable to determine your current morse channel. Critical error.", pid); display_commands(pid); return end

    if type(channel_logs) ~= "table" then channel_logs = {} end
    channel_logs[current_channel_val] = channel_logs[current_channel_val] or {}
    local current_channel_log = channel_logs[current_channel_val]

    if #current_channel_log == 0 then server.announce("[Message Logs]", "No messages on Ch:" .. current_channel_val, pid); display_commands(pid); return end

    if type(player_log_cursor) ~= "table" then player_log_cursor = {} end
    player_log_cursor[pid] = player_log_cursor[pid] or {}
    local current_cursor_val = player_log_cursor[pid][current_channel_val]

    if not current_cursor_val or current_cursor_val < 1 or current_cursor_val > #current_channel_log then
        current_cursor_val = #current_channel_log
    end

    if step then
        current_cursor_val = math_min(#current_channel_log, math_max(1, current_cursor_val + step))
    end
    player_log_cursor[pid][current_channel_val] = current_cursor_val 

    local entry = current_channel_log[current_cursor_val] 
    local display_prefix_chat = "[Log Ch:" .. current_channel_val .. " " .. current_cursor_val .. "/" .. #current_channel_log .. "]"

    if type(fmtChannelEntry) ~= "function" then 
        if debug_echo then
            server.announce("[Morse CRITICAL DIAG]", "showLog: fmtChannelEntry is NOT a function! Type: " .. type(fmtChannelEntry), pid)
        end
        if entry and entry.text then server.announce(display_prefix_chat, "Raw: " .. entry.text, pid)
        elseif entry then server.announce(display_prefix_chat, "Raw entry (no text field or formatting failed)", pid)
        else server.announce(display_prefix_chat, "Entry not found or formatting failed.", pid) end
    elseif entry then
        local current_time_showlog = server.getTimeMillisec()
        if entry.pulse_expected_end_time and current_time_showlog < entry.pulse_expected_end_time then
            local time_remaining_ms = entry.pulse_expected_end_time - current_time_showlog
            local time_str_log = format_timestamp_hhmm(entry.when or 0)
            local body = string_format("%s Receiving from %s%s (Completes in %.1fs)",
                time_str_log,
                id_prefix, 
                tostring(entry.sender_vehicle_id or "N/A"),
                time_remaining_ms / 1000
            )
            server.announce(display_prefix_chat, body, pid)
            queue_log_follow_up(pid, entry, current_channel_val, display_prefix_chat) 
        else
            server.announce(display_prefix_chat, fmtChannelEntry(entry, viewing_vehicle_id, current_time_showlog, id_prefix), pid)
        end
    else
        server.announce("[Message Logs]", "Log data inconsistent. Cursor: " .. current_cursor_val .. ", Log size: " .. #current_channel_log, pid)
    end

    display_commands(pid) 
end

-- Toggles the global debug_echo flag.
-- @param pid: The peer_id of the player issuing the command (for announcement).
local function toggleDebug(pid)
    if not is_initialized then server.announce("[Morse]", "Addon not yet initialized. Please wait.", pid); return end
    if not pid then if debug_echo then server.announce("[Morse CMD]", "toggleDebug called with nil pid.", -1) end return end
    debug_echo = not debug_echo
    server.announce("[Debug]", "Echo " .. (debug_echo and "ON" or "OFF"), pid)
end

-- Handles configuration commands like setting channel or toggling addon.
-- @param pid: The peer_id of the player.
-- @param cmd: The command string (e.g., "?morse_channel").
-- @param args: A table of arguments for the command.
local function handleConfigurationCommand(pid, cmd, args)
    if not is_initialized then server.announce("[Morse]", "Addon not yet initialized. Please wait.", pid); return end
    if not pid then if debug_echo then server.announce("[Morse CMD]", "handleConfigurationCommand called with nil pid for cmd: ".. (cmd or "nil"), -1) end return end
   
    init_player_state(pid) 

    if cmd == "?mdebug" then toggleDebug(pid); return end 
    -- '?setTelegraph' is no longer a chat command handled here.

    if not isPlayerRadioman(pid) then server.announce("[Message Logs]", "Radioman seat first!", pid); return end

    if cmd == "?morse_channel" then
        local n = tonumber(args[1])
        if n and n >= 1 and n <= 999 then 
            local veh_id = player_to_vehicle[pid]
            if veh_id then
                if type(vehicle_virtual_channel) ~= "table" then vehicle_virtual_channel = {} end
                vehicle_virtual_channel[veh_id] = n
                if type(player_log_cursor) ~= "table" then player_log_cursor = {} end
                player_log_cursor[pid] = player_log_cursor[pid] or {}
                player_log_cursor[pid][n] = nil -- Reset log cursor for the new channel
                -- UPDATE player_cache channel for every occupant in that vehicle
                if type(seat_occupants) == "table" and seat_occupants[veh_id] then
                    for _, occupant_pid in pairs(seat_occupants[veh_id]) do
                        if occupant_pid and type(player_cache) == "table" and player_cache[occupant_pid] then
                            player_cache[occupant_pid].channel = n
                        end
                    end
                end
                local message = "Morse Channel for Vehicle " .. veh_id .. " set to " .. n .. ". Log cursor reset."
                server.announce("Morse Channel", message, pid)
            else
                server.announce("Morse Channel", "Error: Could not determine your vehicle. Channel not set.", pid)
            end
        else
            server.announce("Morse Channel", "Invalid channel (1-999).", pid)
        end
    elseif cmd == "?morse_toggle" then
        player_addon_enabled[pid] = not player_addon_enabled[pid]
        -- UPDATE player_cache enabled
        if type(player_cache) == "table" and player_cache[pid] then
            player_cache[pid].enabled = player_addon_enabled[pid]
        end
        server.announce("Morse Addon", "Processing: " .. (player_addon_enabled[pid] and "ON" or "OFF"), pid)
    end
    display_commands(pid) 
end

--=========================================================================  
--  Stormworks Event Handler: onChatMessage
--  Called when a player sends a chat message.
--=========================================================================  
function onChatMessage(pid, sender_name, msg)
    if not is_initialized then return end 
    if not pid then if debug_echo then server.announce("[Morse Event]", "onChatMessage event with nil pid.", -1) end return end
   
    init_player_state(pid) 

    if string_sub(msg, 1, 1) == "?" and debug_echo then server.announce("[Debug CMD]", msg, pid) end

    if player_addon_enabled[pid] == nil then player_addon_enabled[pid] = true end 
    if not player_addon_enabled[pid] and string_lower(msg) ~= "?morse_toggle" and string_lower(msg) ~= "?mdebug" then
        return
    end

    local cmd_lower = string_lower(msg)
    if string_sub(msg, 1, 3) == "?m " then handleMorseCommand(pid, trim(string_sub(msg, 4)))
    elseif cmd_lower == "?msgs" then showLatestReceived(pid)
    elseif cmd_lower == "?mprev" then showLog(pid, -1)
    elseif cmd_lower == "?mnext" then showLog(pid, 1)
    elseif cmd_lower == "?mveh" then handleListMorseVehicles(pid)
    elseif cmd_lower == "?mdebug" then handleConfigurationCommand(pid, "?mdebug", {})
    -- '?setTelegraph' removed from chat commands
    elseif string_sub(msg, 1, 14):lower() == "?morse_channel" then handleConfigurationCommand(pid, "?morse_channel", split_by_spaces(string_sub(msg, 15)))
    elseif cmd_lower == "?morse_toggle" then handleConfigurationCommand(pid, "?morse_toggle", {})
    end
end

--=========================================================================  
--  Stormworks Event Handler: onCustomCommand
--  Called for commands sent via custom UI or other means (e.g., microcontroller).
--=========================================================================  
function onCustomCommand(game_id, pid, command, success, cmd_custom, ...)
    if not is_initialized then return end
    if not pid then if debug_echo then server.announce("[Morse Event]", "onCustomCommand event with nil pid for command: "..(cmd_custom or "nil"), -1) end return end
   
    init_player_state(pid)

    if player_addon_enabled[pid] == nil then player_addon_enabled[pid] = true end
    if not player_addon_enabled[pid] and cmd_custom ~= "?morse_toggle" and cmd_custom ~= "?mdebug" then
        return
    end

    local args_table = {...} 

    if cmd_custom == "?m" then handleMorseCommand(pid, trim(table_concat(args_table, " ")))
    elseif cmd_custom == "?msgs" then showLatestReceived(pid)
    elseif cmd_custom == "?mprev" then showLog(pid, -1)
    elseif cmd_custom == "?mnext" then showLog(pid, 1)
    elseif cmd_custom == "?mveh" then handleListMorseVehicles(pid)
    elseif cmd_custom == "?mdebug" then handleConfigurationCommand(pid, "?mdebug", {})
    -- '?setTelegraph' removed from custom commands
    elseif cmd_custom == "?morse_channel" then handleConfigurationCommand(pid, cmd_custom, args_table)
    elseif cmd_custom == "?morse_toggle" then handleConfigurationCommand(pid, cmd_custom, {})
    elseif cmd_custom == "?morse_test" then server.announce("[Morse Test]", "Addon active!", pid)
    end
end

--=========================================================================  
--  Stormworks Event Handler: onPlayerJoin
--  Called when a new player joins the server.
--=========================================================================  
function onPlayerJoin(steam_id, name, peer_id, is_admin, is_auth)
    if not is_initialized then return end 
    if not peer_id then if debug_echo then server.announce("[Morse Event]", "onPlayerJoin event with nil peer_id.", -1) end return end
   
    init_player_state(peer_id) 
    server.announce("[Morse Addon]", "Ready! You MUST sit in a radioman seat to send or receive messages. Vehicle channel defaults to 0 (disabled). Use ?morse_channel OR press 'setTelegraph' button on vehicle.", peer_id)
end

--=========================================================================  
--  Stormworks Event Handler: onButtonPress
--  Called when a vehicle button is pressed.
--=========================================================================  
-- Handles setting the channel when "setTelegraph" button is pressed.
-- @param vehicle_id: The ID of the vehicle where the button was pressed.
-- @param peer_id: The peer_id of the player who pressed the button.
-- @param button_name: The name of the button pressed.
-- @param is_pressed: Boolean, true if the button was pressed, false if released.
function onButtonPress(vehicle_id, peer_id, button_name, is_pressed)
    if not is_initialized or not is_pressed then return end -- Only act on press, not release
    if not peer_id then 
        if debug_echo then server.announce("[Morse Button]", "Button '".. (button_name or "nil") .."' pressed on Veh:" .. (vehicle_id or "nil") .. " but peer_id is nil.", -1) end
        return
    end

    init_player_state(peer_id)

    local btn_lower = string_lower(button_name or "")
    if btn_lower == "settelegraph" then
        if debug_echo then server.announce("[Morse Button]", "Player P" .. peer_id .. " pressed 'setTelegraph' on Veh:" .. vehicle_id, peer_id) end

        -- GUARD: ensure seat_occupants is a table before indexing
        local is_button_pusher_radioman_of_this_vehicle = false
        if type(seat_occupants) == "table" and type(seat_occupants[vehicle_id]) == "table" and seat_occupants[vehicle_id]["radioman"] == peer_id then
            is_button_pusher_radioman_of_this_vehicle = true
        end

        if not is_button_pusher_radioman_of_this_vehicle then
            server.announce("[Morse]", "You must be in the 'radioman' seat of this vehicle to use its 'setTelegraph' button.", peer_id)
            return
        end

        -- Attempt to read the "telegraph" dial
        local dial_name = "telegraph"
        local dial_result = server.getVehicleDial(vehicle_id, dial_name)
        local dial_value_raw
        local is_success = false

        -- If result is a table, attempt to extract numeric value
        if type(dial_result) == "table" then
            -- try common numeric fields
            if type(dial_result.value) == "number" then
                dial_value_raw = dial_result.value
                is_success = true
            elseif type(dial_result[1]) == "number" then
                dial_value_raw = dial_result[1]
                is_success = true
            else
                is_success = false
            end
        else
            -- if not a table, assume direct numeric return or nil
            dial_value_raw = dial_result
            if type(dial_value_raw) == "number" then
                is_success = true
            end
        end

        if is_success then
            local potential_dial_channel = math_floor(dial_value_raw)
            if potential_dial_channel >= 1 and potential_dial_channel <= 999 then
                if type(vehicle_virtual_channel) ~= "table" then vehicle_virtual_channel = {} end
                vehicle_virtual_channel[vehicle_id] = potential_dial_channel
                if type(player_log_cursor) ~= "table" then player_log_cursor = {} end
                player_log_cursor[peer_id] = player_log_cursor[peer_id] or {}
                player_log_cursor[peer_id][potential_dial_channel] = nil -- Reset log cursor for the new channel
                -- UPDATE player_cache channel for every occupant in that vehicle
                if type(seat_occupants) == "table" and seat_occupants[vehicle_id] then
                    for _, occupant_pid in pairs(seat_occupants[vehicle_id]) do
                        if occupant_pid and type(player_cache) == "table" and player_cache[occupant_pid] then
                            player_cache[occupant_pid].channel = potential_dial_channel
                        end
                    end
                end
                server.announce("[Morse Channel]", "Channel for Vehicle " .. vehicle_id .. " set to " .. potential_dial_channel .. " from 'telegraph' dial via vehicle button.", peer_id)
            else
                server.announce("[Morse Channel]", "Value from 'telegraph' dial (" .. tostring(dial_value_raw) .. ") is not a valid channel (1-999). Vehicle channel unchanged.", peer_id)
            end
        else
            server.announce("[Morse Channel]", "Dial '" .. dial_name .. "' not found or returned non-numeric value on this vehicle. Vehicle channel unchanged.", peer_id)
        end

        display_commands(peer_id) -- Show commands after attempting to set channel
    end
end
