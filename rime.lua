-- rime.lua
-- rime-llm-reranker · 改进版 v3 + 训练数据采集（精确匹配 & 纯净数据）

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
    _socket_ok   = true
    _socket_http = m1
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
    elseif t=='string' then return '"'..esc(x)..'"'
    elseif t=='table'  then
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
      url    = url,
      method = 'POST',
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
    local cmd = string.format(
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
    enabled      = gb('llm_reranker/enabled', true),
    endpoint     = gs('llm_reranker/endpoint', 'http://localhost:8000/v1/chat/completions'),
    model        = gs('llm_reranker/model',    'Qwen3.5-0.8B-MLX-bf16'),
    max_cands    = gi('llm_reranker/max_candidates', 5),
    timeout      = gn('llm_reranker/timeout', 0.5),
    ctx_len      = gi('llm_reranker/context_length', 60),
    temperature  = gn('llm_reranker/temperature', 0.0),
    max_tokens   = gi('llm_reranker/max_tokens', 20),
    min_syllables   = gi('llm_reranker/min_syllables', 2),
    min_ctx_len     = gi('llm_reranker/min_context_len', 0),
    max_preedit_len = gi('llm_reranker/max_preedit_len', 10),
    max_rerank_pos  = gi('llm_reranker/max_rerank_pos', 5),
    system_prompt   = gs('llm_reranker/system_prompt',
      '你是中文输入法候选词排序助手。'..
      '根据对话历史和当前输入，从候选词列表中选出最符合语境的词。'..
      '按优先级从高到低列出最多5个候选词，用顿号分隔，不要任何解释。'),
    fallback = gb('llm_reranker/fallback_on_error', true),
    debug    = gb('llm_reranker/debug_log', false),
    collect_train = gb('llm_reranker/collect_training_data', true),
  }
end

-- ─── 调试日志 ─────────────────────────────────────────────
local LOG_PATH   = _home..'/Library/Rime/rime_llm.log'

local function dlog(cfg, msg)
  if not cfg.debug then return end
  local f = io.open(LOG_PATH,'a')
  if f then f:write(os.date('%H:%M:%S')..' '..msg..'\n'); f:close() end
end

-- ─── 训练数据日志 ─────────────────────────────────────────
local TRAIN_LOG_PATH = _home..'/Library/Rime/rime_train.jsonl'

-- UTF-8 安全截断
local function utf8_tail(s, max_bytes)
  if #s <= max_bytes then return s end
  local start = #s - max_bytes + 1
  while start <= #s and s:byte(start) >= 0x80 and s:byte(start) <= 0xBF do
    start = start + 1
  end
  return s:sub(start)
end

local function log_train_pair(cfg, context, pinyin, positive, negative, source)
  if not cfg.collect_train then return end
  if not positive or not negative or positive == negative then return end
  if positive == '' or negative == '' then return end

  local record = json_encode({
    context  = context,
    pinyin   = pinyin,
    positive = positive,
    negative = negative,
    source   = source,
  })
  if not record then return end

  local f = io.open(TRAIN_LOG_PATH, 'a')
  if f then
    f:write(record..'\n')
    f:close()
  end
end

-- 记录 LLM 排序的所有相邻 pair（仅当 preedit 不是纯简拼时才记录）
local function log_llm_ranking_pairs(cfg, context, pinyin, ranked_texts)
  if not cfg.collect_train then return end
  if not ranked_texts or #ranked_texts < 2 then return end

  -- 排除纯简拼（仅由辅音字母组成，如 xz / bj / cx）
  if pinyin:lower():match('^[bcdfghjklmnpqrstxyz]+$') then
    dlog(cfg, 'TRAIN: skip jianpin '..pinyin)
    return
  end

  for i = 1, #ranked_texts - 1 do
    log_train_pair(cfg, context, pinyin, ranked_texts[i], ranked_texts[i+1], 'llm_rank')
  end
end

