-- SUB 0.5.93 -- 우리가 남긴 **영구 발자국**을 한 주행 안에서 찾는다 (관측 전용)
--
-- 왜 대조를 그만두나
-- ---------------------------------------------------------------------------
-- 0.5.91/0.5.92 로 원본과 VRAM 64 KB · 팔레트 512 를 떠서 비교했다.
--
-- ```
-- $7900-$7DBF   완전히 같음      <- 복원은 정확했다.  그 대역은 범인이 아니다
-- BAT · SATB    같음
-- $6F00-$6FFF   256 word 다르지만 **자막 그리기 전(#1)에 이미 다름** = 사전 차이
-- 팔레트        스프라이트 15 의 2 색만 (우리 글자색)
-- ```
--
-- 그런데 패치본은 자막 엔진이 도니 두 주행의 진행이 어긋난다.  "CD-DA +N 프레임"
-- 으로 맞춘 장면이 서로 같은 장면이라는 보장이 없다 (소유자 지적 2026-09-01).
--
-- 그래서 **한 주행 안에서** 답을 낸다.
--
--     임대 중   우리 엔진이 쓴 VRAM word 를 값까지 전부 기록한다
--     한참 뒤   그 word 들을 다시 읽는다
--               아직 우리 값 그대로 -> 게임이 덮지 않았다 = **영구 발자국**
--               게임 값으로 바뀜    -> 무해
--
-- 남아 있는 구간이 곧 우리가 영구히 망친 자리다.  원본도 정렬도 필요 없다.
--
-- 팔레트도 같이 본다 (VCE 포트 $0400-$0407).  우리가 쓴 엔트리를 기억해 두고
-- 같은 방식으로 살아남았는지 센다.
--
-- ★ 게임을 한 바이트도 안 고친다.  화면에 아무것도 안 그린다.
-- ★ 판정은 정해진 시점마다 즉시 로그로 나온다.  언로드 불필요.
--
--   BIOS  build/patch/0.4.6.48/Syscard3_galmuri_0.4.6.48.pce + 같은 폴더 [KO].cue
--   Power Cycle -> 이 파일만 로드 -> 스킵하지 말고 CD-DA -> 챕터1 -> 접수처까지
--
-- 산출물  C:/snatcher/dump/footprint_0_5_93_<시각>.tsv

local MEM  = emu.memType.pceMemory
local VRAM = emu.memType.pceVideoRam
local CPU  = emu.cpuType.pce

local ENG_LO, ENG_HI = 0x5B80, 0x5E1E

local PAL = nil
for _, name in ipairs({ 'pcePaletteRam', 'pceVideoColorRam', 'pceCgRam', 'palette' }) do
  if emu.memType[name] ~= nil then PAL = emu.memType[name]; break end
end
local STAMP = os.date('%Y%m%d_%H%M%S')
local PATH  = 'C:/snatcher/dump/footprint_0_5_93_' .. STAMP .. '.tsv'
local out   = assert(io.open(PATH, 'w'))
out:write('frame\tevent\tdetail\n')

local frame = 0
local function rd(a) return emu.read(a, MEM) or -1 end
local function say(f, ...) emu.log(string.format(f, ...)) end
local function rec(ev, f, ...)
  local d = select('#', ...) > 0 and string.format(f, ...) or (f or '')
  out:write(string.format('%d\t%s\t%s\n', frame, ev, d)); out:flush()
end

-- ===========================================================================
-- 소유자 · VDC 디코더 (0.5.75 / 0.5.80 검증본)
-- ===========================================================================
local inEngine = false
emu.addMemoryCallback(function(address)
  if not inEngine then inEngine = true end
  if (rd(address) or 0) == 0x60 then inEngine = false end
end, emu.callbackType.exec, ENG_LO, ENG_HI, CPU, MEM)

local selReg, mawr = 0, 0
local mark = {}                 -- word -> 우리가 마지막으로 쓴 값
local nMark, lastWriteFrame = 0, nil

emu.addMemoryCallback(function(address, value)
  local port = address & 3
  value = (value or 0) & 0xFF
  if port == 0 then
    selReg = value
  elseif port == 2 then
    if selReg == 0 then mawr = (mawr & 0xFF00) | value
    elseif selReg == 2 then                       -- VWR 하위바이트 (기억해 둔다)
      if inEngine then mark['lo'] = value end
    end
  elseif port == 3 then
    if selReg == 0 then
      mawr = (mawr & 0x00FF) | (value << 8)
    elseif selReg == 2 then
      local w = mawr & 0x7FFF
      if inEngine then
        if mark[w] == nil then nMark = nMark + 1 end
        mark[w] = ((mark['lo'] or 0) & 0xFF) | (value << 8)
        lastWriteFrame = frame
      end
      mawr = (mawr + 1) & 0xFFFF
    end
  end
end, emu.callbackType.write, 0x0000, 0x03FF, CPU, MEM)

