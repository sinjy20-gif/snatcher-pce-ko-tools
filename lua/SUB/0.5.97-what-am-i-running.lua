-- SUB 0.5.97 -- 지금 무엇이 돌고 있는지 찍는다 (BIOS · 팩 · 자막 세트)
--
-- 왜
-- ---------------------------------------------------------------------------
-- "화면이 깨지고 자막이 옛것만 뜬다" 는 두 가지로 갈린다.
--
--     ① BIOS 에 671 B 처방이 없다        -> 화면이 깨진다 (0.4.6.48 이하)
--     ② AC 에 옛 팩이 올라가 있다        -> 자막이 옛 내용으로 뜬다
--
-- Mesen 은 BIOS 를 옵션에서 따로 고르므로, CUE 만 새 것으로 열고 BIOS 는 옛것이
-- 걸려 있으면 정확히 이 증상이 난다.  추측하지 말고 메모리에서 직접 읽는다.
--
-- 무엇을 보나
-- ---------------------------------------------------------------------------
-- ```
-- BIOS  뱅크$01 $FC7A   671 B 처방 코드가 있는가
--       AD 83 5B C9 AD  = 있다 (0.4.6.60 / .62)
--       FF FF FF FF FF  = 없다 (0.4.6.48 이하)   -> 화면이 깨진다
--
-- 팩    AC $000000 머리 16 B
--       53 4E 53 42 ... 오프셋 10 이  E6 F6 = 옛 팩 8F20AF38
--                                     DD F6 = 새 팩 CDC3A4C4
-- ```
--
-- ★ 게임을 한 바이트도 안 고친다.  화면에 아무것도 안 그린다.
-- ★ 로드하자마자 찍는다.  Power Cycle 도 필요 없다.
--
-- 산출물  C:/snatcher/dump/whatami_0_5_97_<시각>.tsv

local MEM = emu.memType.pceMemory
local AC  = emu.memType.pceArcadeCardRam

local STAMP = os.date('%Y%m%d_%H%M%S')
local PATH  = 'C:/snatcher/dump/whatami_0_5_97_' .. STAMP .. '.tsv'

local function say(f, ...) emu.log(string.format(f, ...)) end
local function hex(read, from, n)
  local t = {}
  for i = 0, n - 1 do t[#t + 1] = string.format('%02X', read(from + i) or 0) end
  return table.concat(t, ' ')
end

local reported = false
local frame = 0

emu.addEventCallback(function()
  frame = frame + 1
  if reported or frame < 120 then return end     -- AC 선적재가 끝날 시간을 준다
  reported = true

  local out = assert(io.open(PATH, 'w'))
  out:write('what\tvalue\tverdict\n')

  -- 1) BIOS -- 671 B 처방.  뱅크 $01 이 MPR7 에 올라와 있을 때만 $FCxx 가 그것이다.
  --    상시로 보려면 파일이 아니라 실행 흔적을 봐야 하므로, 여기서는 CPU 가 보는
  --    $FC7A 를 그대로 읽고 두 형태 중 어느 것인지만 가른다.
  local bios = hex(function(a) return emu.read(a, MEM) end, 0xFC7A, 5)
  local fixed = bios:sub(1, 14) == 'AD 83 5B C9 AD'
  say('0.5.97 BIOS  $FC7A = %s   -> %s', bios,
      fixed and '671 B 처방 있음 (0.4.6.60 / .62)'
             or '★ 처방 없음 -- 화면이 깨진다 (0.4.6.48 이하이거나 뱅크가 안 걸렸다)')
  out:write(string.format('bios_fc7a\t%s\t%s\n', bios, tostring(fixed)))

  -- 2) 팩 -- AC $000000 에 선적재된 번역 이미지 머리
  local head = hex(function(a) return emu.read(a, AC) end, 0x000000, 16)
  local mark = string.format('%02X %02X', emu.read(0x00000A, AC) or 0,
                                          emu.read(0x00000B, AC) or 0)
  local which = (mark == 'E6 F6') and '옛 팩 8F20AF38'
             or ((mark == 'DD F6') and '★ 새 팩 CDC3A4C4' or '알 수 없음')
  say('0.5.97 번역   AC $000000 = %s', head)
  say('0.5.97        오프셋 10-11 = %s   -> %s', mark, which)
  out:write(string.format('ac_head\t%s\t%s\n', head, which))

  -- 3) 자막 팩 -- AC $1C0000 (선적재 표의 subtitle_pack destination)
  local sub = hex(function(a) return emu.read(a, AC) end, 0x1C0000, 16)
  local submark = string.format('%02X %02X', emu.read(0x1C000A, AC) or 0,
                                             emu.read(0x1C000B, AC) or 0)
  local subwhich = (submark == 'E6 F6') and '옛 팩 8F20AF38'
                or ((submark == 'DD F6') and '★ 새 팩 CDC3A4C4' or '알 수 없음')
  say('0.5.97 자막팩 AC $1C0000 = %s', sub)
  say('0.5.97        오프셋 10-11 = %s   -> %s', submark, subwhich)
  out:write(string.format('ac_subtitle_pack\t%s\t%s\n', sub, subwhich))

  say('0.5.97 저장 : %s', PATH)
  out:close()
end, emu.eventType.endFrame)

say('SUB 0.5.97-what-am-i-running armed -- 120 프레임 뒤에 한 번만 찍는다')
say('  BIOS 671 B 처방 · AC 번역 이미지 · AC 자막 팩 셋을 확인한다')
