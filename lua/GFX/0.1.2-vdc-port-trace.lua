-- GFX 0.1.2 -- 면책 화면 타일이 VRAM 에 앉는 시점·PC 를 VDC 포트로 잡는다
--
-- ★ 순수 관측.  아무것도 안 쓰고 화면에도 안 그린다.
--
-- 0.1.1 이 왜 0 회였나 (내 실수)
-- ------------------------------
-- 0.1.1 은 `pceVideoRam` 에 CPU **쓰기 콜백**을 걸었다.  그런데 PCE 는 CPU 가
-- VRAM 을 직접 주소지정하지 않는다 -- VDC 포트로 주소를 넣고 데이터를 밀어넣는다.
-- 그래서 콜백이 등록은 되지만 **영영 안 걸린다.**  "0 회" 는 "안 썼다" 가 아니라
-- "못 봤다" 였다.
--
--     ⚠ 못 잴 수 있는 프로브로 "없다" 를 결론내지 말 것.
--
-- 어떻게 잡나
-- ----------
-- ```
-- $0000 쓰기   VDC 레지스터 선택 (하위 5 비트)
-- $0002/$0003  그 레지스터의 하위/상위 바이트
--
--   reg $00 = MAWR   앞으로 쓸 VRAM 워드 주소
--   reg $02 = VWR    $0003(상위) 를 쓰는 순간 한 워드가 VRAM 에 들어가고
--                    MAWR 이 증가분만큼 늘어난다
-- ```
-- 그러니 reg 선택과 MAWR 을 따라가면 **어느 VRAM 주소에 썼는지** 알 수 있다.
--
-- 두 갈래로 잰다 -- 한쪽이 틀려도 다른 쪽이 남는다
-- ------------------------------------------------
--     ① 포트 추적    글자 타일 구간에 처음 쓴 프레임과 PC  (압축 해제 출구)
--     ② 프레임 폴링   그 구간을 매 프레임 훑어 **언제 채워지고 언제 멎는지**
--                     ②는 포트 해석이 틀려도 반드시 답이 나온다.  우리가 정말
--                     알고 싶은 것("덮어쓸 창이 있나")에는 ②만으로 충분하다
--
-- 글자 타일 구간 (0.1.0 실측)
-- ---------------------------
--     타일 $110-$1F5 · 바이트 $2200-$3EBF · 워드 $1100-$1F5F
--
-- ⚠ 세이브스테이트로 들어가지 말 것.  부팅 직후 화면이라 그럴 이유도 없다.
--
-- 쓰는 법
-- -------
--   1) 이 스크립트를 **먼저** 연다 (첫 쓰기를 놓치면 안 된다)
--   2) 부팅한다
--   3) 면책 화면이 지나고 몇 초 뒤 ★ Stop
--
-- 산출물  C:/snatcher/dump/gfx_0_1_2_<시각>.tsv

local MEM, CPU = emu.memType.pceMemory, emu.cpuType.pce
local VRAM = emu.memType.pceVideoRam

local WORD_LO, WORD_HI = 0x1100, 0x1F5F      -- 글자 타일 구간 (워드 주소)
local BYTE_LO = WORD_LO * 2

local stamp = "session"
if os ~= nil and os.date ~= nil then stamp = os.date("%Y%m%d_%H%M%S") end
local PATH = "C:/snatcher/dump/gfx_0_1_2_" .. stamp .. ".tsv"

local out = assert(io.open(PATH, "w"))
out:write("frame\tkind\taddr\tpc\tdetail\n")

local function say(m) emu.log(m); print(m) end

local frame = 0

-- ① 포트 추적 -------------------------------------------------------------
local selected = -1          -- 지금 고른 VDC 레지스터
local mawr = 0               -- 쓰기 주소
local portWrites = 0
local firstPort = nil
local writers = {}

emu.addMemoryCallback(function(addr, value)
  selected = value % 32
end, emu.callbackType.write, 0x0000, 0x0000, CPU, MEM)

emu.addMemoryCallback(function(addr, value)
  if selected == 0x00 then                 -- MAWR 하위
    mawr = (mawr & 0xFF00) | value
  end
end, emu.callbackType.write, 0x0002, 0x0002, CPU, MEM)