-- 팔레트: VCE 데이터 포트에 쓴 엔트리를 기억한다
local vceAddr, palMark, nPal = 0, {}, 0
emu.addMemoryCallback(function(address, value)
  value = (value or 0) & 0xFF
  local p = address & 7
  if p == 2 then vceAddr = (vceAddr & 0x100) | value
  elseif p == 3 then vceAddr = (vceAddr & 0xFF) | ((value & 1) << 8)
  elseif p == 4 then
    if inEngine then palMark[vceAddr] = (palMark[vceAddr] or 0) & 0xFF00 | value end
  elseif p == 5 then
    if inEngine then
      if palMark[vceAddr] == nil then nPal = nPal + 1 end
      palMark[vceAddr] = ((palMark[vceAddr] or 0) & 0xFF) | ((value & 1) << 8)
    end
    vceAddr = (vceAddr + 1) & 0x1FF
  end
end, emu.callbackType.write, 0x0400, 0x0407, CPU, MEM)

-- ===========================================================================
-- 살아남은 발자국 세기
-- ===========================================================================
local function survey(tag)
  local live, dead, runs, cur = 0, 0, {}, nil
  local words = {}
  for w in pairs(mark) do if type(w) == 'number' then words[#words + 1] = w end end
  table.sort(words)
  for _, w in ipairs(words) do
    local lo = emu.read(w * 2, VRAM) or 0
    local hi = emu.read(w * 2 + 1, VRAM) or 0
    local now = lo | (hi << 8)
    local same = (now == mark[w])
    if same then
      live = live + 1
      if cur and w == cur[2] + 1 then cur[2] = w
      else
        if cur then runs[#runs + 1] = cur end
        cur = { w, w }
      end
    else
      dead = dead + 1
    end
  end
  if cur then runs[#runs + 1] = cur end

  -- 팔레트도 같은 방식으로 살아남았는지 센다
  local palLive, palDead = 0, 0
  if PAL then
    for e, v in pairs(palMark) do
      local lo = emu.read(e * 2, PAL) or 0
      local hi = emu.read(e * 2 + 1, PAL) or 0
      if ((lo | (hi << 8)) & 0x1FF) == (v & 0x1FF) then palLive = palLive + 1
      else palDead = palDead + 1 end
    end
  end

  say('0.5.93 ===== %s  우리가 쓴 word %d 중 **아직 우리 값** %d · 덮인 것 %d',
      tag, nMark, live, dead)
  rec('survey', '%s marked=%d live=%d dead=%d runs=%d', tag, nMark, live, dead, #runs)
  local shown = 0
  for _, r in ipairs(runs) do
    if r[2] - r[1] >= 3 then                   -- 4 word 이상 연속만 보고한다
      shown = shown + 1
      if shown <= 16 then
        say('        $%04X-$%04X  %d word 가 그대로 남아있다', r[1], r[2], r[2] - r[1] + 1)
      end
      rec('live_run', '$%04X-$%04X len=%d', r[1], r[2], r[2] - r[1] + 1)
    end
  end
  if shown == 0 then
    say('        (4 word 이상 연속으로 남은 구간 없음 -- 게임이 다 덮었다)')
  elseif shown > 16 then
    say('        ... 그 밖 %d 구간 (TSV 참조)', shown - 16)
  end
  if PAL then
    say('        우리가 건드린 팔레트 %d 개 중 아직 우리 값 %d · 덮인 것 %d',
        nPal, palLive, palDead)
    rec('palette', 'marked=%d live=%d dead=%d', nPal, palLive, palDead)
  else
    say('        우리가 건드린 팔레트 엔트리 %d 개 (팔레트 메모리 타입 없음)', nPal)
  end
end

local plan, planIdx = { 600, 1800, 3600, 7200, 12000, 18000 }, 1
emu.addEventCallback(function()
  frame = frame + 1
  if lastWriteFrame and planIdx <= #plan
     and frame - lastWriteFrame >= plan[planIdx] then
    survey(string.format('마지막 기입 +%d 프레임', plan[planIdx]))
    planIdx = planIdx + 1
  end
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  if nMark > 0 then survey('종료 시점') end
  rec('end', 'marked=%d pal=%d', nMark, nPal)
  out:close(); say('저장 : ' .. PATH)
end, emu.eventType.scriptEnded)

say('SUB 0.5.93-footprint armed -- 순수 관측 · 게임 무수정 · 화면 무간섭')
say('  임대 중 우리가 쓴 VRAM word 를 값까지 기억했다가, 한참 뒤 살아남았는지 센다')
say('  살아남은 구간 = 게임이 다시 안 그리는 자리 = 우리가 영구히 망친 자리')
say('  덤프 : ' .. PATH)
