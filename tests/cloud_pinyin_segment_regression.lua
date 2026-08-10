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

local function make_context(input, segment_start, segment_end, request_id)
    local segment = {
        start = segment_start,
        _end = segment_end,
        tags = { abc = true },
    }
    local properties = {
        cloud_pinyin_async_request = request_id,
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
            return true
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

print("ok: " .. module_path)
