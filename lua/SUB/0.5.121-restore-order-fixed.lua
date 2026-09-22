-- SUB 0.5.121 -- 복원 프레임 안의 순서 (0.5.120 의 증가폭 버그 수정판) (쓰기 0 B)
--
-- 0.5.120 이 무엇을 틀렸나
-- ---------------------------------------------------------------------------
-- MAWR 그림자를 전진시키는 **증가폭(incr)** 을 잘못 읽었다.
--
--     HuC6270 CR($05) 의 VRAM 증가폭은 **비트 11-12** 다 -> **상위 바이트**의 비트 3-4
--     0.5.120 은 하위 바이트(port2)의 비트 3-4 를 읽었다 -- 완전히 다른 필드
--     게다가 endFrame 에 한 번만 계산해서, 프레임 중 변경을 놓쳤다
--
-- 결과: 그림자가 엉뚱하게 전진 -> 목적지 분류가 전부 흔들렸다.
-- 자체 검산(restore 쓰기 76 vs 기대 1216)이 그것을 잡아냈다.
--
--     ★ 0.5.120 의 wipe/restore 줄 번호와 순서를 **인용하지 말 것.**
--       살아남는 것은 DVSSR 뿐이다 (selReg==$13 로만 잡아 그림자와 무관):
--           DVSSR 2 회 · 첫 기입 line 235~239
--
-- 이 판이 고친 것
-- ---------------------------------------------------------------------------
--     1. 증가폭을 CR **상위 바이트** 비트 3-4 에서 읽는다
--     2. CR 기입 즉시 갱신한다 (프레임 단위가 아니라)
--     3. ★ 증가폭에 **안 기대는** 교차 검증을 같이 낸다
--          -- MAWR 을 명시적으로 프로그램한 값과 그 스캔라인을 그대로 기록
--          -- 이것은 그림자 전진과 무관하므로, incr 이 또 틀려도 살아남는다
--
-- 읽는 법 -- 두 층으로 본다
-- ---------------------------------------------------------------------------
-- (1) 그림자 무관 층 -- 항상 믿을 수 있다
--     mawr_sets      이 프레임에 MAWR 을 몇 번 프로그램했나
--     set_list       그 값과 스캔라인 (앞 8 개)
--     -> "복원이 $6600 을 겨냥한 것은 line 몇인가" 가 여기서 바로 나온다
--     -> DVSSR 기입 줄도 여기 층이다
--
-- (2) 그림자 의존 층 -- 검산을 통과해야 믿는다
--     wipe_n / rest_n 과 그 줄 번호
--     ★ 검산: rest_n 이 1216 근처인가.  아니면 이 층을 통째로 버린다
--
-- ★ 이 판이 **못** 답하는 것 (닫지 말 것)
--     VDC 내부 스프라이트 RAM 은 Lua 로 안 보인다.  VRAM 의 SATB 는 읽히지만
--     래치된 사본은 안 보인다.  그래서 "그래서 화면에 보였다" 는 여기서 안 닫힌다.
--     ⚠ DMA(SATB 자동전송)는 포트를 안 거쳐 안 잡힌다.
--       DVSSR 은 "주소를 지정한 시점" 이지 "전송이 일어난 시점" 이 아니다.
--
-- ★ 화면에 아무것도 안 그린다.  게임을 한 바이트도 안 고친다.
--
--   BIOS  build/patch/0.4.6.68/Syscard3_galmuri_0.4.6.68.pce
--   CUE   build/patch/0.4.6.68/Snatcher CD-ROMantic (Japan) [KO].cue
--   Power Cycle -> 이 파일만 로드 -> 0.5.120 과 같은 장면, 대사를 끝까지
--
-- 산출물  C:/snatcher/dump/restore_order_0_5_121_<시각>.tsv

local MEM, CPU = emu.memType.pceMemory, emu.cpuType.pce

local ENGINE_LO, ENGINE_HI = 0x5B80, 0x5E1F
local CTL_VRAM_LO, CTL_VRAM_HI = 0x5D34, 0x5D35
local CTL_WIPE_SEEN, CTL_WIPE_DONE = 0x5D32, 0x5D33
local STATE_ADDR = 0x7FDF

local REGION_WORDS = 1216
local SATB_LO, SATB_HI = 0x1000, 0x10FF

local LINES, DISPLAY_LAST = 263, 238
local BIG_HITS = 4000
local SAMPLE_EVERY = 64
local MAX_SETS_LOGGED = 8

local STAMP = os.date('%Y%m%d_%H%M%S')
local PATH  = 'C:/snatcher/dump/restore_order_0_5_121_' .. STAMP .. '.tsv'
local out   = assert(io.open(PATH, 'w'))
out:write('frame\tstate\tbase\texec_hits\tincr\tcr_hi\t'
       .. 'mawr_sets\tset_list\tdvssr_n\tdvssr_first\t'
       .. 'wipe_n\twipe_first\twipe_last\trest_n\trest_first\trest_last\t'
       .. 'wipe_seen\twipe_done\tshadow_ok\torder\n')

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

