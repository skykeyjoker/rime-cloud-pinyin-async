-- Asynchronous cloud pinyin for Windows Weasel.
--
-- Network requests run in cloud_pinyin_async_helper.exe, outside WeaselServer.
-- Lua only exchanges small state files and rebuilds the candidate menu after a
-- private F24 event. Selected cloud candidates are explicitly written to the
-- active schema's normal user dictionary.

local M = {}

local REQUEST_PROPERTY = "cloud_pinyin_async_request"
local READY_PROPERTY = "cloud_pinyin_async_ready"
local REQUEST_FILE = "cloud_pinyin_async.request"
local RESPONSE_FILE = "cloud_pinyin_async.response"
local HEARTBEAT_FILE = "cloud_pinyin_async.heartbeat"
local HELPER_FILE = "cloud_pinyin_async_helper.exe"
local RESPONSE_MAGIC = "RIME_CLOUD_V1"

local user_dir = rime_api.get_user_data_dir()
local response_history = {}
local response_order = {}
local cached_response_text = nil
local cached_response = nil
local last_helper_launch = 0
local recent_cloud_codes = {}
local recent_cloud_order = {}

local tone_map = {
    ["ā"] = "a", ["á"] = "a", ["ǎ"] = "a", ["à"] = "a",
    ["ē"] = "e", ["é"] = "e", ["ě"] = "e", ["è"] = "e",
    ["ī"] = "i", ["í"] = "i", ["ǐ"] = "i", ["ì"] = "i",
    ["ō"] = "o", ["ó"] = "o", ["ǒ"] = "o", ["ò"] = "o",
    ["ū"] = "u", ["ú"] = "u", ["ǔ"] = "u", ["ù"] = "u",
    ["ǖ"] = "v", ["ǘ"] = "v", ["ǚ"] = "v", ["ǜ"] = "v", ["ü"] = "v",
    ["ń"] = "n", ["ň"] = "n", ["ǹ"] = "n",
}

local function path(name)
    return user_dir .. "/" .. name
end

local function read_all(file_path)
    local file = io.open(file_path, "rb")
    if not file then
        return nil
    end
    local value = file:read("*a")
    file:close()
    return value
end