-- ─── 音节数估算 ──────────────────────────────────────────
local INITIALS = {
  'zh','ch','sh',
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
    for _, ini in ipairs(INITIALS) do
      if s:sub(i, i+#ini-1) == ini then
        count = count + 1
        i = i + #ini
        while i <= #s and s:sub(i,i):match('[aeiouüv]') do i = i + 1 end
        if s:sub(i,i+1) == 'ng' then i = i + 2
        elseif s:sub(i,i) == 'n' then i = i + 1 end
        matched = true
        break
      end
    end
    if not matched then
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

-- ─── 候选词匹配（仅精确匹配） ──────────────────────────────
local function find_match(list, word)
  if not word or word == '' then return nil end
  word = word:match('^%s*(.-)%s*$') or word
  for i, c in ipairs(list) do
    if c.text == word then return i end
  end
  return nil
end

-- ─── 解析 LLM 响应，只保留精确匹配的词，返回 (best_idx, ranked_texts) ──
local function extract_ranking(response, list)
  local content = json_extract_content(response)
  if not content then return nil, {} end

  local ranked_texts = {}
  local seen = {}
  for word in content:gmatch('[^、，,；;\n]+') do
    word = word:match('^%s*(.-)%s*$') or word
    word = word:gsub('^[%d①②③%.、。%s]+', '')
    word = word:match('^%s*(.-)%s*$') or word
    if word ~= '' and not seen[word] then
      local idx = find_match(list, word)
      if idx then
        table.insert(ranked_texts, list[idx].text)
        seen[word] = true
      else
        -- 任何无法精确匹配的词，停止解析后续词（避免错误累积）
        break
      end
    end
  end

  local best_idx = nil
  if #ranked_texts > 0 then
    for i, c in ipairs(list) do
      if c.text == ranked_texts[1] then best_idx = i; break end
    end
  end

  return best_idx, ranked_texts
end

-- ─── LLM 调用 ────────────────────────────────────────────
local function query_llm(cfg, committed, preedit, cand_texts)
  local user_content
  if committed ~= '' then
    user_content =
      '对话历史：「'..committed..'」\n'..
      '当前输入拼音：「'..preedit..'」\n'..
      '候选词：'..table.concat(cand_texts,'、')..'\n'..
      '按最符合对话语境的顺序列出前5个候选词（顿号分隔）：'
  else
    user_content =
      '输入拼音：「'..preedit..'」\n'..
      '候选词：'..table.concat(cand_texts,'、')..'\n'..
      '按最可能的顺序列出前5个候选词（顿号分隔）：'
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

local _cache      = {}
local _cache_size = 0
local CACHE_MAX   = 300

local _querying = {}

-- 训练快照：展示给用户的候选列表（已排序后的 top 部分）
local _pending_snapshot = nil

-- ─── 拼音完整性判断 ──────────────────────────────────────

-- 纯简拼检测
local function is_jianpin(preedit)
  return preedit:lower():match('^[bcdfghjklmnpqrstxyz]+$') ~= nil
end

-- 完整韵尾列表
local COMPLETE_ENDINGS = {
  'ang','eng','ing','ong','ung',
  'ian','uan','uen','van',
  'an','en','in','un','vn',
  'ng','er',
}
local function preedit_ends_incomplete(preedit)
  if not preedit or preedit == '' then return true end
  local s = preedit:lower()
  if is_jianpin(s) then return false end
  if s:sub(-1):match('[aeiouüv]') then return false end
  for _, ending in ipairs(COMPLETE_ENDINGS) do
    if #s >= #ending and s:sub(-#ending) == ending then return false end
  end
  return true
end

-- ─── Rime filter 入口 ────────────────────────────────────
function llm_reranker(input, env)
  local all = {}
  for cand in input:iter() do table.insert(all, cand) end

  local cfg = get_config(env)

  if not _logged and cfg.debug then
    dlog(cfg, 'v3 started, backend: '..(_socket_ok and 'luasocket' or 'curl'))
    _logged = true
  end

  if not cfg.enabled or #all < 2 then
    for _,c in ipairs(all) do yield(c) end
    return
  end

  local preedit = ''
  pcall(function()
    local p = env.engine.context:get_preedit()
    if p then preedit = p.text or '' end
  end)

  local syllables = count_syllables(preedit)
  if syllables < cfg.min_syllables then
    for _,c in ipairs(all) do yield(c) end
    return
  end

  local skip = false
  local ctx_bytes = committed_buffer:len()
  if ctx_bytes < cfg.min_ctx_len then
    skip = true
    dlog(cfg, 'SKIP: no context ('..ctx_bytes..' bytes < '..cfg.min_ctx_len..')')
  end

  local preedit_len = preedit:len()
  if preedit_len > cfg.max_preedit_len then
    skip = true
    dlog(cfg, 'SKIP: preedit too long ('..preedit_len..' > '..cfg.max_preedit_len..')')
  end

  local top, rest = {}, {}
  for i,c in ipairs(all) do
    if i <= cfg.max_cands then table.insert(top,c)
    else                       table.insert(rest,c) end
  end

  local idx = nil

  if not skip then
    local history_key = utf8_tail(committed_buffer, 60)
    local cache_key   = history_key..':'..preedit
    local cached      = _cache[cache_key]

    if cached == nil and not _querying[cache_key] then
      _querying[cache_key] = true

      local texts = {}
      for _,c in ipairs(top) do table.insert(texts, c.text) end

      local resp = nil
      local ctx_snapshot = utf8_tail(committed_buffer, cfg.ctx_len)
      if cfg.fallback then
        pcall(function()
          resp = (query_llm(cfg, ctx_snapshot, preedit, texts))
        end)
      else
        resp = (query_llm(cfg, ctx_snapshot, preedit, texts))
      end

      local raw_idx, ranked_texts = extract_ranking(resp or '', top)

      -- 训练数据记录：仅当拼音非中间态且非简拼时记录
      if is_jianpin(preedit) or not preedit_ends_incomplete(preedit) then
        log_llm_ranking_pairs(cfg, ctx_snapshot, preedit, ranked_texts)
      end

      if raw_idx and raw_idx > cfg.max_rerank_pos then
        dlog(cfg, string.format('FILTERED: rank %d > max %d, skip rerank',
          raw_idx, cfg.max_rerank_pos))
        raw_idx = nil
      end

      cached = raw_idx or false
      _querying[cache_key] = nil
      if _cache_size >= CACHE_MAX then _cache={}; _cache_size=0 end
      _cache[cache_key] = cached
      _cache_size = _cache_size + 1

      if cfg.debug then
        if cached and cached > 1 then
          dlog(cfg, 'RERANKED: '..top[1].text..' → '..top[cached].text)
        else
          dlog(cfg, 'NO_CHANGE: kept '..top[1].text)
        end
      end
    elseif _querying[cache_key] then
      dlog(cfg, 'skip: query in progress '..cache_key)
    else
      dlog(cfg, 'cache hit ['..tostring(cached)..'] '..cache_key)
    end

    if cached ~= false then idx = cached end
  end

  local ordered = reorder(top, idx)

  -- 保存快照用于 user_select 信号
  if cfg.collect_train then
    local ordered_texts = {}
    for _, c in ipairs(ordered) do table.insert(ordered_texts, c.text) end
    _pending_snapshot = {
      context       = utf8_tail(committed_buffer, cfg.ctx_len),
      pinyin        = preedit,
      ordered_texts = ordered_texts,
    }
  end

  for _,c in ipairs(ordered) do yield(c) end
  for _,c in ipairs(rest)    do yield(c) end
end

-- ─── init / fini ─────────────────────────────────────────
function llm_reranker_init(env)
  committed_buffer  = ''
  _logged           = false
  _cache            = {}
  _cache_size       = 0
  _querying         = {}
  _pending_snapshot = nil

  pcall(function()
    env.commit_conn = env.engine.context.commit_notifier:connect(function(ctx)
      local h = ctx.commit_history
      if h and not h:empty() then
        local last = h:back()
        if last and last.text then
          committed_buffer = utf8_tail(committed_buffer..last.text, 1200)
          _cache = {}
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
  committed_buffer  = ''
  _cache            = {}
  _cache_size       = 0
  _pending_snapshot = nil
end

-- ─── Context Tracker Processor（记录用户覆盖信号）─────────
local _last_commit_text = ''

local function read_latest_commit(env)
  local text = nil
  pcall(function()
    local hist = env.engine.context.commit_history
    if hist and not hist:empty() then
      local entry = hist:back()
      if entry and entry.text then text = entry.text end
    end
  end)
  return text
end

-- 查找词语在有序列表中的位置（从1开始）
local function index_of(list, word)
  for i, w in ipairs(list) do
    if w == word then return i end
  end
  return nil
end

function llm_context_tracker(key_event, env)
  local kNoop = 2

  local keycode = key_event.keycode
  local is_commit_key = (keycode == 32)
    or (keycode >= 49 and keycode <= 53)
    or (keycode == 65293 or keycode == 65421)

  if is_commit_key then
    local latest = read_latest_commit(env)
    if latest and latest ~= _last_commit_text then
      _last_commit_text = latest

      local snap = _pending_snapshot
      if snap and snap.ordered_texts and #snap.ordered_texts >= 2 then
        local user_pos = index_of(snap.ordered_texts, latest)
        local top1 = snap.ordered_texts[1]
        -- 只要用户选择的不是第一候选，就记录 pair (latest > top1)
        if user_pos and user_pos > 1 and latest ~= top1 then
          local record = json_encode({
            context  = snap.context,
            pinyin   = snap.pinyin,
            positive = latest,
            negative = top1,
            source   = 'user_select',
          })
          if record then
            local f = io.open(TRAIN_LOG_PATH, 'a')
            if f then f:write(record..'\n'); f:close() end
          end
        end
      end

      _pending_snapshot = nil
      committed_buffer = utf8_tail(committed_buffer .. latest, 1200)
      _cache = {}
      _cache_size = 0
    end
  end

  return kNoop
end