local function whereOf(a)
  if a < 0 then return '-' end
  return (a <= DISPLAY_LAST) and '표시' or 'VBlank'
end

-- VDC 그림자
local selReg, mawr, incr = 0, 0, 1
local crHi = nil
local pendMawrLo = 0

local function incrFrom(hi)
  -- CR 비트 11-12  ->  상위 바이트 비트 3-4
  local sel = (hi >> 3) & 0x03
  return (sel == 0) and 1 or (sel == 1) and 32 or (sel == 2) and 64 or 128
end

-- 프레임 집계
local hits = 0
local wN, wFirst, wLast = 0, -1, -1
local rN, rFirst, rLast = 0, -1, -1
local dN, dFirst = 0, -1
local setN, sets = 0, {}
local regLo, regHi = -1, -1

emu.addMemoryCallback(function(address, value)
  local port = address & 3
  value = (value or 0) & 0xFF

  if port == 0 then
    selReg = value
    return
  end

  if port == 2 then
    if selReg == 0x00 then
      pendMawrLo = value
    elseif selReg == 0x13 then
      dN = dN + 1
      if dFirst < 0 then dFirst = scanline() end
    end
    return
  end

  -- port 3
  if selReg == 0x00 then
    mawr = ((value << 8) | pendMawrLo) & 0xFFFF
    setN = setN + 1
    if #sets < MAX_SETS_LOGGED then
      sets[#sets + 1] = string.format('%04X@%d', mawr & 0x7FFF, scanline())
    end
  elseif selReg == 0x05 then
    crHi = value
    incr = incrFrom(value)                      -- ★ 즉시 갱신
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

local frame, restores = 0, 0

emu.addEventCallback(function()
  frame = frame + 1

  if hits >= BIG_HITS then
    restores = restores + 1
    local base = (rd(CTL_VRAM_HI) << 8) | rd(CTL_VRAM_LO)

    -- 그림자 층이 믿을 만한가
    local shadowOk = (rN >= REGION_WORDS // 2 and rN <= REGION_WORDS * 2) and 'OK' or '★버릴것'

    local order
    if shadowOk ~= 'OK' then order = '판정보류(그림자불신)'
    elseif wFirst < 0 then order = 'wipe-못봄'
    elseif rFirst < 0 then order = 'restore-못봄'
    elseif wFirst < rFirst then order = 'wipe -> restore'
    elseif wFirst > rFirst then order = '★restore -> wipe'
    else order = '같은-줄' end

    local setList = table.concat(sets, ' ')
    out:write(string.format(
      '%d\t%d\t%04X\t%d\t%d\t%s\t%d\t%s\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%s\t%s\n',
      frame, rd(STATE_ADDR), base, hits, incr,
      crHi and string.format('%02X', crHi) or '-',
      setN, setList, dN, dFirst,
      wN, wFirst, wLast, rN, rFirst, rLast,
      rd(CTL_WIPE_SEEN), rd(CTL_WIPE_DONE), shadowOk, order))
    out:flush()

    say('0.5.121 f%d base=$%04X incr=+%d cr_hi=%s  MAWR설정 %d회 [%s]',
        frame, base, incr, crHi and string.format('%02X', crHi) or '-', setN, setList)
    say('           DVSSR %d회 첫 %d(%s) · wipe %d회 %d..%d · restore %d회 %d..%d'
        .. '  그림자=%s  [%s]',
        dN, dFirst, whereOf(dFirst), wN, wFirst, wLast, rN, rFirst, rLast,
        shadowOk, order)
    if shadowOk ~= 'OK' then
      say('0.5.121 ⚠ restore 쓰기 %d 가 1216 과 다르다 -- 그림자 층(wipe/restore 줄)을'
          .. ' 버리고 MAWR설정 목록과 DVSSR 만 읽을 것', rN)
    end
  end

  local b = (rd(CTL_VRAM_HI) << 8) | rd(CTL_VRAM_LO)
  if b > 0 then regLo, regHi = b, b + REGION_WORDS - 1 else regLo, regHi = -1, -1 end
  hits = 0
  wN, wFirst, wLast = 0, -1, -1
  rN, rFirst, rLast = 0, -1, -1
  dN, dFirst = 0, -1
  setN, sets = 0, {}
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  out:close()
  say('0.5.121 끝 -- 복원 %d 회', restores)
  if restores == 0 then say('0.5.121 ⚠ 복원을 못 봤다.  판정하지 말 것') end
  say('0.5.121 ⚠ 내부 스프라이트 RAM 은 안 보인다.'
      .. ' "그래서 화면에 보였다" 는 이 판으로 닫지 못한다')
  say('0.5.121 저장 %s', PATH)
end, emu.eventType.scriptEnded)

say('SUB 0.5.121-restore-order-fixed armed -- 순수 관측 · 게임 무수정 · 화면 무개입')
say('  0.5.120 은 증가폭을 CR 하위바이트에서 읽어 그림자가 어긋났다.  상위바이트로 고쳤다')
say('  그림자에 안 기대는 층(MAWR 설정 목록 · DVSSR)을 같이 낸다')
say('  덤프 : ' .. PATH)
