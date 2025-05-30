-- 词条隐藏、降频
-- 在 engine/processors 增加 - lua_processor@cold_word_drop.processor
-- 在 engine/filters 增加 - lua_filter@cold_word_drop.filter
-- 在 key_binder 增加快捷键：
-- reduce_freq_cand: "Control+j"  # 匹配当前输入码后隐藏指定的候选字词 或候选词条放到第四候选位置
-- drop_cand: "Control+d"         # 强制删词, 无视输入的编码
-- get_record_filername() 函数中仅支持了 Windows、macOS、Linux

require("cold_word_drop.string")
require("cold_word_drop.metatable")
local processor = {}

local function get_record_filername(record_type)
	local path_sep = "/"
	local user_data_dir = rime_api:get_user_data_dir()
	local user_distribute_name = rime_api:get_distribution_code_name()
	if user_distribute_name:lower():match("weasel") then path_sep = [[\]] end
	if user_distribute_name:lower():match("ibus") then
		return string.format("%s/rime/lua/cold_word_drop/%s_words.lua",
			os.getenv("HOME") .. "/.config/ibus",
			record_type
		)
	else
		local file_path = string.format("%s/lua/cold_word_drop/%s_words.lua", user_data_dir, record_type)
		return file_path:gsub("/", path_sep)
	end
end

local function write_word_to_file(env, record_type)
	local filename = get_record_filername(record_type)
	local record_header = string.format("local %s_words =\n", record_type)
	local record_tailer = string.format("\nreturn %s_words", record_type)
	if not filename then
		return false
	end
	local fd = assert(io.open(filename, "w")) --打开
	-- fd:flush() --刷新
	local x = string.format("%s_list", record_type)
	local record = table.serialize(env.tbls[x]) -- lua 的 table 对象 序列化为字符串
	fd:setvbuf("line")
	fd:write(record_header) --写入文件头部
	fd:write(record) --写入 序列化的字符串
	fd:write(record_tailer) --写入文件尾部, 结束记录
	fd:close() --关闭
end

local function append_word_to_droplist(env, ctx, action_type)
	local word = ctx.word:gsub(" ", "")
	local input_code = ctx.code:gsub(" ", "")

	if action_type == "drop" then
		table.insert(env.drop_words, word) -- 高亮选中的词条插入到 drop_list
		return true
	end

	if action_type == "hide" then
		if not env.hide_words[word] then
			env.hide_words[word] = { input_code }
			-- 隐藏的词条如果已经在 hide_list 中, 则将输入串追加到 值表中, 如: ['藏'] = {'chang', 'zhang'}
		elseif not table.find_index(env.hide_words[word], input_code) then
			table.insert(env.hide_words[word], input_code)
		end
		return true
	end

	if action_type == "reduce_freq" then
		if env.reduce_freq_words[word] then
			table.insert(env.reduce_freq_words[word], input_code)
		else
			env.reduce_freq_words[word] = { input_code }
		end
		return true
	end
end

function processor.init(env)
    local engine = env.engine
    local config = engine.schema.config
    local _sd, drop_words = pcall(require, "cold_word_drop/drop_words")
    local _sh, hide_words = pcall(require, "cold_word_drop/hide_words")
    local _st, turn_down_words = pcall(require, "cold_word_drop/turn_down_words")
    local _sr, reduce_freq_words = pcall(require, "cold_word_drop/reduce_freq_words")
    env.drop_words = _sd and drop_words or {}
    env.hide_words = _sh and hide_words or {}
    env.reduce_freq_words = (_st and turn_down_words) or (_sr and reduce_freq_words) or {}
    env.drop_cand_key = config:get_string("key_binder/drop_cand") or "Control+d"
    env.hide_cand_key = config:get_string("key_binder/hide_cand") or "Control+x"
    env.turn_down_cand_key = config:get_string("key_binder/turn_down_cand") or nil
    env.reduce_cand_key = env.turn_down_cand_key or config:get_string("key_binder/reduce_freq_cand") or "Control+j"
    env.tbls = {
		["drop_list"] = env.drop_words,
		["hide_list"] = env.hide_words,
		["reduce_freq_list"] = env.reduce_freq_words,
	}
end

function processor.func(key, env)
	local engine = env.engine
	local context = engine.context
	local preedit_code = context:get_script_text()
	local action_map = {
		[env.drop_cand_key] = "drop",
		[env.hide_cand_key] = "hide",
		[env.reduce_cand_key] = "reduce_freq",
	}

	if context:has_menu() and action_map[key:repr()] then
		local cand = context:get_selected_candidate()
		local action_type = action_map[key:repr()]
		local ctx_map = {
			["word"] = cand.text,
			["code"] = preedit_code,
		}
		local res = append_word_to_droplist(env, ctx_map, action_type)

		context:refresh_non_confirmed_composition() -- 刷新当前输入法候选菜单, 实现看到实时效果
		if not res then
			return 2
		end

		if res then
			-- 期望被删的词和隐藏的词条写入文件(drop_words.lua, hide_words.lua)
			write_word_to_file(env, action_type)
		end

		return 1 -- kAccept
	end

	return 2 -- kNoop, 不做任何操作, 交给下个组件处理
end

return processor
