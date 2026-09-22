-- SUB 0.5.120 -- 복원 프레임 안의 **순서**를 잰다 (쓰기 0 B)
--
-- 무엇을 묻나
-- ---------------------------------------------------------------------------
-- 0.5.117 로 wipe 가 슬롯을 지운 것은 확인됐다 (seen 22~23 · done 7~9).
-- 0.5.118 로 우리 자리를 BAT/SATB 가 참조하지 않는 것도 확인됐다.
-- 그런데 소유자 관측은 이렇다:
--
--     "다른 그림이 깨지는게 아니라 정확히 우리 자막이 사라질때 생기고 없어진다"
--
-- 즉 깨지는 것은 **우리 자막 자리**이고, 방아쇠는 **복원**이다.
-- 그러면 프레임 안에서 무엇이 어떤 순서로 일어나는지가 먼저다.
--
-- ★ 이 판은 기구를 세우지 않는다.  순서만 잰다.
--
-- 무엇을 재나
-- ---------------------------------------------------------------------------
-- VDC 포트만 보고 MAWR 그림자로 모든 VRAM 쓰기의 **목적지와 스캔라인**을 되살린다.
--
--     wipe      SATB($1000-$10FF)에 쓰는 첫/마지막 줄        (우리 슬롯 비우기)
--     restore   우리 자리 [base, base+1216) 에 쓰는 첫/마지막 줄
--     dvssr     DVSSR($13) 기입 줄                            (SATB 원본 주소 지정)
--
-- 그리고 각각이 활성 표시 구간(0..238)인지 VBlank(239..262)인지 같이 찍는다.
--
-- 읽는 법 -- 이 판이 답하는 것
-- ---------------------------------------------------------------------------
--     wipe_first < restore_first     wipe 가 먼저다 (설계대로)
--     wipe_first > restore_first     ★ 복원이 먼저 시작한다 -- 설계와 다르다
--     wipe 와 restore 가 같은 프레임  둘이 한 프레임 안에 붙어 있다
--     dvssr 줄이 wipe 보다 앞         이번 프레임 SATB 원본 지정은 wipe 이전이다
--
-- ★ 이 판이 **못** 답하는 것 (닫지 말 것)
-- ---------------------------------------------------------------------------
-- VDC 내부 스프라이트 RAM 이 그 순간 무엇을 들고 있는지는 안 보인다.
-- VRAM 의 SATB 는 읽히지만 **래치된 내부 사본**은 Lua 로 안 보인다.
-- 그래서 "그래서 화면에 보였다" 는 이 판으로 확정되지 않는다.
-- 여기서 나오는 것은 **순서 사실**뿐이고, 기구는 그 다음에 따로 세운다.
--
--     ⚠ DMA(SATB 자동전송)는 포트를 안 거치므로 안 잡힌다.
--       dvssr 은 "주소를 지정한 시점" 이지 "전송이 일어난 시점" 이 아니다.
--
-- ⚠ 증가폭 가정
--     CR($05)의 증가폭 비트를 읽되 못 보면 +1 로 본다.  로그에 같이 찍는다.
--     restore 쓰기 수가 1216 근처로 안 나오면 이 가정부터 의심할 것.
--
-- ★ 화면에 아무것도 안 그린다.  게임을 한 바이트도 안 고친다.
--
--   BIOS  build/patch/0.4.6.68/Syscard3_galmuri_0.4.6.68.pce
--   CUE   build/patch/0.4.6.68/Snatcher CD-ROMantic (Japan) [KO].cue
--   Power Cycle -> 이 파일만 로드 -> 0.5.117~119 와 같은 장면, 대사를 끝까지
--
-- 산출물  C:/snatcher/dump/restore_order_0_5_120_<시각>.tsv

local MEM, CPU = emu.memType.pceMemory, emu.cpuType.pce

local ENGINE_LO, ENGINE_HI = 0x5B80, 0x5E1F
local CTL_VRAM_LO, CTL_VRAM_HI = 0x5D34, 0x5D35
local CTL_WIPE_SEEN, CTL_WIPE_DONE = 0x5D32, 0x5D33
local STATE_ADDR = 0x7FDF

local REGION_WORDS = 1216
local SATB_LO, SATB_HI = 0x1000, 0x10FF

local LINES, DISPLAY_LAST = 263, 238
local BIG_HITS = 4000

local STAMP = os.date('%Y%m%d_%H%M%S')
local PATH  = 'C:/snatcher/dump/restore_order_0_5_120_' .. STAMP .. '.tsv'
local out   = assert(io.open(PATH, 'w'))
out:write('frame\tstate\tbase\texec_hits\tincr\t'
       .. 'wipe_n\twipe_first\twipe_last\twipe_where\t'
       .. 'rest_n\trest_first\trest_last\trest_where\t'
       .. 'dvssr_n\tdvssr_first\tdvssr_where\t'
       .. 'wipe_seen\twipe_done\torder\n')

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

local function whereOf(a, b)
  if a < 0 or b < 0 then return '-' end
  local da = (a >= 0 and a <= DISPLAY_LAST)
  local db = (b >= 0 and b <= DISPLAY_LAST)
  if da and db then return '표시' end
  if (not da) and (not db) then return 'VBlank' end
  return '걸침'
end

-- VDC 그림자
local selReg, mawr, incr, crLo = 0, 0, 1, nil

