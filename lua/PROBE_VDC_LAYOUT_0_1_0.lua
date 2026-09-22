-- PROBE_VDC_LAYOUT 0.1.0
--
-- 무엇을 재나
-- ------------
-- 지금 이 장면에서 VDC 가 SATB 와 BAT 을 어디에 두고 있는지.  추측을 끝낸다.
--
-- 왜 필요한가
--   SUBTITEL 0.2.11 이 SAT 엔트리를 VRAM 워드 $1000+40*4 에 썼더니 **타일맵이
--   통째로 깨졌다.**  즉 거기는 SATB 가 아니라 BAT 이었다.
--
--   $1000 은 PROBE_OPENING_SPRITE 가 **오프닝에서** 잰 satbBlockSrc 다.
--   오프닝은 스프라이트를 아예 안 켜는 화면이라 일반 대사와 배치가 다를 수 있다.
--   같은 함정(오프닝 값을 일반 대사에 적용)을 오늘 두 번 밟았다.
--
-- 출력  로그 + C:/snatcher/dump/probe_vdc_layout_0_1_0_<날짜>.tsv
--
-- 쓰는 법
--   **음성 대사 장면에서** 실행하고 바로 정지하면 된다.  아무것도 안 건드린다.

local function dump()
  local st = emu.getState()
  local keys = {}
  for k, v in pairs(st) do
    if type(k) == "string" and k:lower():find("vdc") then keys[#keys + 1] = k end
  end
  table.sort(keys)

  local name = string.format('C:/snatcher/dump/probe_vdc_layout_0_1_0_%s.tsv',
                             os.date('%Y%m%d_%H%M%S'))
  local f = io.open(name, 'w')
  if f then f:write('key\tvalue\thex\n') end

  emu.log('--- vdc.* 상태 ---')
  for _, k in ipairs(keys) do
    local v = st[k]
    local hex = ''
    if type(v) == 'number' and v == math.floor(v) and v >= 0 then
      hex = string.format('$%X', v)
    end
    emu.log(string.format('  %-42s %s  %s', k, tostring(v), hex))
    if f then f:write(string.format('%s\t%s\t%s\n', k, tostring(v), hex)) end
  end

  -- 관심 항목만 다시 짚어 준다
  local pick = {
    'vdc.satbBlockSrc', 'vdc.satbTransferPending', 'vdc.spritesEnabled',
    'vdc.bgEnabled', 'vdc.hvReg.columnCount', 'vdc.hvReg.rowCount',
    'vdc.memAddrWrite', 'vdc.memAddrRead',
  }
  emu.log('--- 요약 ---')
  for _, k in ipairs(pick) do
    if st[k] ~= nil then
      local v = st[k]
      emu.log(string.format('  %-28s %s%s', k, tostring(v),
              type(v) == 'number' and string.format('  ($%X · 워드)', v) or ''))
    end
  end
  if st['vdc.satbBlockSrc'] ~= nil then
    emu.log(string.format('  ★ SATB 는 VRAM 워드 $%X 다.  0.2.11 은 $1000 에 썼다',
            st['vdc.satbBlockSrc']))
  end
  if f then f:close(); emu.log('-> ' .. name) end
end

emu.addEventCallback(dump, emu.eventType.scriptEnded)
emu.log('PROBE_VDC_LAYOUT 0.1.0 loaded')
emu.log('  음성 대사 장면에서 그냥 정지하면 그 시점의 VDC 배치를 찍는다')
