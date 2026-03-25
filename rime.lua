-- rime.lua
-- rime-llm-reranker · 改进版 v2
--
-- 改进点（相比 v1）：
--   1. prompt 分离：历史上下文用汉字，当前拼音单独传，LLM 理解更准确
--   2. 上下文感知缓存：key = 历史末尾20字 + preedit，避免跨语境污染
--   3. 音节数去抖动：至少打完2个音节才触发，替代不可靠的"末尾韵母"判断
--   4. top-3 排名模式：LLM 返回有序列表而非单词，提高命中率
--   5. 置信度过滤：LLM 选的词超出原始 top-3 则放弃重排

-- ─── luasocket 路径注入（Apple Silicon Mac）─────────────
local _home = os.getenv('HOME') or ''
package.path = package.path
  ..';'.._home..'/.luarocks/share/lua/5.4/?.lua'
  ..';'.._home..'/.luarocks/share/lua/5.4/?/init.lua'
  ..';/opt/homebrew/share/lua/5.4/?.lua'
  ..';/opt/homebrew/share/lua/5.4/?/init.lua'
package.cpath = package.cpath
  ..';'.._home..'/.luarocks/lib/lua/5.4/?.so'
  ..';/opt/homebrew/lib/lua/5.4/?.so'

-- ─── luasocket 检测 ──────────────────────────────────────
local _socket_ok, _socket_http, _socket_ltn12
do
  local ok1, m1 = pcall(require, 'socket.http')
  local ok2, m2 = pcall(require, 'ltn12')
  if ok1 and ok2 then
    _socket_ok    = true
    _socket_http  = m1
    _socket_ltn12 = m2
  end
end

-- ─── JSON 编码 ───────────────────────────────────────────
local function json_encode(v)
  local ESC = {['"']='\\"',['\\']='\\\\', ['\n']='\\n',['\r']='\\r',['\t']='\\t'}
  local function esc(s)
    s = s:gsub('["\\\n\r\t]', ESC)
    s = s:gsub('[\x00-\x1f]', function(c) return string.format('\\u%04x',c:byte()) end)
    return s
  end
  local function is_arr(t)
    local n=0
    for k in pairs(t) do
      if type(k)~='number' or k~=math.floor(k) or k<1 then return false end
      n=n+1
    end
    return n==#t
  end
  local function enc(x, d)
    d=d or 0
    local t=type(x)
    if     t=='nil'     then return 'null'
    elseif t=='boolean' then return x and 'true' or 'false'
    elseif t=='number'  then
      if x~=x or math.abs(x)==math.huge then return 'null' end
      if x==math.floor(x) and math.abs(x)<1e15 then return string.format('%d',x) end
      return string.format('%.17g',x)
    elseif t=='string'  then return '"'..esc(x)..'"'
    elseif t=='table'   then
      if is_arr(x) then
        local p={} for i=1,#x do p[i]=enc(x[i],d+1) end
        return '['..table.concat(p,',')..']'
      else
        local p={}
        for k,val in pairs(x) do
          if type(k)=='string' then
            table.insert(p, '"'..esc(k)..'":'..enc(val,d+1))
          end
        end
        return '{'..table.concat(p,',')..'}'
      end
    end
    return 'null'
  end
  local ok, r = pcall(enc, v)
  return ok and r or nil
end

local function json_extract_content(s)
  if not s or s=='' then return nil end
  local c = s:match('"content"%s*:%s*"(.-[^\\])"')
  if not c then return nil end
  c = c:gsub('\\"','"'):gsub('\\n','\n'):gsub('\\t','\t'):gsub('\\\\','\\')
  c = c:match('^%s*(.-)%s*$') or c
  if c:find('%?') or c:find('\xef\xbf\xbd') then return nil end
  return c ~= '' and c or nil
end