-- 프레임 집계.  ★ getState 는 "구간의 첫 쓰기" 와 "구간이 이어지는 동안 가끔" 만 부른다
local hits = 0
local wN, wFirst, wLast = 0, -1, -1
local rN, rFirst, rLast = 0, -1, -1
local dN, dFirst = 0, -1
local regLo, regHi = -1, -1

local SAMPLE_EVERY = 64          -- 구간 안에서 마지막 줄을 갱신하는 간격

emu.addMemoryCallback(function(address, value)
  local port = address & 3
  value = (value or 0) & 0xFF
  if port == 0 then
    selReg = value
    return
  end
  if port == 2 then
    if selReg == 0x00 then mawr = (mawr & 0xFF00) | value
    elseif selReg == 0x05 then crLo = value
    elseif selReg == 0x13 then
      dN = dN + 1
      if dFirst < 0 then dFirst = scanline() end
    end
    return
  end
  -- port 3
  if selReg == 0x00 then
    mawr = (mawr & 0x00FF) | (value << 8)
  elseif selReg == 0x13 then
    dN = dN + 1
    if dFirst < 0 then dFirst = scanline() end
  elseif selReg == 0x02 then
    local a = mawr & 0x7FFF
    if a >= SATB_LO and a <= SATB_HI then
      wN = wN + 1
      if wN == 1 or wN % SAMPLE_EVERY == 0 then
        local l = scanline()
        if wFirst < 0 then wFirst = l end
        wLast = l
      end
    elseif regLo >= 0 and a >= regLo and a <= regHi then
      rN = rN + 1
      if rN == 1 or rN % SAMPLE_EVERY == 0 then
        local l = scanline()
        if rFirst < 0 then rFirst = l end
        rLast = l
      end
    end
    mawr = (mawr + incr) & 0xFFFF
  end
end, emu.callbackType.write, 0x0000, 0x0003, CPU, MEM)

emu.addMemoryCallback(function() hits = hits + 1 end,
  emu.callbackType.exec, ENGINE_LO, ENGINE_HI, CPU, MEM)

local function incrFromCr()
  if crLo == nil then return 1 end
  local sel = (crLo >> 3) & 0x03
  return (sel == 0) and 1 or (sel == 1) and 32 or (sel == 2) and 64 or 128
end

local frame, restores = 0, 0

emu.addEventCallback(function()
  frame = frame + 1
  incr = incrFromCr()

  if hits >= BIG_HITS then
    restores = restores + 1
    local base = (rd(CTL_VRAM_HI) << 8) | rd(CTL_VRAM_LO)

    local order
    if wFirst < 0 and rFirst < 0 then order = '둘다-못봄'
    elseif wFirst < 0 then order = 'wipe-못봄'
    elseif rFirst < 0 then order = 'restore-못봄'
    elseif wFirst < rFirst then order = 'wipe -> restore'
    elseif wFirst > rFirst then order = '★restore -> wipe'
    else order = '같은-줄' end

    out:write(string.format(
      '%d\t%d\t%04X\t%d\t%d\t%d\t%d\t%d\t%s\t%d\t%d\t%d\t%s\t%d\t%d\t%s\t%d\t%d\t%s\n',
      frame, rd(STATE_ADDR), base, hits, incr,
      wN, wFirst, wLast, whereOf(wFirst, wLast),
      rN, rFirst, rLast, whereOf(rFirst, rLast),
      dN, dFirst, whereOf(dFirst, dFirst),
      rd(CTL_WIPE_SEEN), rd(CTL_WIPE_DONE), order))
    out:flush()

    say('0.5.120 f%d base=$%04X  wipe %d회 %d..%d(%s) · restore %d회 %d..%d(%s)'
        .. ' · DVSSR %d회 첫 %d(%s)  incr=+%d  [%s]',
        frame, base,
        wN, wFirst, wLast, whereOf(wFirst, wLast),
        rN, rFirst, rLast, whereOf(rFirst, rLast),
        dN, dFirst, whereOf(dFirst, dFirst), incr, order)
    if rN > 0 and (rN < REGION_WORDS // 2 or rN > REGION_WORDS * 2) then
      say('0.5.120 ⚠ restore 쓰기 %d 가 1216 과 많이 다르다 -- incr 가정(+%d)부터 의심할 것',
          rN, incr)
    end
  end

  local b = (rd(CTL_VRAM_HI) << 8) | rd(CTL_VRAM_LO)
  if b > 0 then regLo, regHi = b, b + REGION_WORDS - 1 else regLo, regHi = -1, -1 end
  hits = 0
  wN, wFirst, wLast = 0, -1, -1
  rN, rFirst, rLast = 0, -1, -1
  dN, dFirst = 0, -1
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  out:close()
  say('0.5.120 끝 -- 복원 %d 회', restores)
  if restores == 0 then
    say('0.5.120 ⚠ 복원을 못 봤다.  판정하지 말 것')
  end
  say('0.5.120 ⚠ 이 판은 **순서 사실**만 낸다.'
      .. ' 내부 스프라이트 RAM 은 안 보이므로 "그래서 화면에 보였다" 는 닫지 못한다')
  say('0.5.120 저장 %s', PATH)
end, emu.eventType.scriptEnded)

say('SUB 0.5.120-restore-order armed -- 순수 관측 · 게임 무수정 · 화면 무개입')
say('  묻는 것 : 복원 프레임 안에서 wipe · restore · DVSSR 의 순서와 스캔라인')
say('  덤프 : ' .. PATH)
