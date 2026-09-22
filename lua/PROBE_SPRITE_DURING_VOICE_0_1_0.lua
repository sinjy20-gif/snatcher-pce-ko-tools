-- PROBE_SPRITE_DURING_VOICE 0.1.0  --  음성이 나올 때 게임이 몇 칸을 쓰나
--
-- 왜
-- --
-- PROBE_SPRITE_BUDGET 0.1.0 이 "게임 최대 19 칸" 을 냈고 나는 그것을 예산으로 썼다.
-- **틀렸다.**  그 판은 4200 프레임짜리 한 장면이었고, 스프라이트를 많이 쓰는
-- 화면에서는 40~60 칸이 찬다 (사용자가 스프라이트 뷰어로 확인).
-- 표본 하나를 분포로 쓴 것이다 -- 이 프로젝트가 이미 두 번 밟은 함정이다.
--
-- 그리고 숫자만의 문제가 아니다.  우리는 $601E 에서 **게임보다 먼저** 민다
-- (그래야 그림·초상화 앞에 그려진다).  그러면 게임 예산을 그만큼 뺏는다:
--
--     스텁이 $17 = $3F 로 세우고 우리가 N 개를 민다 -> 게임은 63-N 을 받는다
--     게임이 56 칸을 원하는데 우리가 19 를 가져가면 게임 스프라이트가 잘린다
--
-- 다만 **자막은 음성이 나올 때만 뜬다.**  스프라이트가 빽빽한 화면이 무음이면
-- 우리와 무관하다.  그래서 물어야 할 것은 "게임 최대" 가 아니라
-- **"음성 재생 중 게임이 몇 칸을 쓰나"** 다.
--
-- 무엇을 재나
--   프레임마다 SATB 64 칸에서 살아 있는 엔트리 수를 센다.
--   ADPCM 재생 중 · CD-DA 재생 중 · 무음을 갈라서 분포를 낸다.
--   자막 N 자를 넣을 여유가 있는 프레임 비율도 같이 낸다.
--
-- 아무것도 안 쓴다.  **여러 장면을 두루 지나갈 것** -- 그게 이 판의 요점이다.
--
-- 출력  로그 + C:/snatcher/dump/probe_sprite_during_voice_0_1_0_<날짜>.tsv

local MEM, VRAM = emu.memType.pceMemory, emu.memType.pceVideoRam
local SATB_BYTE = 0x2000
local WANT = { 10, 16, 19, 24 }        -- 자막 글자 수 후보

local frames = 0
local last_sector = -1
local buckets = {
  adpcm = { n = 0, sum = 0, max = 0, hist = {} },
  cdda  = { n = 0, sum = 0, max = 0, hist = {} },
  quiet = { n = 0, sum = 0, max = 0, hist = {} },
}
local fits = {}
for _, w in ipairs(WANT) do fits[w] = { adpcm = 0, cdda = 0 } end
local lines = {}
local function say(s) emu.log(s); lines[#lines+1] = s end

local function rb(a, t) return emu.read(a, t or MEM) or 0 end
local function vw(o) return rb(o, VRAM) + rb(o + 1, VRAM) * 256 end

-- 살아 있는 엔트리 수.  네 워드가 다 0 이면 빈 칸이다 (게임이 0 으로 채운다)
local function live()
  local n = 0
  for s = 0, 63 do
    local o = SATB_BYTE + s * 8
    if not (vw(o) == 0 and vw(o + 2) == 0 and vw(o + 4) == 0 and vw(o + 6) == 0) then
      n = n + 1
    end
  end
  return n
end

local function record(b, n)
  b.n = b.n + 1
  b.sum = b.sum + n
  if n > b.max then b.max = n end
  local slot = math.floor(n / 8) * 8
  b.hist[slot] = (b.hist[slot] or 0) + 1
end

local function histline(b)
  local out = {}
  for slot = 0, 56, 8 do
    local c = b.hist[slot] or 0
    if c > 0 then out[#out+1] = string.format('%d-%d:%d', slot, slot + 7, c) end
  end
  return table.concat(out, ' ')
end

emu.addEventCallback(function()
  frames = frames + 1
  local ok, s = pcall(emu.getState)
  if not ok or not s then return end

  local n = live()
  local adpcm = s['cdrom.adpcm.playing'] == true
  -- CD-DA 는 "멈춰 있어도 참" 이 되면 안 된다.
  -- endSector 만 보면 정지 상태에서도 참이 되므로, **재생 위치가 실제로
  -- 움직이는지**로 판정한다.  75 섹터/초라 프레임마다 1~2 씩 오른다.
  local sector = s['cdrom.audioPlayer.currentSector']
  local cdda = false
  if type(sector) == 'number' then
    sector = math.floor(sector)
    cdda = (last_sector >= 0) and (sector > last_sector) and (sector - last_sector < 8)
    last_sector = sector
  else
    last_sector = -1
  end

  if adpcm then
    record(buckets.adpcm, n)
    for _, w in ipairs(WANT) do if n + w <= 64 then fits[w].adpcm = fits[w].adpcm + 1 end end
  elseif cdda then
    record(buckets.cdda, n)
    for _, w in ipairs(WANT) do if n + w <= 64 then fits[w].cdda = fits[w].cdda + 1 end end
  else
    record(buckets.quiet, n)
  end

  if frames % 900 == 0 then
    say(string.format('--- %d 프레임 ---', frames))
    for _, name in ipairs({ 'adpcm', 'cdda', 'quiet' }) do
      local b = buckets[name]
      if b.n > 0 then
        say(string.format('  %-5s %6d 프레임 · 평균 %5.1f · 최대 %2d 칸   %s',
              name, b.n, b.sum / b.n, b.max, histline(b)))
      end
    end
    local va, vc = buckets.adpcm.n, buckets.cdda.n
    if va > 0 or vc > 0 then
      say('  음성 중 자막이 들어갈 여유가 있는 프레임 비율')
      for _, w in ipairs(WANT) do
        local a = va > 0 and (fits[w].adpcm * 100.0 / va) or 0
        local c = vc > 0 and (fits[w].cdda * 100.0 / vc) or 0
        say(string.format('    %2d 자   ADPCM %5.1f%%   CD-DA %5.1f%%', w, a, c))
      end
    end
    local f = io.open(string.format('C:/snatcher/dump/probe_sprite_during_voice_0_1_0_%s.tsv',
                                    os.date('%Y%m%d_%H%M%S')), 'w')
    if f then
      f:write('line\n')
      for _, l in ipairs(lines) do f:write(l .. '\n') end
      f:close()
    end
  end
end, emu.eventType.startFrame)

emu.log('PROBE_SPRITE_DURING_VOICE 0.1.0 loaded  --  아무것도 안 쓴다')
emu.log('  음성 재생 중 게임이 SATB 를 몇 칸 쓰는지 분포로 낸다')
emu.log('  ★ 여러 장면을 두루 지나갈 것.  스프라이트가 많은 화면도 꼭 포함할 것')
