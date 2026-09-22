-- PROBE_VRAM_FREE 0.2.0  --  KO 빌드에서 정말 안 쓰는 VRAM 창을 찾는다
--
-- 왜 다시 재나
-- ------------
-- 글리프를 워드 `$7900` 에 올렸더니 **메뉴 선택 하이라이트가 깨졌다.**
-- 스크립트를 안 켜면 깨끗하므로 원인은 우리 업로드다.
--
--     $7900-$7B3F   EXTEND 2026-08-23: "430 프레임 재업로드 0 회"
--                   -> 그것은 **원본 디스크** 기준이었다.  KO 빌드는 다르다
--
-- 기존 연구가 이미 경고하고 있었다:
--
--     STATE 2026-08-23: "VRAM $7B00 부터 슬롯 20 개 · **컷신마다 다름.
--                        상수로 박으면 안 됨**"
--     BREAKTHROUGH:     덤프 3 장 보고 $7B00 이 비었다고 했다가 뒤집혔다
--
-- 0.1.0 과 무엇이 다른가
-- ----------------------
-- 0.1.0 은 VRAM 쓰기 콜백을 걸려 했다.  메모리 타입 인자가 맞는지 확신할 수 없어
-- **표본 방식만** 쓴다.  주기적으로 내용을 떠서 바뀐 워드를 "쓰인다" 로 표시한다.
-- 순간 썼다 지운 것은 놓칠 수 있지만, 우리가 알고 싶은 것은 **점유**다.
--
-- 무엇을 재나
--   워드 4 개마다 하나씩 떠서 바뀌면 그 4 개를 통째로 표시한다.
--   한 번도 안 바뀐 **연속 창**을 길이순으로 낸다.
--
--     9 글자 -> $240 워드 (1,152 B)     지금 필요한 것
--    16 글자 -> $400 워드              한 줄 최대
--
-- ★ 반드시 지나갈 것
--     **메뉴 열기/닫기** (여기서 깨졌다) · 대사창 · 이동 · 장면 전환
--     컷신(음성) 여러 개 · 세이브/로드
--
-- 아무것도 안 쓴다.
-- 출력  로그 + C:/snatcher/dump/probe_vram_free_0_2_0_<날짜>.tsv

local VRAM = emu.memType.pceVideoRam
local WORDS = 0x8000                  -- 32K 워드
local STRIDE = 4                      -- 4 워드마다 하나씩 뜬다
local EVERY = 20                      -- 이만큼 프레임마다 한 번
local NEED = 0x240                    -- 9 글자.  이보다 짧은 창은 안 낸다

local used = {}                       -- 워드 -> 처음 바뀐 프레임
local snap = {}
local frames, samples, marked = 0, 0, 0
local last_total = -1
local lines = {}
local function say(s) emu.log(s); lines[#lines+1] = s end

local function sample()
  samples = samples + 1
  for w = 0, WORDS - 1, STRIDE do
    local v = emu.read(w, VRAM) or 0
    local was = snap[w]
    if was == nil then
      snap[w] = v
    elseif was ~= v then
      snap[w] = v
      for i = 0, STRIDE - 1 do
        if not used[w + i] then used[w + i] = frames; marked = marked + 1 end
      end
    end
  end
end

local function windows()
  local out, start = {}, nil
  for w = 0, WORDS - 1 do
    if used[w] then
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
  local f = io.open(string.format('C:/snatcher/dump/probe_vram_free_0_2_0_%s.tsv',
                                  os.date('%Y%m%d_%H%M%S')), 'w')
  if not f then return end
  f:write('line\n')
  for _, l in ipairs(lines) do f:write(l .. '\n') end
  f:write('\n빈 창 (워드)\nfrom\tto\twords\tglyphs\n')
  for _, h in ipairs(windows()) do
    f:write(string.format('%04X\t%04X\t%d\t%d\n', h[1], h[2], h[3],
                          math.floor(h[3] / 0x40)))
  end
  f:close()
end

emu.addEventCallback(function()
  frames = frames + 1
  if frames % EVERY ~= 0 then return end
  sample()

  if samples % 30 == 0 then
    local list = windows()
    local total = 0
    for _, h in ipairs(list) do total = total + h[3] end
    if last_total < 0 or total < last_total then
      say(string.format('--- 프레임 %d (표본 %d) --- 쓰인 워드 %d · 빈 창 %d 곳 %d 워드%s',
            frames, samples, marked, #list, total,
            last_total < 0 and '' or string.format('  (%d 줄었다)', last_total - total)))
      for i = 1, math.min(5, #list) do
        say(string.format('      $%04X-$%04X  %d 워드 = %d 글자',
              list[i][1], list[i][2], list[i][3], math.floor(list[i][3] / 0x40)))
      end
      say(string.format('      우리가 쓰던 $7900-$7B3F : %s',
            used[0x7900] and '★ 쓰인다' or '아직 깨끗'))
      last_total = total
    end
    flush()
  end
end, emu.eventType.startFrame)

emu.log('PROBE_VRAM_FREE 0.2.0 loaded  --  아무것도 안 쓴다')
emu.log('  $7900 은 원본 기준 값이었다.  KO 빌드에서 다시 잰다')
emu.log('  ★ 메뉴를 여러 번 열고 닫을 것 -- 거기서 깨졌다')
emu.log('  9 글자에 $240 워드가 필요하다')
