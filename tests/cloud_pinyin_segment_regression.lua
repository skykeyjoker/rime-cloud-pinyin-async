local module_path = assert(arg[1], "usage: luajit tests/cloud_pinyin_segment_regression.lua <lua-module>")

rime_api = {
    get_user_data_dir = function()
        return "/tmp/rime-cloud-pinyin-async-test"
    end,
}

local cloud = assert(dofile(module_path))
local helpers = assert(cloud._test)

local function assert_equal(actual, expected, message)
    if actual ~= expected then
        error((message or "values differ") .. ": expected " .. tostring(expected) ..
            ", got " .. tostring(actual), 2)
    end
end

local function make_context(input, segment_start, segment_end, request_id, has_menu, ready_token)
    local segment = {
        start = segment_start,
        _end = segment_end,
        tags = { abc = true },
    }
    local properties = {
        cloud_pinyin_async_request = request_id,
        cloud_pinyin_async_ready = ready_token or "",
    }
    return {
        input = input,
        caret_pos = #input,
        composition = {
            empty = function()
                return false
            end,
            back = function()
                return segment
            end,
        },
        has_menu = function()
            return has_menu ~= false
        end,
        get_property = function(_, name)
            return properties[name] or ""
        end,
    }
end

local config = { min_input_length = 2 }
local full_input = "chabuduojiukeyishidianhouxiabanle"
local prefix_length = #"chabuduo"
local remaining_input = full_input:sub(prefix_length + 1)

local initial_context = make_context(full_input, 0, #full_input, "request-1")
local initial_target = assert(helpers.current_request_target(initial_context, config))
assert_equal(initial_target.context_input, full_input, "initial full context")
assert_equal(initial_target.segment_input, full_input, "initial active segment")
assert_equal(initial_target.query_input, full_input, "initial cloud query")

-- Rime keeps Context.input unchanged after confirming the first candidate, but
-- moves the active segment start to the unconfirmed suffix.
local partial_context = make_context(full_input, prefix_length, #full_input, "request-2")
local partial_target = assert(helpers.current_request_target(partial_context, config))
assert_equal(partial_target.context_input, full_input, "partial full context")
assert_equal(partial_target.segment_input, remaining_input, "partial active segment")
assert_equal(partial_target.query_input, remaining_input, "partial cloud query")
assert(initial_target.key ~= partial_target.key, "partial selection must create a new request target")

local current_response = {
    id = "request-2",
    input = full_input,
    query = remaining_input,
}
assert(
    helpers.response_matches_target(partial_context, current_response, config),
    "response for the unconfirmed suffix should be accepted")

local stale_response = {
    id = "request-2",
    input = full_input,
    query = full_input,
}
assert_equal(
    helpers.response_matches_target(partial_context, stale_response, config),
    nil,
    "response for the previously confirmed segment must be rejected")

-- Filters run while Rime is rebuilding the menu. Context.has_menu() is false
-- during that window, but the composition and active segment remain valid.
local rebuilding_context = make_context("xian", 0, #"xian", "request-3", false)
assert_equal(
    helpers.current_request_target(rebuilding_context, config),
    nil,
    "normal scheduling must still require an existing menu")
local rebuilding_target = assert(
    helpers.current_request_target(rebuilding_context, config, true),
    "filter validation should accept a valid segment during menu rebuild")
assert_equal(rebuilding_target.query_input, "xian", "menu rebuild cloud query")
local rebuilding_response = {
    id = "request-3",
    input = "xian",
    query = "xian",
}
assert(
    helpers.response_matches_target(
        rebuilding_context,
        rebuilding_response,
        config,
        true),
    "filter should retain segment-aware ordering while the menu is rebuilding")

-- Backspace after confirming a prefix returns Rime to the original full
-- segment. The suffix response must become stale and the full query valid
-- again, even though Context.input itself never changed.
local backed_context = make_context(full_input, 0, #full_input, "request-4")
local backed_target = assert(helpers.current_request_target(backed_context, config))
assert_equal(backed_target.query_input, full_input, "backspace restores full query")
assert_equal(backed_target.key, initial_target.key, "backspace restores initial target")
local backed_response = {
    id = "request-4",
    input = full_input,
    query = full_input,
}
assert(
    helpers.response_matches_target(backed_context, backed_response, config),
    "full response should be accepted after backing out of prefix selection")
local stale_suffix_after_backspace = {
    id = "request-4",
    input = full_input,
    query = remaining_input,
}
assert_equal(
    helpers.response_matches_target(
        backed_context,
        stale_suffix_after_backspace,
        config),
    nil,
    "suffix response must be rejected after backing out of prefix selection")

local function make_candidate(candidate_type, text)
    local candidate = {
        type = candidate_type,
        text = text,
        comment = candidate_type == "cloud_pinyin_async" and " ☁测试" or "",
    }
    candidate.get_genuine = function(self)
        return self
    end
    candidate.get_genuines = function(self)
        return { self }
    end
    return candidate
end

local function make_input(candidates)
    local index = 0
    return {
        iter = function()
            return function()
                index = index + 1
                return candidates[index]
            end
        end,
    }
end

-- The cloud translator intentionally has a much higher quality, so its raw
-- candidates reach the first filter before the native Frost candidates. The
-- cloud filter must restore the native local head before any order-changing
-- filter (notably long_word_filter) sees that stream.
local order_response = {
    id = "request-order",
    revision = 1,
    input = "xian",
    query = "xian",
    candidates = {},
    sogou_status = "ok",
    google_status = "ok",
}
local order_token = helpers.remember_response(order_response)
local order_context = make_context(
    "xian",
    0,
    #"xian",
    order_response.id,
    false,
    order_token)
local order_env = {
    engine = { context = order_context },
    cloud_config = {
        insert_after = 2,
        max_candidates = 5,
        min_input_length = 2,
        refill_on_duplicate = false,
    },
}
local order_input = make_input({
    make_candidate("cloud_pinyin_async", "先"),
    make_candidate("cloud_pinyin_async", "云端新词"),
    make_candidate("cloud_pinyin_async", "线"),
    make_candidate("cloud_pinyin_async", "现"),
    make_candidate("phrase", "先"),
    make_candidate("phrase", "线"),
    make_candidate("phrase", "西安"),
    make_candidate("phrase", "锡安"),
    make_candidate("phrase", "弦"),
    make_candidate("phrase", "现"),
})
local emitted = {}
local original_yield = yield
yield = function(candidate)
    emitted[#emitted + 1] = candidate
end
cloud.filter.func(order_input, order_env)
yield = original_yield

local expected_order = { "先", "线", "云端新词", "西安", "锡安", "弦", "现" }
assert_equal(#emitted, #expected_order, "ranked candidate count")
for index, expected in ipairs(expected_order) do
    assert_equal(emitted[index].text, expected, "ranked candidate " .. tostring(index))
end
assert(order_response.suppressed_texts["先"], "local first candidate suppresses cloud duplicate")
assert(order_response.suppressed_texts["线"], "local second candidate suppresses cloud duplicate")
assert(order_response.suppressed_texts["现"], "local scan suppresses later cloud duplicate")

print("ok: " .. module_path)