local function split_tab(line)
    local fields = {}
    for field in (line .. "\t"):gmatch("(.-)\t") do
        fields[#fields + 1] = field
    end
    return fields
end

local base64_alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local base64_values = {}
for index = 1, #base64_alphabet do
    base64_values[base64_alphabet:sub(index, index)] = index - 1
end

local function base64_decode(value)
    local output = {}
    local accumulator = 0
    local bits = 0
    for index = 1, #value do
        local char = value:sub(index, index)
        if char == "=" then
            break
        end
        local digit = base64_values[char]
        if digit then
            accumulator = accumulator * 64 + digit
            bits = bits + 6
            if bits >= 8 then
                bits = bits - 8
                local divisor = 2 ^ bits
                local byte = math.floor(accumulator / divisor) % 256
                output[#output + 1] = string.char(byte)
                accumulator = accumulator % divisor
            end
        end
    end
    return table.concat(output)
end

local function response_token(response)
    return response.id .. ":" .. tostring(response.revision)
end

local function remember_response(response)
    local token = response_token(response)
    if not response_history[token] then
        response_order[#response_order + 1] = token
    end
    response_history[token] = response
    while #response_order > 8 do
        local expired = table.remove(response_order, 1)
        response_history[expired] = nil
    end
end

local function parse_response(text)
    if not text or text == "" then
        return nil
    end

    local lines = {}
    for line in text:gmatch("[^\r\n]+") do
        lines[#lines + 1] = line
    end
    if #lines == 0 then
        return nil
    end

    local header = split_tab(lines[1])
    if header[1] ~= RESPONSE_MAGIC or #header < 9 then
        return nil
    end

    local response = {
        id = header[2],
        input = header[3],
        query = header[4],
        revision = tonumber(header[5]) or 0,
        sogou_ms = tonumber(header[6]) or -1,
        google_ms = tonumber(header[7]) or -1,
        sogou_status = header[8],
        google_status = header[9],
        candidates = {},
    }

    for index = 2, #lines do
        local fields = split_tab(lines[index])
        if fields[1] == "C" and #fields >= 4 then
            local text_value = base64_decode(fields[2])
            if text_value ~= "" then
                response.candidates[#response.candidates + 1] = {
                    text = text_value,
                    pinyin = base64_decode(fields[3]),
                    sources = fields[4],
                }
            end
        end
    end

    if #response.candidates == 0 then
        return nil
    end
    return response
end

local function read_current_response()
    local text = read_all(path(RESPONSE_FILE))
    if text == cached_response_text then
        return cached_response
    end

    cached_response_text = text
    local ok, response = pcall(parse_response, text)
    if not ok then
        log.error("[cloud_pinyin_async] invalid response: " .. tostring(response))
        cached_response = nil
        return nil
    end

    cached_response = response
    if response then
        remember_response(response)
    end
    return response
end

local function active_response(context)
    local token = context:get_property(READY_PROPERTY)
    if not token or token == "" then
        return nil
    end
    local response = response_history[token]
    if response then
        return response
    end
    response = read_current_response()
    if response and response_token(response) == token then
        return response
    end
    return nil
end

local function config_number(config, key, default_value)
    local value = config:get_int("cloud_pinyin_async/" .. key)
    return tonumber(value) or default_value
end

local function load_config(env)
    local config = env.engine.schema.config
    return {
        delay_ms = config_number(config, "delay_ms", 500),
        timeout_ms = config_number(config, "timeout_ms", 900),
        candidates_per_source = config_number(config, "candidates_per_source", 5),
        max_candidates = config_number(config, "max_candidates", 8),
        insert_after = config_number(config, "insert_after", 3),
        min_input_length = config_number(config, "min_input_length", 2),
        learn_to_user_dict = config:get_bool("cloud_pinyin_async/learn_to_user_dict") ~= false,
    }
end

local function helper_is_alive()
    local heartbeat = tonumber(read_all(path(HEARTBEAT_FILE)) or "")
    return heartbeat and math.abs(os.time() - heartbeat) <= 6
end

local function ensure_helper()
    if helper_is_alive() then
        return true
    end

    local now = os.time()
    if now - last_helper_launch < 5 then
        return false
    end
    last_helper_launch = now

    local helper_path = path(HELPER_FILE):gsub("/", "\\")
    local data_path = user_dir:gsub("/", "\\")
    local probe = io.open(path(HELPER_FILE), "rb")
    if not probe then
        log.error("[cloud_pinyin_async] helper is missing: " .. helper_path)
        return false
    end
    probe:close()

    local command = 'cmd.exe /d /c start "" /b "' .. helper_path .. '" "' .. data_path .. '"'
    os.execute(command)
    return true
end

local function write_request(request_id, context_input, query_input, config)
    ensure_helper()
    local file = io.open(path(REQUEST_FILE), "wb")
    if not file then
        log.error("[cloud_pinyin_async] cannot write request file")
        return false
    end
    file:write(
        request_id, "\t",
        context_input, "\t",
        query_input, "\t",
        tostring(config.delay_ms), "\t",
        tostring(config.timeout_ms), "\t",
        tostring(config.candidates_per_source), "\t",
        tostring(config.max_candidates), "\n")
    file:close()
    return true
end

local function current_segment(context)
    local composition = context.composition
    if not composition or composition:empty() then
        return nil
    end
    return composition:back()
end

local function is_full_pinyin_context(context, config)
    local input = context.input or ""
    if #input < config.min_input_length or not input:match("^[a-z']+$") then
        return false
    end
    if not context:has_menu() then
        return false
    end
    local segment = current_segment(context)
    return segment and segment.tags and segment.tags["abc"]
end

local function make_nonce(env)
    local raw = tostring(env.engine) .. "-" .. tostring(os.time()) .. "-" .. tostring(math.floor(os.clock() * 1000000))
    return raw:gsub("[^%w%-]", "")
end

local function schedule_context(context, env)
    local input = context.input or ""
    local signature = input .. "\31" .. tostring(context.caret_pos)

    -- Rebuilding the menu after a cloud response can itself emit update
    -- notifications (and may change caret metadata). Keep the accepted request
    -- stable until the user actually changes the input, so a second provider
    -- can merge into the same candidate menu instead of becoming stale.
    if env.active_cloud_input then
        if input == env.active_cloud_input and context:get_property(READY_PROPERTY) ~= "" then
            env.last_signature = signature
            return
        end
        env.active_cloud_input = nil
    end

    if signature == env.last_signature then
        return
    end
    env.last_signature = signature
    env.sequence = env.sequence + 1

    local request_id = env.nonce .. "-" .. tostring(env.sequence)
    context:set_property(REQUEST_PROPERTY, request_id)
    context:set_property(READY_PROPERTY, "")

    if is_full_pinyin_context(context, env.cloud_config) then
        local query = input:gsub("'", "")
        write_request(request_id, input, query, env.cloud_config)
    else
        write_request(request_id, "", "", env.cloud_config)
        if input == "" then
            env.pending_cloud = {}
        end
    end
end

local function normalize_code(code)
    if not code then
        return nil
    end
    code = code:lower():gsub("'", " "):gsub("[^a-zv%s]", " ")
    code = code:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    if code == "" then
        return nil
    end
    return code
end

local function remove_tone(value)
    local output = {}
    for char in value:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
        output[#output + 1] = tone_map[char] or char
    end
    return table.concat(output):lower():gsub("[^a-zv]", "")
end

local function comment_to_code(comment)
    local syllables = {}
    for chunk in (comment or ""):gmatch("%S+") do
        local head = chunk:match("^([^;]+)") or ""
        local syllable = remove_tone(head)
        if syllable ~= "" then
            syllables[#syllables + 1] = syllable
        end
    end
    if #syllables == 0 then
        return nil
    end
    return table.concat(syllables, " ")
end

local function derive_local_code(input, segment, env)
    local code = nil
    if env.main_translator then
        local ok, translation = pcall(function()
            return env.main_translator:query(input, segment)
        end)
        if ok and translation then
            local seen = 0
            for candidate in translation:iter() do
                seen = seen + 1
                if candidate._end - candidate.start >= segment._end - segment.start then
                    code = comment_to_code(candidate.comment or "")
                    if code then
                        break
                    end
                end
                if seen >= 8 then
                    break
                end
            end
        end
    end

    if not code and input:find("'", 1, true) then
        code = normalize_code(input)
    end
    return code
end

local function source_comment(sources)
    if sources == "SG+GG" then
        return " ☁搜谷"
    elseif sources == "SG" then
        return " ☁搜"
    end
    return " ☁谷"
end

local function genuine_candidate(candidate)
    local ok, genuine = pcall(function()
        return candidate:get_genuine()
    end)
    if ok and genuine then
        return genuine
    end
    return candidate
end

local function user_phrase_variant(candidate)
    local ok, variants = pcall(function()
        return candidate:get_genuines()
    end)
    if ok and variants then
        for _, variant in ipairs(variants) do
            local genuine = genuine_candidate(variant)
            if variant.type == "user_phrase" or genuine.type == "user_phrase" then
                return variant
            end
        end
    end

    local genuine = genuine_candidate(candidate)
    if candidate.type == "user_phrase" or genuine.type == "user_phrase" then
        return candidate
    end
    return nil
end

local function remember_cloud_code(text, code, token, input)
    if not text or not code then
        return
    end
    if not recent_cloud_codes[text] then
        recent_cloud_order[#recent_cloud_order + 1] = text
    end
    recent_cloud_codes[text] = {
        code = code,
        token = token,
        input = input,
    }
    while #recent_cloud_order > 64 do
        local expired = table.remove(recent_cloud_order, 1)
        recent_cloud_codes[expired] = nil
    end
end

local function learn_pending(context, env)
    local pending = env.pending_cloud
    env.pending_cloud = {}
    local activated_response = env.last_activated_response
    env.last_activated_response = nil
    if not env.cloud_config.learn_to_user_dict or not env.memory then
        return
    end

    local commit_text = context:get_commit_text() or ""
    local selected = {}
    for _, item in ipairs(pending or {}) do
        if commit_text:find(item.text, 1, true) and not selected[item.text .. "\31" .. item.code] then
            selected[item.text .. "\31" .. item.code] = item
        end
    end

    -- Direct selection with Space/number keys does not reliably emit
    -- select_notifier on Weasel. Match the actual committed text against the
    -- last response that was rendered, which covers keyboard and mouse commits
    -- without depending on the wrapped candidate type.
    if activated_response then
        for _, candidate in ipairs(activated_response.candidates or {}) do
            if commit_text:find(candidate.text, 1, true) then
                local remembered = recent_cloud_codes[candidate.text]
                local code = activated_response.learn_codes and activated_response.learn_codes[candidate.text] or nil
                code = code or (remembered and remembered.code or nil)
                code = code or normalize_code(candidate.pinyin)
                if code then
                    selected[candidate.text .. "\31" .. code] = {
                        text = candidate.text,
                        code = code,
                    }
                    log.info("[cloud_pinyin_async] matched committed cloud candidate")
                end
            end
        end
    end
    if not next(selected) then
        return
    end

    local started = false
    if env.memory.start_session then
        env.memory:start_session()
        started = true
    end

    for _, item in pairs(selected) do
        local entry = DictEntry()
        entry.text = item.text
        entry.custom_code = item.code .. " "
        local ok, updated = pcall(function()
            return env.memory:update_userdict(entry, 1, "")
        end)
        if not ok or not updated then
            log.error("[cloud_pinyin_async] failed to learn cloud candidate")
        else
            log.info("[cloud_pinyin_async] learned cloud candidate")
        end
    end

    if started and env.memory.finish_session then
        env.memory:finish_session()
    end
end

local function processor_init(env)
    env.cloud_config = load_config(env)
    env.last_signature = nil
    env.sequence = 0
    env.nonce = make_nonce(env)
    env.pending_cloud = {}
    env.active_cloud_input = nil
    env.last_activated_response = nil

    local ok, memory = pcall(function()
        return Memory(env.engine, env.engine.schema)
    end)
    if ok then
        env.memory = memory
    else
        env.memory = nil
        log.error("[cloud_pinyin_async] cannot open schema user dictionary: " .. tostring(memory))
    end

    local context = env.engine.context
    env.update_connection = context.update_notifier:connect(function(current)
        schedule_context(current, env)
    end)
    env.select_connection = context.select_notifier:connect(function(current)
        local candidate = current:get_selected_candidate()
        if not candidate then
            return
        end

        local genuine = genuine_candidate(candidate)
        local candidate_text = candidate.text or genuine.text or ""
        local marked_cloud = (candidate.comment or ""):find("☁", 1, true) ~= nil
        local response = active_response(current)
        local response_item = nil
        if response then
            for _, item in ipairs(response.candidates) do
                if item.text == candidate_text then
                    response_item = item
                    break
                end
            end
        end

        if genuine.type ~= "cloud_pinyin_async" and not marked_cloud and not response_item then
            return
        end

        local remembered = recent_cloud_codes[candidate_text]
        local code = remembered and remembered.code or nil
        if not code and response and response.learn_codes then
            code = response.learn_codes[candidate_text]
        end
        if not code and response_item then
            code = normalize_code(response_item.pinyin)
        end
        code = code or normalize_code(genuine.preedit or candidate.preedit or "")
        if not code then
            log.error("[cloud_pinyin_async] selected cloud candidate has no learnable code")
            return
        end

        env.pending_cloud[#env.pending_cloud + 1] = {
            text = candidate_text,
            code = code,
        }
        log.info("[cloud_pinyin_async] captured cloud selection")
    end)
    env.commit_connection = context.commit_notifier:connect(function(current)
        learn_pending(current, env)
    end)

    ensure_helper()
    schedule_context(context, env)
end

local function processor_fini(env)
    if env.update_connection then
        env.update_connection:disconnect()
    end
    if env.select_connection then
        env.select_connection:disconnect()
    end
    if env.commit_connection then
        env.commit_connection:disconnect()
    end
    if env.memory and env.memory.disconnect then
        env.memory:disconnect()
    end
end

local function processor_func(key, env)
    local representation = key:repr()
    if representation ~= "F24" and representation ~= "Release+F24" then
        return 2
    end
    if representation == "Release+F24" then
        return 1
    end

    local context = env.engine.context
    local response = read_current_response()
    if not response or response.id ~= context:get_property(REQUEST_PROPERTY) or response.input ~= context.input then
        log.info("[cloud_pinyin_async] refresh ignored: stale response")
        return 1
    end
    if not context:is_composing() or not context:has_menu() then
        log.info("[cloud_pinyin_async] refresh ignored: no active menu")
        return 1
    end

    local segment = current_segment(context)
    if not segment or segment.selected_index ~= 0 then
        log.info("[cloud_pinyin_async] refresh ignored: selection moved")
        return 1
    end

    env.active_cloud_input = context.input
    env.last_activated_response = response
    context:set_property(READY_PROPERTY, response_token(response))
    log.info("[cloud_pinyin_async] activating response " .. response_token(response))
    context:refresh_non_confirmed_composition()
    return 1
end

M.processor = {
    init = processor_init,
    func = processor_func,
    fini = processor_fini,
}

local function translator_init(env)
    env.cloud_config = load_config(env)
    local ok, translator = pcall(function()
        return Component.Translator(env.engine, "translator", "script_translator")
    end)
    if ok then
        env.main_translator = translator
    end
    env.code_cache_token = nil
    env.code_cache_value = nil
    env.last_logged_response = nil
end

local function translator_func(input, segment, env)
    local context = env.engine.context
    local response = active_response(context)
    if not response or response.input ~= input or response.id ~= context:get_property(REQUEST_PROPERTY) then
        return
    end

    local token = response_token(response)
    if env.last_logged_response ~= token then
        env.last_logged_response = token
        log.info(
            "[cloud_pinyin_async] yielding " ..
            tostring(#response.candidates) ..
            " cloud candidates from " .. token)
    end
    if env.code_cache_token ~= token then
        env.code_cache_token = token
        env.code_cache_value = derive_local_code(input, segment, env)
    end
    response.learn_codes = response.learn_codes or {}

    for _, item in ipairs(response.candidates) do
        local code = normalize_code(item.pinyin)
        if item.sources == "SG" and env.code_cache_value then
            code = env.code_cache_value
        end
        code = code or normalize_code(input)
        if code then
            response.learn_codes[item.text] = code
            remember_cloud_code(item.text, code, token, input)
        end

        local candidate = Candidate(
            "cloud_pinyin_async",
            segment.start,
            segment._end,
            item.text,
            source_comment(item.sources))
        candidate.quality = 10000
        if code then
            candidate.preedit = code
        end
        yield(candidate)
    end
end

M.translator = {
    init = translator_init,
    func = translator_func,
}

local function filter_init(env)
    env.cloud_config = load_config(env)
end

local function filter_func(input, env)
    local context = env.engine.context
    if not active_response(context) then
        for candidate in input:iter() do
            yield(candidate)
        end
        return
    end

    local cloud_candidates = {}
    local local_count = 0
    local inserted = false

    local function emit_cloud()
        if inserted then
            return
        end
        inserted = true
        for _, candidate in ipairs(cloud_candidates) do
            yield(candidate)
        end
    end

    for candidate in input:iter() do
        -- `uniquifier` may combine a high-quality cloud candidate with an
        -- existing learned user phrase. Prefer the user-phrase member so the
        -- normal Rime ranking/learning path takes over on subsequent input.
        local learned_variant = user_phrase_variant(candidate)
        local genuine = genuine_candidate(candidate)
        if learned_variant then
            yield(learned_variant)
            local_count = local_count + 1
            if local_count >= env.cloud_config.insert_after then
                emit_cloud()
            end
        elseif genuine.type == "cloud_pinyin_async" then
            cloud_candidates[#cloud_candidates + 1] = candidate
        else
            yield(candidate)
            local_count = local_count + 1
            if local_count >= env.cloud_config.insert_after then
                emit_cloud()
            end
        end
    end
    emit_cloud()
end

M.filter = {
    init = filter_init,
    func = filter_func,
}

return M
