-- SUB 0.5.130 -- 조각이 바뀔 때 우리 스프라이트가 몇 개 남는지 센다 (쓰기 0 B)
--
-- 무엇을 확정하려는가
-- ---------------------------------------------------------------------------
-- 0.5.128/0.5.129 로 나온 사실:
--
--     전환 프레임    SATB 쓰기 0 · MAWR 은 전부 $66xx (글리프)
--                    -> 우리 렌더러는 조각이 바뀔 때 **스프라이트를 안 건드린다**
--     hits=111 프레임 게임이 $1000-$10FF 64 슬롯을 매 프레임 통째로 갱신
--
-- 그러면 조각 1(16 칸) -> 조각 2(9 칸) 로 넘어가도 **스프라이트는 16 개 그대로**여야
-- 한다.  글리프 비트맵만 9 개가 새 것으로 바뀌고, 슬롯 9~15 는 앞 조각 글자를
-- 계속 가리킨다.  그것이 사진의 `임명된` 과 가운데 뒤섞임이다.
--
-- ★ 이 판은 그 **결과**를 직접 센다.  VRAM 의 SATB 를 프레임마다 읽어
--   "우리 스프라이트" 의 개수와 x 좌표를 찍는다.
--
-- 우리 것을 어떻게 알아보나
-- ---------------------------------------------------------------------------
-- 헬퍼의 wipe 와 같은 기준을 쓴다 (tools/build_subtitle_vram_helper.py):
--
--     attr 하위 4 비트 == $F      (layout.GLYPH_PALETTE)
--     pattern 이 0 이 아니다
--
-- ⚠ control block 의 base/pattern_first 는 못 믿는다 -- 0.5.129 에서 $FFFF·$00BF
--   같은 잡값이 나왔다.  그래서 **팔레트만으로** 고르고, pattern 값은 그대로 찍어서
--   나중에 눈으로 대조한다.  팔레트 $F 를 게임도 쓴다면 그 값이 섞이는데,
--   그건 x 좌표 분포로 구분된다 (자막은 한 줄에 가지런히 늘어선다).
--
-- 읽는 법
-- ---------------------------------------------------------------------------
--     조각 1 구간   ours=16  x=0,10,20,...,112
--     조각 2 구간   ours=16  x 그대로            ★안 지운다.  증상 1 확정
--     조각 2 구간   ours=9   x=0,10,...,74       지운다 -> 원인은 다른 것
--
-- ★ 변할 때만 찍는다.  같은 상태가 이어지면 로그가 조용하다.
--
-- ⚠ 이 판이 보는 것은 **VRAM 의 SATB** 다.  VDC 내부에 래치된 사본은 Lua 로 안 보인다.
--   그래서 "그 프레임 화면에 실제로 몇 개가 그려졌나" 까지는 못 닫는다.
--   다만 "지우는가 / 안 지우는가" 는 여기서 갈린다.
--
-- ★ 화면에 아무것도 안 그린다.  게임을 한 바이트도 안 고친다.  개입 없음.
--
--   BIOS  build/patch/0.4.6.68/Syscard3_galmuri_0.4.6.68.pce
--   CUE   build/patch/0.4.6.68/Snatcher CD-ROMantic (Japan) [KO].cue
--   Power Cycle -> 이 파일만 로드
--   ★ ADPCM_003078_6800_0E  조각 1 '금일부로 JUNKER로 임명된' 16 칸
--                           조각 2 '길리언 시드다만.'          9 칸
--
-- 산출물  C:/snatcher/dump/satb_content_0_5_130_<시각>.tsv

local MEM, CPU = emu.memType.pceMemory, emu.cpuType.pce
local VRAM = emu.memType.pceVideoRam

local ENGINE_LO, ENGINE_HI = 0x5B80, 0x5E1F
local STATE_ADDR = 0x7FDF
local SATB = 0x1000
local SLOTS = 64
local GLYPH_PALETTE = 0x0F

local STAMP = os.date('%Y%m%d_%H%M%S')
local PATH  = 'C:/snatcher/dump/satb_content_0_5_130_' .. STAMP .. '.tsv'
local out   = assert(io.open(PATH, 'w'))
out:write('frame\tstate\thits\tours\tslots\txs\tpatterns\tys\n')

local function say(f, ...) emu.log(string.format(f, ...)) end
local function rd(a)
  local ok, v = pcall(emu.read, a, MEM)
  return (ok and type(v) == 'number') and v or -1
end
local function rb(at)
  local ok, v = pcall(emu.read, at, VRAM)
  return (ok and type(v) == 'number') and v or 0
end
local function rw(word) local at = word * 2; return rb(at) | (rb(at + 1) << 8) end

local hits = 0
emu.addMemoryCallback(function() hits = hits + 1 end,
  emu.callbackType.exec, ENGINE_LO, ENGINE_HI, CPU, MEM)

local function scan()
  local slots, xs, pats, ys = {}, {}, {}, {}
  for i = 0, SLOTS - 1 do
    local base = SATB + i * 4
    local y    = rw(base + 0)
    local x    = rw(base + 1)
    local pat  = rw(base + 2)
    local attr = rw(base + 3)
    if pat ~= 0 and (attr & 0x0F) == GLYPH_PALETTE then
      slots[#slots + 1] = i
      xs[#xs + 1]   = x & 0x03FF
      pats[#pats + 1] = pat & 0x07FF
      ys[#ys + 1]   = y & 0x03FF
    end
  end
  return slots, xs, pats, ys
end

local function join(t, n)
  local p = {}
  for i = 1, math.min(#t, n or 24) do p[#p + 1] = tostring(t[i]) end
  if #t > (n or 24) then p[#p + 1] = '...+' .. (#t - (n or 24)) end
  return table.concat(p, ',')
end

local frame, lastKey, changes = 0, nil, 0

emu.addEventCallback(function()
  frame = frame + 1
  local slots, xs, pats, ys = scan()
  local key = #slots .. '|' .. join(slots, 64) .. '|' .. join(xs, 64)

  if key ~= lastKey then
    lastKey = key
    changes = changes + 1
    out:write(string.format('%d\t%d\t%d\t%d\t%s\t%s\t%s\t%s\n',
      frame, rd(STATE_ADDR), hits, #slots,
      join(slots), join(xs), join(pats), join(ys, 4)))
    out:flush()
    if #slots > 0 or changes <= 200 then
      say('f%d state=%d hits=%d  우리 스프라이트 %d 개', frame, rd(STATE_ADDR), hits, #slots)
      if #slots > 0 then
        say('    슬롯 [%s]', join(slots))
        say('    x    [%s]', join(xs))
        say('    pat  [%s]', join(pats))
      end
    end
  end

  hits = 0
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  out:close()
  say('0.5.130 끝 -- 상태 변화 %d 회 · 저장 %s', changes, PATH)
  say('0.5.130 ⚠ VRAM 의 SATB 만 본다.  VDC 내부 래치 사본은 안 보이므로'
      .. ' "그 프레임에 실제로 몇 개가 그려졌나" 는 여기서 안 닫힌다')
end, emu.eventType.scriptEnded)

say('SUB 0.5.130-satb-content armed -- 순수 관측 · 게임 무수정 · 화면 무개입')
say('  묻는 것 : 조각이 바뀔 때 우리 스프라이트 개수가 줄어드는가')
say('  조각1 16 칸 -> 조각2 9 칸.  16 이 그대로면 안 지우는 것이다')
say('  덤프 : ' .. PATH)
