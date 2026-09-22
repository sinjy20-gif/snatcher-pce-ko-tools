-- ★ HQ 1.1.0 -- **개입 실험**: 슬롯을 물고만 있어도 국장실이 깨지는가
--
-- ⚠ 이 판은 읽기 전용이 아니다.  일부러 게임 메모리를 건드린다.
--
-- 왜 이 판인가
-- ------------
-- 소유자 질문:
--     "근대 애초에 트랙 3번에 자막을 걸면 게임이 깨지는게 확정이야?
--      이건 LUA로 자막 넣어볼수 있지 않아?"
--
-- 확정이 아니다.  지금까지 잰 것은 이것뿐이다:
--
--     0.5.10  트랙 3 자막 없음          정상
--     0.5.18  자막 11 줄 (33.8초까지)   정상
--     0.5.17  자막 22 줄 (58초까지)     깨짐
--
-- 즉 "35 초 전환 시점까지 물고 있으면 깨진다" 까지다.  그런데 **물고 있어서**인지
-- **그려서**인지 아직 못 갈랐다.  빌드로 가르려면 또 몇 판을 구워야 한다.
--
-- 이 판은 그걸 **빌드 없이** 가른다.
--
-- 어떻게
-- ------
-- **0.5.10** 으로 돌린다 -- 트랙 3 자막이 아예 없는 판이다.  거기서 Lua 가
-- 트랙 3 이 시작될 때 슬롯 $5B80-$5E1E (671 B) 를 **떠 두고 $EA 로 채운다.**
-- 트랙이 끝나면 원래대로 돌려준다.
--
--     자막도 안 그리고, 스케줄러도 안 돌고, 렌더러도 없다.
--     오직 **"그 671 B 를 게임이 못 쓰게 한다"** 만 한다.
--
-- 판정
--     국장실에서 깨진다   -> ★슬롯 점유만으로 충분하다.  원인 확정.
--                            그리기·자리·이사는 전부 무관하다
--     멀쩡하다            -> 점유는 무죄.  그리기(VRAM) 쪽이 원인이다
--
-- 어느 쪽이든 **다음에 뭘 설계할지가 정해진다.**  훅 설계(§38)의 전제이기도 하다.
--
-- 쓰는 법
--     ★ build/patch/0.5.10 으로 Power Cycle -> 이 파일 하나만
--     트랙 3 을 자동 진행으로 국장실까지
--
-- 산출  dump/hq_1_1_0_occupy_<시각>.tsv
--
-- ⚠ 게임을 일부러 망가뜨리는 실험이다.  세이브는 쓰지 말 것.

local VERSION = '1.1.0'
local MEM = emu.memType.pceMemory

local SLOT_LO, SLOT_HI = 0x5B80, 0x5E1E
local SLOT_LEN = SLOT_HI - SLOT_LO + 1        -- 671
local CD_RAW = 0x26F9
local FILL = 0xEA                              -- NOP.  게임 코드처럼 안 보이게

local stamp = os.date('%Y%m%d_%H%M%S')
local OUT = 'C:/snatcher/dump/hq_' .. VERSION:gsub('%.', '_')
            .. '_occupy_' .. stamp .. '.tsv'
local out = assert(io.open(OUT, 'w'))
out:write('frame\telapsed\tevent\tcd_raw\tpc\n')

local function rb(at) return emu.read(at, MEM) or 0 end
local function wb(at, v) emu.write(at, v, MEM) end

local frame, rows = 0, 0
local backup = nil          -- 원본 671 B
local heldFrame = nil       -- 점유 시작 프레임

local function line(ev)
  local s = emu.getState() or {}
  local el = heldFrame and string.format('%.2f', (frame - heldFrame) / 60) or '-'
  out:write(string.format('%d\t%s\t%s\t%02X\t%04X\n',
    frame, el, ev, rb(CD_RAW), s['cpu.pc'] or 0))
  out:flush(); rows = rows + 1
end

local function occupy()
  backup = {}
  for i = 0, SLOT_LEN - 1 do
    backup[i] = rb(SLOT_LO + i)
    wb(SLOT_LO + i, FILL)
  end
  heldFrame = frame
  line('OCCUPY')
  emu.log(string.format('★ 슬롯 %d B 점유 시작  frame=%d', SLOT_LEN, frame))
end

local function release()
  if backup == nil then return end
  for i = 0, SLOT_LEN - 1 do wb(SLOT_LO + i, backup[i]) end
  line('RELEASE')
  emu.log(string.format('★ 슬롯 반납  frame=%d  점유 %.2f초',
    frame, (frame - heldFrame) / 60))
  backup, heldFrame = nil, nil
end

emu.addEventCallback(function()
  frame = frame + 1
  local t = rb(CD_RAW) & 0x7F
  if backup == nil and t == 3 then
    occupy()
  elseif backup ~= nil and t ~= 3 then
    release()
  end
  if backup ~= nil and frame % 600 == 0 then line('beat') end
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  release()
  out:write(string.format('# rows=%d frames=%d\n', rows, frame))
  out:close()
end, emu.eventType.scriptEnded)

emu.log('HQ ' .. VERSION .. ' -- ★개입 실험.  슬롯을 물고만 있는다')
emu.log('  ⚠ build/patch/0.5.10 (트랙 3 자막 없는 판) 으로 돌릴 것')
emu.log('  트랙 3 이 시작되면 $5B80-$5E1E 671 B 를 $EA 로 채우고, 끝나면 되돌린다')
emu.log('  국장실에서 깨지면 -> 점유만으로 충분.  원인 확정')
emu.log('  -> ' .. OUT)
