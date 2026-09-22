-- SUB 0.5.153 -- 복원이 화면을 그리는 도중에 도는가 (프레임 안 해상도)
--
-- ★ 순수 관측.  아무것도 안 고친다.  게임 무수정.
--
-- 왜 프레임 안을 봐야 하나
-- ---------------------------------------------------------------------------
-- 0.5.152 에서 음성 끝은 **한 줄**로 찍혔다 -- 스프라이트 사라짐 · 글리프 복원
-- (지문이 매번 32401985 로 복귀) · 엔진 내려감이 전부 같은 프레임이다.
-- 프레임 끝에서만 재니 그 안에서 무슨 순서로 일어났는지 안 보인다.
--
-- 그런데 오늘 이미 증명한 사실이 있다 (0.5.147 ★LEAD 14/14):
--
--     스프라이트 표는 한 프레임 늦고 · VRAM 은 즉시 반영된다
--
-- PCE 는 SAT 를 프레임 시작 vblank 에 한 번 DMA 로 래치한다.  그러니 헬퍼가
-- 화면 그리는 도중에 복원을 돌리면:
--
--     SATB 비우기 -> VRAM 만 지워진다.  이미 래치된 이번 프레임 스프라이트는 산다
--     VRAM 복원   -> 글리프 자리에 배경이 즉시 들어간다
--                    복원이 지나간 스캔라인부터 스프라이트가 그것을 그린다 ★ 가로 띠
--
-- 정적으로도 들어맞는다: 복원은 2,432 B 다.  TIA 가 바이트당 6 사이클이면
-- 약 14,600 사이클 = 스캔라인 32 줄어치.  vblank 에 안 들어간다.
--
-- 무엇을 재나
-- ---------------------------------------------------------------------------
-- 헬퍼의 restore_loop 가 실행되는 순간의 **스캔라인**을 잡는다.
--
--     helper offsets (subtitle_vram_helper.json)
--         restore       +108   CPU $5BEC
--         restore_loop  +159   CPU $5C1F      ★ 여기를 훅한다
--         wipe_sprites  +192   CPU $5C40
--
-- ⚠ 헬퍼와 렌더러는 **같은 $5B80** 을 쓴다.  그래서 지금 올라온 것이 헬퍼인지
--   entry 의 오퍼랜드로 가린다:
--         헬퍼   $5B83: AD 30 5D   (LDA command  = $5D30)
--         렌더러 $5B83: AD F9 5C   (LDA ready    = $5CF9)
--
-- 판정
--     복원 스캔라인이 표시 구간(대략 0~239) 안  -> ★ 확정.  그리는 도중에 덮는다
--     전부 vblank(240 이상)                     -> 이 설명은 틀렸다
--
-- 산출물  C:/snatcher/dump/restore_scanline_0_5_153_<시각>.tsv

local MEM, CPU = emu.memType.pceMemory, emu.cpuType.pce
local VRAM = emu.memType.pceVideoRam

local RESTORE_LOOP = 0x5C1F
local WIPE_LOOP    = 0x5C48        -- wipe_loop +200
local ENGINE = 0x5B80

local STAMP = os.date('%Y%m%d_%H%M%S')
local PATH  = 'C:/snatcher/dump/restore_scanline_0_5_153_' .. STAMP .. '.tsv'
local out   = assert(io.open(PATH, 'w'))
out:write('frame\tkind\thelper\tfirst_line\tlast_line\thits\twipe_line\twipe_hits\tnote\n')

local function say(m) emu.log(m); print(m) end
local function rd(a) local ok,v = pcall(emu.read, a, MEM); return (ok and type(v)=='number') and v or -1 end

-- 스캔라인 키를 한 번 찾아 둔다
local LINE_KEY = nil
local function scanline()
  local ok, s = pcall(emu.getState)
  if not ok or not s then return -1 end
  if LINE_KEY == nil then
    LINE_KEY = false
    for _, k in ipairs({'video.scanline','ppu.scanline','vdc.scanline','scanline',
                        'video.cycle','ppu.cycle'}) do
      if type(s[k]) == 'number' then LINE_KEY = k break end
    end
    if LINE_KEY == false then
      local names = {}
      for k, v in pairs(s) do
        if type(v) == 'number' and (k:find('line') or k:find('cycle') or k:find('frame')) then
          names[#names+1] = k
        end
      end
      say('  ⚠ 스캔라인 키를 못 찾았다.  후보: ' .. table.concat(names, ' '))
    else
      say('  스캔라인 키 = ' .. LINE_KEY)
    end
  end
  if LINE_KEY == false then return -1 end
  local v = s[LINE_KEY]
  return type(v) == 'number' and math.floor(v) or -1
end

-- 지금 $5B80 에 올라온 것이 헬퍼인가 (entry 의 오퍼랜드로 가린다)
local function helperUp()
  return rd(ENGINE + 4) == 0x30 and rd(ENGINE + 5) == 0x5D
end

local frame = 0
local rFirst, rLast, rHits = -1, -1, 0
local wLine, wHits = -1, 0
local isHelper = false

emu.addMemoryCallback(function()
  local ln = scanline()
  if rHits == 0 then rFirst = ln; isHelper = helperUp() end
  rLast = ln
  rHits = rHits + 1
end, emu.callbackType.exec, RESTORE_LOOP, RESTORE_LOOP + 2, CPU, MEM)

emu.addMemoryCallback(function()
  if wHits == 0 then wLine = scanline() end
  wHits = wHits + 1
end, emu.callbackType.exec, WIPE_LOOP, WIPE_LOOP + 2, CPU, MEM)

emu.addEventCallback(function()
  frame = frame + 1
  if rHits > 0 or wHits > 0 then
    local active = (rFirst >= 0 and rFirst < 240) or (rLast >= 0 and rLast < 240)
    local kind = active and 'ACTIVE' or 'VBLANK'
    local note = active
      and '표시 구간에서 복원한다 -- 그 아래 스캔라인이 깨진다'
      or  'vblank 안에서 끝났다'
    say(('%s f%-7d helper=%s  복원 스캔라인 %d..%d (%d 회) · 비우기 %d (%d 회)')
          :format(kind == 'ACTIVE' and '★ACTIVE' or '  VBLANK', frame,
                  tostring(isHelper), rFirst, rLast, rHits, wLine, wHits))
    out:write(('%d\t%s\t%s\t%d\t%d\t%d\t%d\t%d\t%s\n'):format(
      frame, kind, tostring(isHelper), rFirst, rLast, rHits, wLine, wHits, note))
    out:flush()
  end
  rFirst, rLast, rHits, wLine, wHits = -1, -1, 0, -1, 0
end, emu.eventType.endFrame)

emu.addEventCallback(function() out:close() end, emu.eventType.scriptEnded)

say('SUB 0.5.153-restore-scanline armed -- 순수 관측')
say('  ★ 볼 것: 복원이 도는 스캔라인.  표시 구간(0~239)이면 확정')
say('  ' .. PATH)