emu.addMemoryCallback(function(addr, value)
  if selected == 0x00 then                 -- MAWR 상위
    mawr = ((value & 0xFF) << 8) | (mawr & 0x00FF)
    return
  end
  if selected ~= 0x02 then return end       -- VWR 상위 = 한 워드 확정
  if mawr >= WORD_LO and mawr <= WORD_HI then
    portWrites = portWrites + 1
    local st = emu.getState()
    local pc = (st and st.cpu and st.cpu.pc) or 0
    writers[pc] = (writers[pc] or 0) + 1
    if firstPort == nil then
      firstPort = { frame = frame, word = mawr, pc = pc }
      say(string.format("★첫 타일 쓰기  f%d  VRAM 워드 $%04X  PC $%04X",
                        frame, mawr, pc))
      out:write(string.format("%d\tFIRST\t%04X\t%04X\t\n", frame, mawr, pc))
      out:flush()
    end
  end
  mawr = (mawr + 1) & 0xFFFF                -- 증가분은 보통 1.  대충 따라간다
end, emu.callbackType.write, 0x0003, 0x0003, CPU, MEM)

-- ② 프레임 폴링 -- 포트 해석이 틀려도 이건 답이 나온다 ---------------------
local BYTES = 256                            -- 구간 앞머리만 훑는다 (충분하다)
local last = nil
local filledAt, settledAt = nil, nil
local stableFor = 0

local function digest()
  local sum = 0
  for i = 0, BYTES - 1 do
    local b = emu.read(BYTE_LO + i, VRAM) or 0
    sum = (sum * 31 + b) % 0x7FFFFFFF
  end
  return sum
end

emu.addEventCallback(function()
  frame = frame + 1
  local d = digest()
  if last ~= nil and d ~= last then
    if filledAt == nil then
      filledAt = frame
      say(string.format("★타일 구간이 처음 바뀜  f%d  (폴링)", frame))
      out:write(string.format("%d\tFILL\t%04X\t\t폴링\n", frame, BYTE_LO))
      out:flush()
    end
    stableFor = 0
    settledAt = nil
  elseif filledAt ~= nil then
    stableFor = stableFor + 1
    if stableFor == 60 and settledAt == nil then
      settledAt = frame - 60
      say(string.format("  f%d 이후 60 프레임 그대로 -- 덮어쓸 창이 있다", settledAt))
      out:write(string.format("%d\tSETTLE\t\t\t60프레임 무변화\n", settledAt))
      out:flush()
    end
  end
  last = d
  if frame % 300 == 0 then
    say(string.format("f%d  포트로 본 쓰기 %d 회 · 폴링 변화 %s",
                      frame, portWrites, filledAt and ("f" .. filledAt) or "없음"))
  end
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  say("")
  say("끝 -- 글자 타일 구간 (워드 $1100-$1F5F · 바이트 $2200-$3EBF)")
  say(string.format("  ① 포트로 본 쓰기 %d 회", portWrites))
  if firstPort ~= nil then
    say(string.format("     첫 쓰기 f%d  PC $%04X", firstPort.frame, firstPort.pc))
    local list = {}
    for pc, n in pairs(writers) do list[#list + 1] = { pc = pc, n = n } end
    table.sort(list, function(a, b) return a.n > b.n end)
    for i = 1, math.min(#list, 8) do
      say(string.format("     PC $%04X  x%d", list[i].pc, list[i].n))
      out:write(string.format("0\tWRITER\t\t%04X\t%d\n", list[i].pc, list[i].n))
    end
  else
    say("     ★포트로는 못 잡았다 (레지스터 해석이 틀렸을 수 있다)")
  end
  say(string.format("  ② 폴링  채워짐 %s · 멎음 %s",
                    filledAt and ("f" .. filledAt) or "없음",
                    settledAt and ("f" .. settledAt) or "없음"))
  if filledAt == nil then
    say("     ★폴링도 변화를 못 봤다 -- 그 화면을 안 지났거나 구간이 틀렸다")
  end
  out:close()
  say("  " .. PATH)
end, emu.eventType.scriptEnded)

say("GFX 0.1.2 -- 스크립트를 먼저 열고 부팅해라.  면책 화면이 지나면 Stop")
say("  " .. PATH)
