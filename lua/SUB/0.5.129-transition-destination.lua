-- SUB 0.5.129 -- 조각 전환 프레임의 쓰기가 어디로 가는지 (분류가 안 죽는 판)
--
-- ★ 같은 실수를 네 번 했다.  이번엔 구조로 막는다
-- ---------------------------------------------------------------------------
-- 0.5.121·122·123 은 우리 자리 경계를 **직전 프레임 끝**의 control block 으로 잡아
-- regLo=-1 이 됐다.  0.5.128 은 쓰기 시점에 읽게 고쳤는데도 죽었다 --
-- **전환 프레임에는 $5D34/$5D35 가 0 이다.**  base 는 복원 직전에만 채워진다.
--
-- 그래서 이 판은:
--     1. base 를 **끈적이게(sticky)** 들고 있는다.  마지막으로 본 0 아닌 값을 쓴다
--     2. 그래도 **모든 쓰기를 구간에 넣는다.**  분류 불가 칸을 없앤다
--        bat / satb / bg / low / our / high -- 어디에도 안 걸리는 주소가 없다
--     3. 구간마다 min/max 를 찍는다.  경계가 틀려도 원자료로 되짚을 수 있다
--
-- 0.5.128 이 남긴 것
-- ---------------------------------------------------------------------------
--     hits=111        SATB 256 word · 슬롯 64 개 전부   게임의 정상 SATB 갱신
--     hits=585~1499   SATB 0 word · 슬롯 0 개           글리프 업로드 프레임
--
-- ★ 글리프를 올리는 프레임마다 게임의 SATB 갱신이 $1000 에서 **사라진다.**
--   복원 프레임에서 본 것과 같은 패턴이다 (0.5.122: satb 235~245 -> 28~36).
--
-- 가설 -- 아직 확인 안 됨
-- ---------------------------------------------------------------------------
-- MAWR 탈취가 복원 때만이 아니라 **글리프 업로드 때도** 일어난다면, 게임의 SATB
-- 256 word 가 업로드 끝 지점으로 흘러간다.  0.5.126 은 $15=0(복원 종료)에서만
-- MAWR 을 되돌렸으므로 전환은 손도 안 댔다.  개선이 0 이었던 이유가 이것일 수 있다.
--
-- ★ 이 판은 그 가설을 세우지 않는다.  **256 word 가 어디로 가는지만** 본다.
--
-- 판정
-- ---------------------------------------------------------------------------
--     전환 프레임에 256 word 가 우리 글리프 자리 근처로 간다
--         ★ 복원과 같은 사슬이 전환에서도 돈다.  MAWR 을 두 곳 다 되돌려야 한다
--     전환 프레임에 256 word 가 $1000 으로 정상 도착
--         SATB 는 무사하다.  증상 1 의 원인은 다른 것
--     전환 프레임에 256 word 가 아예 없다
--         게임이 그 프레임에 SATB 를 안 쓴 것이다.  그것 자체가 사실 (닫지 말 것)
--
-- ★ 화면에 아무것도 안 그린다.  게임을 한 바이트도 안 고친다.  개입 없음.
--
--   BIOS  build/patch/0.4.6.68/Syscard3_galmuri_0.4.6.68.pce
--   CUE   build/patch/0.4.6.68/Snatcher CD-ROMantic (Japan) [KO].cue
--   Power Cycle -> 이 파일만 로드
--   ★ ADPCM_003078_6800_0E ('금일부로 JUNKER로 임명된' -> '길리언 시드다만.')
--     조각 1 이 16 칸, 조각 2 가 9 칸이라 슬롯 9~15 가 문제 구간이다
--
-- 산출물  C:/snatcher/dump/transition_dest_0_5_129_<시각>.tsv

local MEM, CPU = emu.memType.pceMemory, emu.cpuType.pce

local ENGINE_LO, ENGINE_HI = 0x5B80, 0x5E1F
local CTL_VRAM_LO, CTL_VRAM_HI = 0x5D34, 0x5D35
local STATE_ADDR = 0x7FDF

local REGION_WORDS = 1216
local IDLE_HITS = 40
local BIG_HITS  = 4000
local MAX_SETS  = 64
local SAMPLE_EVERY = 32

local STAMP = os.date('%Y%m%d_%H%M%S')
local PATH  = 'C:/snatcher/dump/transition_dest_0_5_129_' .. STAMP .. '.tsv'
local out   = assert(io.open(PATH, 'w'))
out:write('frame\tkind\tstate\tctl_base\tsticky_base\thits\ttotal\t'
       .. 'bat\tsatb\tbg\tlow\tour\thigh\t'
       .. 'top\ttop_n\ttop_lo\ttop_hi\ttop_first\ttop_last\t'
       .. 'sets_n\tsets_trunc\tset_list\n')

local function say(f, ...) emu.log(string.format(f, ...)) end
local function rd(a)
  local ok, v = pcall(emu.read, a, MEM)
  return (ok and type(v) == 'number') and v or -1
end

local LINE_KEY
local function scanline()
  local ok, s = pcall(emu.getState)
  if not ok or not s then return -1 end
  if LINE_KEY == nil then
    LINE_KEY = false
    for _, k in ipairs({ 'vdc.scanline', 'scanline', 'vdc.vCounter', 'ppu.scanline' }) do
      if type(s[k]) == 'number' then LINE_KEY = k; break end
    end
  end
  if LINE_KEY == false then return -1 end
  local v = s[LINE_KEY]
  return type(v) == 'number' and math.floor(v) or -1
end