-- ─── HTTP POST ───────────────────────────────────────────
local function http_post(url, payload_table, timeout)
  local body = json_encode(payload_table)
  if not body then return nil, 'encode failed' end

  if _socket_ok then
    _socket_http.TIMEOUT = timeout
    local parts = {}
    local _, code = _socket_http.request({
      url     = url,
      method  = 'POST',
      headers = {
        ['content-type']   = 'application/json',
        ['content-length'] = tostring(#body),
        ['authorization']  = 'Bearer sk-placeholder',
      },
      source = _socket_ltn12.source.string(body),
      sink   = _socket_ltn12.sink.table(parts),
    })
    if code == 200 then return table.concat(parts) end
    return nil, 'luasocket HTTP '..tostring(code)
  else
    local safe = body:gsub("'","'\"'\"'")
    local cmd  = string.format(
      "curl -s --connect-timeout %.2f --max-time %.2f "..
      "-X POST -H 'Content-Type: application/json' "..
      "-H 'Authorization: Bearer sk-placeholder' "..
      "-d '%s' '%s' 2>/dev/null",
      timeout*0.5, timeout, safe, url)
    local h = io.popen(cmd,'r')
    if not h then return nil,'popen failed' end
    local r = h:read('*all'); h:close()
    if r and #r>0 then return r end
    return nil,'curl empty response'
  end
end

-- ─── 配置读取 ────────────────────────────────────────────
local function get_config(env)
  local c = env.engine.schema.config
  local function gb(k,d) local v=c:get_bool(k);   return v~=nil and v or d end
  local function gs(k,d) return c:get_string(k) or d end
  local function gn(k,d) return c:get_double(k) or d end
  local function gi(k,d) return c:get_int(k)    or d end
  return {
    enabled         = gb('llm_reranker/enabled',           true),
    endpoint        = gs('llm_reranker/endpoint',          'http://localhost:8000/v1/chat/completions'),
    model           = gs('llm_reranker/model',             'Qwen3.5-0.8B-MLX-bf16'),
    max_cands       = gi('llm_reranker/max_candidates',    5),
    timeout         = gn('llm_reranker/timeout',           0.5),
    ctx_len         = gi('llm_reranker/context_length',    60),
    temperature     = gn('llm_reranker/temperature',       0.0),
    max_tokens      = gi('llm_reranker/max_tokens',        20),
    -- 改进3：音节数去抖动阈值（替代 min_preedit_len）
    min_syllables   = gi('llm_reranker/min_syllables',     2),
    -- 无上下文时跳过 LLM（历史提交文字少于此值则不调用）
    min_ctx_len     = gi('llm_reranker/min_context_len',   0),  -- 0=不限制
    -- 超长 preedit 时跳过（第一候选通常已经很准）
    max_preedit_len = gi('llm_reranker/max_preedit_len',   10),
    -- 改进5：置信度过滤——LLM 选的词超出此排名则放弃重排
    max_rerank_pos  = gi('llm_reranker/max_rerank_pos',    3),
    system_prompt   = gs('llm_reranker/system_prompt',
      '你是中文输入法候选词排序助手。'..
      '根据对话历史和当前输入，从候选词列表中选出最符合语境的词。'..
      '按优先级从高到低列出最多3个候选词，用顿号分隔，不要任何解释。'),
    fallback        = gb('llm_reranker/fallback_on_error', true),
    debug           = gb('llm_reranker/debug_log',         false),
  }
end

-- ─── 日志 ────────────────────────────────────────────────
local LOG_PATH = _home..'/Library/Rime/rime_llm.log'
local function dlog(cfg, msg)
  if not cfg.debug then return end
  local f = io.open(LOG_PATH,'a')
  if f then f:write(os.date('%H:%M:%S')..' '..msg..'\n'); f:close() end
end

-- ─── 改进3：拼音音节数估算 ───────────────────────────────
-- 通过统计声母出现次数估算音节数，比"末尾是韵母"更可靠
-- 例：chongxin = 2音节，na = 1音节，c = 0音节（不完整）
local INITIALS = {
  'zh','ch','sh',  -- 翘舌音（三字母，必须先检测）
  'b','p','m','f',
  'd','t','n','l',
  'g','k','h',
  'j','q','x',
  'z','c','s',
  'r','y','w',
}
local function count_syllables(preedit)
  if not preedit or preedit == '' then return 0 end
  local s = preedit:lower()
  local count = 0
  local i = 1
  while i <= #s do
    local matched = false
    -- 尝试匹配声母（优先长的）
    for _, ini in ipairs(INITIALS) do
      if s:sub(i, i+#ini-1) == ini then
        count = count + 1
        i = i + #ini
        -- 跳过后续韵母
        while i <= #s and s:sub(i,i):match('[aeiouüv]') do i = i + 1 end
        -- 跳过鼻韵尾 n/ng
        if s:sub(i,i+1) == 'ng' then i = i + 2
        elseif s:sub(i,i) == 'n' then i = i + 1 end
        matched = true
        break
      end
    end
    if not matched then
      -- 零声母音节（如 an、ou、yi）
      if s:sub(i,i):match('[aeiouüv]') then
        count = count + 1
        while i <= #s and s:sub(i,i):match('[aeiouüvng]') do i = i + 1 end
      else
        i = i + 1
      end
    end
  end
  return count
end

-- ─── 候选词匹配 ──────────────────────────────────────────
local function find_match(list, word)
  if not word or word == '' then return nil end
  word = word:match('^%s*(.-)%s*$') or word
  -- 精确匹配
  for i,c in ipairs(list) do
    if c.text == word then return i end
  end
  -- 前缀匹配（模型可能只输出部分）
  for i,c in ipairs(list) do
    if #word >= 1 and c.text:sub(1,#word) == word then return i end
    if #c.text >= 1 and word:sub(1,#c.text) == c.text then return i end
  end
  return nil
end

-- ─── 改进4：解析 top-3 排名响应 ─────────────────────────
-- LLM 返回"词A、词B、词C"，依次尝试匹配候选词列表
local function extract_best_from_ranking(response, list)
  local content = json_extract_content(response)
  if not content then return nil end
  -- 按常见分隔符切分
  for word in content:gmatch('[^、，,；;\n]+') do
    word = word:match('^%s*(.-)%s*$') or word
    -- 去掉序号（如"1. 重新" "①重新"）
    word = word:gsub('^[%d①②③%.、。%s]+', '')
    word = word:match('^%s*(.-)%s*$') or word
    if word ~= '' then
      local idx = find_match(list, word)
      if idx then return idx end
    end
  end
  return nil
end

-- ─── 改进1：LLM 调用（prompt 分离汉字上下文和拼音）────────
local function query_llm(cfg, committed, preedit, cand_texts)
  -- 改进1核心：历史上下文用汉字传，当前输入拼音单独说明
  -- 让 LLM 知道"前面说了什么"和"现在想打什么"是两件事
  local user_content
  if committed ~= '' then
    user_content =
      '对话历史：「'..committed..'」\n'..
      '当前输入拼音：「'..preedit..'」\n'..
      '候选词：'..table.concat(cand_texts,'、')..'\n'..
      '按最符合对话语境的顺序列出前3个候选词（顿号分隔）：'
  else
    -- 无历史上下文时，直接让模型根据拼音猜最可能的词
    user_content =
      '输入拼音：「'..preedit..'」\n'..
      '候选词：'..table.concat(cand_texts,'、')..'\n'..
      '按最可能的顺序列出前3个候选词（顿号分隔）：'
  end

  local payload = {
    model       = cfg.model,
    stream      = false,
    temperature = cfg.temperature,
    max_tokens  = cfg.max_tokens,
    messages    = {
      {role='system', content=cfg.system_prompt},
      {role='user',   content=user_content},
    },
  }

  local t0 = os.clock()
  local resp, err = http_post(cfg.endpoint, payload, cfg.timeout)
  local ms = (os.clock()-t0)*1000

  if not resp then
    dlog(cfg, string.format('FAIL %.0fms %s', ms, tostring(err)))
    return nil, ms
  end

  local content = json_extract_content(resp)
  dlog(cfg, string.format('OK %.0fms → [%s] preedit=「%s」 ctx=「%s」',
    ms, content or 'nil', preedit, committed:sub(-15)))
  return resp, ms
end

-- ─── 重排序 ──────────────────────────────────────────────
local function reorder(list, idx)
  if not idx or idx == 1 then return list end
  local r = {list[idx]}
  for i,c in ipairs(list) do if i ~= idx then table.insert(r,c) end end
  return r
end

-- ─── 模块级状态 ──────────────────────────────────────────
local committed_buffer = ''
local _logged          = false
-- 改进2：缓存 key = 历史末尾20字 + ':' + preedit（上下文感知）
local _cache      = {}
local _cache_size = 0
local CACHE_MAX   = 300

-- ─── Rime filter 入口 ────────────────────────────────────
function llm_reranker(input, env)
  local all = {}
  for cand in input:iter() do table.insert(all, cand) end

  local cfg = get_config(env)

  if not _logged and cfg.debug then
    dlog(cfg, 'v2 started, backend: '..(_socket_ok and 'luasocket' or 'curl'))
    _logged = true
  end

  if not cfg.enabled or #all < 2 then
    for _,c in ipairs(all) do yield(c) end
    return
  end

  -- 获取 preedit
  local preedit = ''
  pcall(function()
    local p = env.engine.context:get_preedit()
    if p then preedit = p.text or '' end
  end)


  -- 改进3：音节数去抖动（至少 min_syllables 个完整音节）
  local syllables = count_syllables(preedit)
  if syllables < cfg.min_syllables then
    for _,c in ipairs(all) do yield(c) end
    return
  end

  -- 是否跳过 LLM（统一用 skip 标志，避免在协程内提前 return）
  local skip = false

  -- 无上下文时跳过：历史提交字节数不足（中文每字3字节）
  -- min_ctx_len=4 约等于至少提交过1-2个中文词
  local ctx_bytes = committed_buffer:len()
  if ctx_bytes < cfg.min_ctx_len then
    skip = true
    dlog(cfg, 'SKIP: no context ('..ctx_bytes..' bytes < '..cfg.min_ctx_len..')')
  end

  -- preedit 过长时跳过：超长拼音第一候选通常已经很准
  local preedit_len = preedit:len()
  if preedit_len > cfg.max_preedit_len then
    skip = true
    dlog(cfg, 'SKIP: preedit too long ('..preedit_len..' > '..cfg.max_preedit_len..')')
  end

  -- 分 top / rest
  local top, rest = {}, {}
  for i,c in ipairs(all) do
    if i <= cfg.max_cands then table.insert(top,c)
    else table.insert(rest,c) end
  end

  local idx = nil  -- 最终重排位置，nil = 不重排

  if not skip then
    -- 改进2：上下文感知缓存 key
    local history_key = committed_buffer:sub(-20)
    local cache_key   = history_key..':'..preedit
    local cached = _cache[cache_key]

    if cached == nil then
      -- 缓存未命中：调用 LLM
      local texts = {}
      for _,c in ipairs(top) do table.insert(texts, c.text) end

      local resp = nil
      if cfg.fallback then
        pcall(function()
          resp = (query_llm(cfg, committed_buffer:sub(-cfg.ctx_len), preedit, texts))
        end)
      else
        resp = (query_llm(cfg, committed_buffer:sub(-cfg.ctx_len), preedit, texts))
      end

      -- 改进4：从 top-3 排名中提取最佳匹配
      local raw_idx = extract_best_from_ranking(resp or '', top)

      -- 改进5：置信度过滤——排名太靠后则放弃重排
      if raw_idx and raw_idx > cfg.max_rerank_pos then
        dlog(cfg, string.format('FILTERED: rank %d > max %d, skip rerank',
          raw_idx, cfg.max_rerank_pos))
        raw_idx = nil
      end

      cached = raw_idx or false  -- false = 已查询但无可信匹配

      -- 写入缓存
      if _cache_size >= CACHE_MAX then _cache={}; _cache_size=0 end
      _cache[cache_key] = cached
      _cache_size = _cache_size + 1

      -- 调试：记录是否实际改变了排序
      if cfg.debug then
        if cached and cached > 1 then
          dlog(cfg, 'RERANKED: '..top[1].text..' → '..top[cached].text)
        else
          dlog(cfg, 'NO_CHANGE: kept '..top[1].text)
        end
      end
    else
      dlog(cfg, 'cache hit ['..tostring(cached)..'] '..cache_key)
    end

    if cached ~= false then idx = cached end
  end

  local ordered = reorder(top, idx)
  for _,c in ipairs(ordered) do yield(c) end
  for _,c in ipairs(rest)    do yield(c) end
end

-- ─── init / fini ─────────────────────────────────────────
function llm_reranker_init(env)
  committed_buffer = ''
  _logged          = false
  _cache           = {}
  _cache_size      = 0
  pcall(function()
    env.commit_conn = env.engine.context.commit_notifier:connect(function(ctx)
      local h = ctx.commit_history
      if h and not h:empty() then
        local last = h:back()
        if last and last.text then
          committed_buffer = (committed_buffer..last.text):sub(-200)
          -- 提交后清空缓存（上下文变了，旧缓存失效）
          _cache      = {}
          _cache_size = 0
        end
      end
    end)
  end)
end

function llm_reranker_fini(env)
  if env.commit_conn then
    pcall(function() env.commit_conn:disconnect() end)
  end
  committed_buffer = ''
  _cache           = {}
  _cache_size      = 0
end

-- ─── Context Tracker Processor ───────────────────────────
-- 通过监听按键事件捕获提交文本，解决 commit_notifier 不触发的问题
-- 原理：用户按空格/数字键选词后，commit_history 会新增条目
--       processor 在每次按键后检查 commit_history 变化

local _last_commit_text = ''  -- 上次已知的最新提交文本

local function read_latest_commit(env)
  -- 读取 commit_history 最新一条
  local text = nil
  pcall(function()
    local hist = env.engine.context.commit_history
    if hist and not hist:empty() then
      -- back() 返回最新的一条
      local entry = hist:back()
      if entry and entry.text then
        text = entry.text
      end
    end
  end)
  return text
end

function llm_context_tracker(key_event, env)
  -- kNoop = 不干预按键处理，只做旁观记录
  local kNoop = 2

  -- 只在可能触发提交的按键之后检查
  -- 空格(32)、数字1-5(49-53)、回车(Return=65293)
  local keycode = key_event.keycode
  local is_commit_key = (keycode == 32)                    -- 空格
    or (keycode >= 49 and keycode <= 53)                   -- 数字1-5
    or (keycode == 65293 or keycode == 65421)              -- Return/KP_Enter

  if is_commit_key then
    local latest = read_latest_commit(env)
    if latest and latest ~= _last_commit_text then
      -- 有新提交的文本
      _last_commit_text = latest
      committed_buffer = (committed_buffer .. latest):sub(-200)
      -- 提交后清空重排缓存（上下文变了）
      _cache      = {}
      _cache_size = 0
    end
  end

  return kNoop
end