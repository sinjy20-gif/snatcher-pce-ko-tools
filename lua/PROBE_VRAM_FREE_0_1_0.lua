-- PROBE_VRAM_FREE 0.1.0  --  KO 빌드에서 정말 안 쓰는 VRAM 창을 찾는다
--
-- 왜
-- --
-- 자막 패턴을 워드 `$7900` 에 올렸더니 대사창 글꼴이 깨졌다.  그 주소는
-- **원본 디스크**에서 나온 값이다 (EXTEND §: "$7900-$7B3F · 430 프레임 재업로드 0 회").
-- KO 빌드는 한글 글립을 VRAM 에 동적으로 올리므로 그 자리가 이미 쓰인다.
--
-- 기존 연구가 이미 경고하고 있었다:
--
--     STATE 2026-08-23 §: "VRAM $7B00 부터 슬롯 20 개 · **컷신마다 다름.
--                          상수로 박으면 안 됨**"
--     BREAKTHROUGH §:     덤프 3 장을 보고 $7B00 이 비었다고 판단했다가 뒤집혔다
--
-- 그러니 이번엔 **길게, KO 빌드에서** 잰다.
--
-- 무엇을 재나
--   VRAM 워드마다 "한 번이라도 쓰였나" 를 표로 쌓고, 한 번도 안 쓰인 **연속 창**을
--   길이순으로 낸다.  우리에게 필요한 것은 글자 수 x $40 워드다.
--
--     16 글자 -> $400 워드 (2048 B)      한 줄 최대
--      9 글자 -> $240 워드               지금까지 띄워 본 길이
--
--   창이 줄어드는 순간마다 찍는다 -- 어느 장면이 깎는지 보이게.
--
-- ★ 반드시 지나갈 것
--     대사창 · 메뉴 · 이동 · 장면 전환 · **컷신(음성)** · 세이브/로드
--   컷신마다 다르다고 했으므로 컷신을 여러 개 지나야 한다.
--
-- 아무것도 안 쓴다.
-- 출력  로그 + C:/snatcher/dump/probe_vram_free_0_1_0_<날짜>.tsv

local VRAM = emu.memType.pceVideoRam
local WORDS = 0x8000                  -- 32K 워드
local NEED = 0x240                    -- 9 글자.  이보다 짧은 창은 안 낸다

local written = {}
local frames, marks = 0, 0
local last_total = -1
local lines = {}
local function say(s) emu.log(s); lines[#lines+1] = s end

-- VRAM 콜백이 바이트 주소로 오면 워드로 접는다
local function mark(address)
  local word = address
  if word >= WORDS then word = math.floor(word / 2) end
  if word < WORDS and not written[word] then
    written[word] = frames
    marks = marks + 1
  end
end

local ok = pcall(function()
  emu.addMemoryCallback(mark, emu.callbackType.write, 0, WORDS * 2 - 1, nil, VRAM)
end)
if not ok then
  emu.log('★ VRAM 쓰기 콜백을 못 걸었다 -- 표본 방식으로 돌린다')
end

-- 콜백이 안 되면 주기적으로 내용을 떠서 바뀐 워드를 표시한다
local snapshot = nil
local function sample()
  local now = {}
  for w = 0, WORDS - 1, 8 do          -- 8 워드마다 하나씩 (전수는 너무 느리다)
    now[w] = emu.read(w, VRAM) or 0
  end
  if snapshot then
    for w, v in pairs(now) do
      if snapshot[w] ~= v then
        for i = 0, 7 do mark(w + i) end   -- 표본 간격만큼 뭉개서 표시
      end
    end
  end
  snapshot = now
end

local function windows()
  local out, start = {}, nil
  for w = 0, WORDS - 1 do
    if written[w] then
      if start and w - start >= NEED then out[#out+1] = { start, w - 1, w - start } end
      start = nil
    elseif not start then
      start = w
    end
  end
  if start and WORDS - start >= NEED then out[#out+1] = { start, WORDS - 1, WORDS - start } end
  table.sort(out, function(p, q) return p[3] > q[3] end)
  return out
end

local function flush()
  local f = io.open(string.format('C:/snatcher/dump/probe_vram_free_0_1_0_%s.tsv',
                                  os.date('%Y%m%d_%H%M%S')), 'w')
  if not f then return end
  f:write('line\n')
  for _, l in ipairs(lines) do f:write(l .. '\n') end
  f:write('\n빈 창 (워드)\nfrom\tto\twords\tglyphs\n')
  for _, h in ipairs(windows()) do
    f:write(string.format('%04X\t%04X\t%d\t%d\n', h[1], h[2], h[3], math.floor(h[3] / 0x40)))
  end
  f:close()
end

emu.addEventCallback(function()
  frames = frames + 1
  if not ok and frames % 30 == 0 then sample() end

  if frames % 600 == 0 then
    local list = windows()
    local total = 0
    for _, h in ipairs(list) do total = total + h[3] end
    if last_total < 0 or total < last_total then
      say(string.format('--- %d --- 쓰인 워드 %d · 빈 창 %d 곳 %d 워드%s',
            frames, marks, #list, total,
            last_total < 0 and '' or string.format('  (%d 줄었다)', last_total - total)))
      for i = 1, math.min(4, #list) do
        say(string.format('      $%04X-$%04X  %d 워드 = %d 글자',
              list[i][1], list[i][2], list[i][3], math.floor(list[i][3] / 0x40)))
      end
      last_total = total
    end
    flush()
  end
end, emu.eventType.startFrame)

emu.log('PROBE_VRAM_FREE 0.1.0 loaded  --  아무것도 안 쓴다')
emu.log('  $7900 은 원본 기준 값이었다.  KO 빌드에서 다시 잰다')
emu.log('  ★ 대사창 · 메뉴 · 컷신(음성) 여러 개 · 세이브/로드를 지날 것')
emu.log('  9 글자에 $240 워드 · 16 글자에 $400 워드가 필요하다')