-- ★ 끈적이는 base.  0 이 아닌 값을 본 적이 있으면 계속 그것을 쓴다
local stickyBase = -1
local function refreshBase()
  local b = (rd(CTL_VRAM_HI) << 8) | rd(CTL_VRAM_LO)
  if b > 0 then stickyBase = b end
  return b
end

local ZONES = { 'bat', 'satb', 'bg', 'low', 'our', 'high' }
local z = {}
local function resetZones()
  z = {}
  for _, n in ipairs(ZONES) do z[n] = { n = 0, lo = -1, hi = -1, first = -1, last = -1 } end
end
resetZones()

-- ★ 어디에도 안 걸리는 주소가 없도록 짠다
local function zoneOf(a)
  if a <= 0x0FFF then return 'bat' end
  if a <= 0x10FF then return 'satb' end
  if stickyBase > 0 and a >= stickyBase and a < stickyBase + REGION_WORDS then
    return 'our'
  end
  if a <= 0x2BBF then return 'bg' end
  if stickyBase > 0 and a < stickyBase then return 'low' end
  return 'high'
end

local selReg, mawr, incr, pendLo = 0, 0, 1, 0
local function incrFrom(hi) local s = (hi >> 3) & 0x03
  return (s == 0) and 1 or (s == 1) and 32 or (s == 2) and 64 or 128 end

local hits, total = 0, 0
local setN, sets = 0, {}

emu.addMemoryCallback(function(address, value)
  local port = address & 3
  value = (value or 0) & 0xFF
  if port == 0 then selReg = value; return end
  if port == 2 then if selReg == 0x00 then pendLo = value end return end
  if selReg == 0x00 then
    mawr = ((value << 8) | pendLo) & 0xFFFF
    setN = setN + 1
    if #sets < MAX_SETS then
      sets[#sets + 1] = string.format('%04X@%d', mawr & 0x7FFF, scanline())
    end
  elseif selReg == 0x05 then
    incr = incrFrom(value)
  elseif selReg == 0x02 then
    local a = mawr & 0x7FFF
    local e = z[zoneOf(a)]
    e.n = e.n + 1
    if e.lo < 0 or a < e.lo then e.lo = a end
    if e.hi < 0 or a > e.hi then e.hi = a end
    if e.n == 1 or e.n % SAMPLE_EVERY == 0 then
      local l = scanline()
      if e.first < 0 then e.first = l end
      e.last = l
    end
    total = total + 1
    mawr = (mawr + incr) & 0xFFFF
  end
end, emu.callbackType.write, 0x0000, 0x0003, CPU, MEM)

emu.addMemoryCallback(function() hits = hits + 1 end,
  emu.callbackType.exec, ENGINE_LO, ENGINE_HI, CPU, MEM)

local frame, frames = 0, 0

emu.addEventCallback(function()
  frame = frame + 1
  local ctlBase = refreshBase()

  if hits > IDLE_HITS then
    frames = frames + 1
    local kind = (hits >= BIG_HITS) and '복원' or '전환추정'

    local topName, top = nil, nil
    for _, n in ipairs(ZONES) do
      if top == nil or z[n].n > top.n then topName, top = n, z[n] end
    end
    local trunc = (setN > MAX_SETS) and ('★' .. (setN - MAX_SETS) .. '개잘림') or 'no'

    out:write(string.format(
      '%d\t%s\t%d\t%04X\t%04X\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%s\t%d\t%04X\t%04X\t%d\t%d\t%d\t%s\t%s\n',
      frame, kind, rd(STATE_ADDR), ctlBase < 0 and 0 or ctlBase,
      stickyBase < 0 and 0 or stickyBase, hits, total,
      z.bat.n, z.satb.n, z.bg.n, z.low.n, z.our.n, z.high.n,
      topName, top.n, top.lo < 0 and 0 or top.lo, top.hi < 0 and 0 or top.hi,
      top.first, top.last, setN, trunc, table.concat(sets, ' ')))
    out:flush()

    say('%s f%d hits=%d 총%d  bat=%d satb=%d bg=%d low=%d our=%d high=%d  (sticky $%04X)',
        kind, frame, hits, total, z.bat.n, z.satb.n, z.bg.n, z.low.n, z.our.n, z.high.n,
        stickyBase < 0 and 0 or stickyBase)
    say('     최다 %s %d회 $%04X-$%04X line %d..%d · MAWR %d회(%s) [%s]',
        topName, top.n, top.lo < 0 and 0 or top.lo, top.hi < 0 and 0 or top.hi,
        top.first, top.last, setN, trunc, table.concat(sets, ' '))
  end

  hits, total, setN, sets = 0, 0, 0, {}
  resetZones()
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  out:close()
  say('0.5.129 끝 -- 기록 %d 프레임 · sticky base $%04X · 저장 %s',
      frames, stickyBase < 0 and 0 or stickyBase, PATH)
  if stickyBase < 0 then
    say('0.5.129 ⚠ control block base 를 한 번도 못 봤다.  our 구간이 무의미하다.'
        .. ' 그 칸으로 판정하지 말 것 -- high/low 의 min/max 를 볼 것')
  end
end, emu.eventType.scriptEnded)

say('SUB 0.5.129-transition-destination armed -- 순수 관측 · 게임 무수정 · 화면 무개입')
say('  base 를 끈적이게 들고, 모든 쓰기를 구간에 넣는다 (분류 불가 칸 없음)')
say('  묻는 것 : 전환 프레임에서 게임의 SATB 256 word 가 어디로 가는가')
say('  덤프 : ' .. PATH)
