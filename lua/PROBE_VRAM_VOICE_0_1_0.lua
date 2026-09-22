-- PROBE_VRAM_VOICE 0.1.0  --  **음성 중에** 안 쓰는 VRAM 창을 찾는다
--
-- 0.2.0 이 무엇을 말했나
-- ----------------------
--     프레임 2400 · 쓰인 워드 31620 / 32768 · 빈 창 0 곳
--
-- 항상 비어 있는 VRAM 은 **없다.**  그러니 "빈 자리를 찾아 쓴다" 는 길은 닫혔다.
--
-- 그런데 `$5B80` 때와 같은 모양이다.  거기도 항상 비지는 않았고, **음성 중에만**
-- 통째로 비었다 (134/134).  자막은 음성이 나올 때만 뜨므로 그것으로 충분했다.
--
-- VRAM 도 같은 질문을 해야 한다:
--
--     항상 비었나?           -> 아니다 (0.2.0 이 답했다)
--     음성 중에 안 쓰이나?    -> ★ 이 판이 재는 것
--
-- 다만 RAM 과 다른 점이 하나 있다
-- --------------------------------
-- 스크립트 스택은 음성이 끝나면 게임이 다시 쓰므로 되돌릴 필요가 없었다.
-- VRAM 은 그렇지 않다 -- 메뉴 하이라이트가 **음성이 끝난 뒤에도 계속 깨져** 있었다.
-- 게임이 그 자리를 다시 안 그린다는 뜻이다.
--
-- 그래서 두 가지를 같이 잰다:
--
--     A  음성 중에 안 바뀌는 창        -> 빌려 쓸 수 있는 후보
--     B  그 창이 음성이 끝난 뒤 게임에 의해 다시 쓰이는가
--        쓰이면 그냥 빌려도 되고, 안 쓰이면 **우리가 되돌려야 한다**
--
-- 무엇을 재나
--   워드 4 개마다 하나씩 떠서, 음성 중 프레임과 음성 밖 프레임을 따로 표시한다.
--   음성 중에 한 번도 안 바뀐 연속 창을 길이순으로 낸다.
--
--     9 글자 -> $240 워드
--
-- ★ 반드시 지나갈 것: **컷신(음성)을 여러 개** · 그 사이 메뉴 열고 닫기
-- 아무것도 안 쓴다.
-- 출력  로그 + C:/snatcher/dump/probe_vram_voice_0_1_0_<날짜>.tsv

local VRAM = emu.memType.pceVideoRam
local WORDS = 0x8000
local STRIDE = 4
local NEED = 0x240

local in_voice = {}                   -- 음성 중에 바뀐 워드
local out_voice = {}                  -- 음성 밖에서 바뀐 워드
local snap = {}
local frames, voice_frames, samples = 0, 0, 0
local last_total = -1
local lines = {}
local function say(s) emu.log(s); lines[#lines+1] = s end

local function sample(playing)
  samples = samples + 1
  local target = playing and in_voice or out_voice
  for w = 0, WORDS - 1, STRIDE do
    local v = emu.read(w, VRAM) or 0
    local was = snap[w]
    if was == nil then
      snap[w] = v
    elseif was ~= v then
      snap[w] = v
      for i = 0, STRIDE - 1 do target[w + i] = frames end
    end
  end
end

local function windows()
  local out, start = {}, nil
  for w = 0, WORDS - 1 do
    if in_voice[w] then
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

-- 그 창이 음성 밖에서는 게임이 다시 쓰는가 -- 되돌려야 하는지 가른다
local function rewritten(from, to)
  local n = 0
  for w = from, to do if out_voice[w] then n = n + 1 end end
  return n
end

local function flush()
  local f = io.open(string.format('C:/snatcher/dump/probe_vram_voice_0_1_0_%s.tsv',
                                  os.date('%Y%m%d_%H%M%S')), 'w')
  if not f then return end
  f:write('line\n')
  for _, l in ipairs(lines) do f:write(l .. '\n') end
  f:write('\n음성 중 안 쓰는 창\nfrom\tto\twords\tglyphs\trewritten_outside\n')
  for _, h in ipairs(windows()) do
    f:write(string.format('%04X\t%04X\t%d\t%d\t%d\n', h[1], h[2], h[3],
                          math.floor(h[3] / 0x40), rewritten(h[1], h[2])))
  end
  f:close()
end

emu.addEventCallback(function()
  frames = frames + 1
  if frames % 10 ~= 0 then return end

  local s = emu.getState()
  local playing = s['cdrom.adpcm.playing'] == true
  if playing then voice_frames = voice_frames + 1 end
  sample(playing)

  if samples % 60 == 0 then
    local list = windows()
    local total = 0
    for _, h in ipairs(list) do total = total + h[3] end
    if last_total < 0 or total < last_total then
      say(string.format('--- 프레임 %d · 음성 표본 %d --- 음성 중 안 쓰는 창 %d 곳 %d 워드%s',
            frames, voice_frames, #list, total,
            last_total < 0 and '' or string.format('  (%d 줄었다)', last_total - total)))
      for i = 1, math.min(5, #list) do
        local h = list[i]
        local back = rewritten(h[1], h[2])
        say(string.format('      $%04X-$%04X  %d 워드 = %d 글자   음성 밖 재사용 %d 워드%s',
              h[1], h[2], h[3], math.floor(h[3] / 0x40), back,
              back > h[3] / 2 and '  <- 게임이 다시 그린다.  되돌릴 필요 적다' or ''))
      end
      last_total = total
    end
    flush()
  end
end, emu.eventType.startFrame)

emu.log('PROBE_VRAM_VOICE 0.1.0 loaded  --  아무것도 안 쓴다')
emu.log('  항상 빈 VRAM 은 없다 (0.2.0).  음성 중에 안 쓰는 자리를 찾는다')
emu.log('  ★ 컷신(음성)을 여러 개 지날 것 · 사이사이 메뉴도 열어볼 것')
emu.log('  9 글자에 $240 워드 · 음성 밖 재사용이 많으면 되돌릴 필요가 적다')
