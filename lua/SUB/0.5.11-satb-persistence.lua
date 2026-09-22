-- SUB 0.5.11 -- 우리가 민 스프라이트는 저절로 사라지나, 남나 (쓰기 0 B)
--
-- 왜 이걸 재나
-- ---------------------------------------------------------------------------
-- 0.5.10 으로 "복원 직전에 우리 SATB 슬롯을 비우면 1 프레임 깨짐이 사라진다" 가
-- 확인됐다.  이제 그 순서를 정식 코드에 넣어야 하는데 **넣을 자리가 없다.**
--
--     상주 컨트롤러   151 / 151 B   여유 0
--     헬퍼            303 / 320 B   여유 17
--     렌더러          669 / 671 B   여유 2
--
-- 유일한 문은 헬퍼 슬롯을 320 -> 448 B 로 늘리는 것이다 (AC $1F1C00~$1F1F00 사이가
-- 768 B 이고, copy_fixed 의 코드 크기는 divmod(size,256) 이 같아 안 변한다).
-- 그런데 그 전에 **지우는 코드가 정말 필요한지**부터 확인해야 한다.
--
--     게임이 매 프레임 SATB 를 자기 목록에서 재구성한다
--       -> 우리가 그 프레임에 안 밀기만 하면 저절로 사라진다.  코드 0 B
--     우리가 민 것이 그대로 남는다
--       -> 지우는 코드가 필요하다.  헬퍼 슬롯 확장
--
-- 무엇을 재나
-- ---------------------------------------------------------------------------
-- **와이프 없는 체인**(0.4.89-marker)에서 돌린다.  0.4.48 이 지우면 관측이
-- 오염되므로 반드시 빼야 한다.
--
--     매 프레임   SATB(VRAM word $1000) 64 슬롯 중 우리 블록($1600-$1ABF)을
--                 팔레트 15 로 가리키는 슬롯 수를 센다.  Sprite RAM 도 같이
--     engine      count_ok 가 실행된 프레임인지
--
-- 판정
--     엔진이 안 도는 프레임에서 슬롯 수가 **다음 프레임에 0 이 된다**
--       -> 게임이 재구성한다.  "안 밀기" 만으로 끝난다
--     여러 프레임 그대로 남는다
--       -> 우리가 민 것이 남는다.  지우는 코드가 필요하다
--
-- 화면에 "마지막 푸시 후 유지 프레임" 최대값을 띄운다.  그 숫자가 답이다.
--
-- ★ 푸시 관측이 0 이면 판정하지 말 것.
-- ⚠ 와이프가 없으므로 이전 자막이 화면에 남는다.  예정된 부작용이다.
--
-- Power Cycle 뒤 이 파일 하나만 로드한다.  디스크는 0.4.6.16-reviewed.

assert(rawget(_G, 'SUB_FRAGMENT_FORCE_KEY') == nil and
       rawget(_G, 'SUB_FRAGMENT_FORCE_BASE') == nil,
       '재무장 엔진에서는 SUB_FRAGMENT_FORCE_KEY/BASE 를 쓸 수 없다')

-- ★ 와이프 없는 체인.  0.4.48 을 얹지 않는다.
dofile('C:/snatcher/lua/SUB/0.4.89-marker.lua')

local info = rawget(_G, 'SUB_REARM_INFO')
local ENGINE_LO = info and info.engine_lo or 0x5B80
local COUNT_OK = ENGINE_LO + (info and info.offsets.count_ok or 118)

local MEM, CPU = emu.memType.pceMemory, emu.cpuType.pce
local VRAM = emu.memType.pceVideoRam
local SPR  = emu.memType.pceSpriteRam

local BASE = 0x1600
local BLOCK_WORDS = 19 * 0x40
local SATB_BYTE = 0x2000            -- VRAM 바이트 = word $1000

local STAMP = os.date('%Y%m%d_%H%M%S')
local OUT = 'C:/snatcher/dump/satb_persist_0_5_11_' .. STAMP .. '.tsv'
local out = io.open(OUT, 'w')
if out then out:write('frame\tengine\tvram_slots\tspr_slots\tsince_push\n') end

local function rb(at, kind)
  local ok, v = pcall(emu.read, at, kind)
  if not ok or type(v) ~= 'number' then return 0 end
  return v
end

local function pointsAtBase(pattern, attr)
  if (attr & 0x0F) ~= 0x0F then return false end
  local first = (pattern & 0x07FF) << 5
  local width = ((attr & 0x0100) ~= 0) and 2 or 1
  local hcode = (attr >> 12) & 0x03
  local height = (hcode == 0) and 1 or ((hcode == 1) and 2 or 4)
  local last = first + width * height * 0x40 - 1
  return last >= BASE and first < BASE + BLOCK_WORDS
end

local function countSlots(kind, origin)
  local n = 0
  for slot = 0, 63 do
    local at = origin + slot * 8
    local pattern = rb(at + 4, kind) | (rb(at + 5, kind) << 8)
    local attr    = rb(at + 6, kind) | (rb(at + 7, kind) << 8)
    if pointsAtBase(pattern, attr) then n = n + 1 end
  end
  return n
end

local engineFrame = false
emu.addMemoryCallback(function() engineFrame = true end,
  emu.callbackType.exec, COUNT_OK, COUNT_OK, CPU, MEM)

local frame = 0
local sincePush = -1          -- 마지막 푸시 프레임으로부터 경과
local pushes, maxHold = 0, 0
local lastV, lastS = -1, -1

emu.addEventCallback(function()
  frame = frame + 1
  local ran = engineFrame
  engineFrame = false

  local v = countSlots(VRAM, SATB_BYTE)
  local s = countSlots(SPR, 0)

  if ran and v > 0 then
    pushes = pushes + 1
    sincePush = 0
  elseif sincePush >= 0 then
    sincePush = sincePush + 1
    -- 아직 남아 있으면 유지 기록을 늘린다
    if v > 0 or s > 0 then
      if sincePush > maxHold then maxHold = sincePush end
    else
      -- 사라졌다.  이번 사이클 종료
      sincePush = -1
    end
  end

  if v ~= lastV or s ~= lastS then
    lastV, lastS = v, s
    emu.log(string.format('SUB 0.5.11 %df · %s · VRAM SATB %d칸 · Sprite RAM %d칸 · 푸시후 %d f',
                          frame, ran and 'engine' or '-', v, s,
                          sincePush < 0 and 0 or sincePush))
    if out then
      out:write(string.format('%d\t%d\t%d\t%d\t%d\n',
                              frame, ran and 1 or 0, v, s, sincePush))
      out:flush()
    end
  end

  emu.drawString(4, 74, string.format(
    '0.5.11 푸시 %d회 · 지금 SATB %d / SPR %d · 푸시후 최대유지 %d 프레임',
    pushes, v, s, maxHold),
    maxHold > 2 and 0x4040FF or 0x80FF80, 0x000000)
end, emu.eventType.endFrame)

emu.log('SUB 0.5.11-satb-persistence armed -- 와이프 없는 체인 · 우리 슬롯이 남는지 센다')
emu.log(string.format('  블록 $%04X-$%04X · SATB VRAM byte $%04X · 팔레트 15',
                      BASE, BASE + BLOCK_WORDS - 1, SATB_BYTE))
emu.log('  ★ 푸시 0 회면 판정 불가 · 이전 자막이 남는 것은 예정된 부작용')
emu.log('  로그: ' .. OUT)
