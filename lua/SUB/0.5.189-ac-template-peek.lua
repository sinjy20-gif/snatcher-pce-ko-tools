-- SUB 0.5.189 -- AC 템플릿이 어느 페이지에 구워져 있나 (즉시 1회 출력)
--
-- 왜: 헬퍼가 레코드마다 96 B 상수를 다시 읽는데(550 회 실측) 그 결과가 $00 이다.
--     그런데 부팅 직후 RAM 에는 진짜 상수 $05/$6B 가 들어 있었다.
--     -> 데이터는 구워져 있고 헬퍼만 엉뚱한 페이지를 읽는 것으로 보인다.
--
--     TEMPLATE_AC = STATE_AC + STATE_SPAN + IDLE_PAGE   # $10100, or $10200
--     헬퍼 관측 주소 = $010200
--
-- 판정
--   A 에 데이터 · B 전부 00  -> ★ 페이지 어긋남.  헬퍼 주소 한 줄이면 닫힌다
--   둘 다 00                 -> 템플릿이 안 구워졌다.  템플릿 단계 통째로 제거
--   B 에 데이터              -> 가설 틀림.  다시 판다
--
-- 로드하면 바로 찍고 끝난다.  게임 진행 중 아무 때나 해도 된다.

local AC = emu.memType.pceArcadeCardRam

local function rd(a)
  local ok, v = pcall(emu.read, a, AC)
  return (ok and type(v) == 'number') and v or -1
end

local function dump(base, name)
  local head, nonzero = {}, 0
  for i = 0, 95 do
    local v = rd(base + i)
    if i < 16 then head[#head + 1] = string.format('%02X', v) end
    if v ~= 0 then nonzero = nonzero + 1 end
  end
  local line = string.format('%s $%06X  [0]=%02X [95]=%02X  0아닌바이트 %d/96  앞16: %s',
    name, base, rd(base), rd(base + 95), nonzero, table.concat(head, ' '))
  emu.log(line); print(line)
end

print('--- AC 템플릿 후보 두 페이지 ---')
dump(0x10100, 'A')
dump(0x10200, 'B')
local line = string.format('참고  RAM $5BE0=%02X  $5C3F=%02X',
  emu.read(0x5BE0, emu.memType.pceMemory), emu.read(0x5C3F, emu.memType.pceMemory))
emu.log(line); print(line)
