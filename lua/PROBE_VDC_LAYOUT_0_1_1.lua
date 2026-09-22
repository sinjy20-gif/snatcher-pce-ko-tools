-- PROBE_VDC_LAYOUT 0.1.1
--
-- 0.1.0 에서 바뀐 것
--   1  키 이름에 'vdc' 가 없으면 아무것도 안 찍혔다.  이제 **전부** 찍는다
--   2  scriptEnded 에만 저장했다.  정지를 깜빡하면 파일이 안 생긴다.
--      이제 **60 프레임째에 한 번 저장**하고 정지 때 한 번 더 한다
--
-- 무엇을 재나
--   지금 이 장면에서 VDC 가 SATB 와 BAT 을 어디에 두고 있는지.
--
-- 왜 필요한가
--   SUBTITEL 0.2.11 이 SAT 엔트리를 VRAM 워드 $10A0 에 썼더니 **타일맵이 깨졌다.**
--   거기는 SATB 가 아니라 BAT 이었다는 뜻이다.  $1000 은 PROBE_OPENING_SPRITE 가
--   **오프닝에서** 잰 값인데, 오프닝은 스프라이트를 아예 안 켜는 화면이라
--   일반 대사와 배치가 다르다.
--
-- 출력  C:/snatcher/dump/probe_vdc_layout_0_1_1_<날짜>.tsv   (읽기만 한다)
--
-- 쓰는 법
--   **음성 대사 장면에서** 실행하고 몇 초 두면 알아서 저장된다.

local frames, saved = 0, 0

local function save(tag)
  local st = emu.getState()
  local keys = {}
  for k, _ in pairs(st) do keys[#keys + 1] = tostring(k) end
  table.sort(keys)

  local name = string.format('C:/snatcher/dump/probe_vdc_layout_0_1_1_%s_%s.tsv',
                             os.date('%Y%m%d_%H%M%S'), tag)
  local f = io.open(name, 'w')
  if f == nil then emu.log('저장 실패: ' .. name) return end
  f:write('key\tvalue\thex\n')
  for _, k in ipairs(keys) do
    local v = st[k]
    local hex = ''
    if type(v) == 'number' and v == math.floor(v) and v >= 0 then
      hex = string.format('$%X', v)
    end
    f:write(string.format('%s\t%s\t%s\n', k, tostring(v), hex))
  end
  f:close()
  saved = saved + 1
  emu.log(string.format('PROBE_VDC_LAYOUT 0.1.1 -> %s  (키 %d 개)', name, #keys))

  -- 관심 항목을 로그에도 바로 띄운다
  for _, k in ipairs(keys) do
    local lk = k:lower()
    if lk:find('satb') or lk:find('sprite') or lk:find('bat')
       or lk:find('column') or lk:find('row') or lk:find('mapw') or lk:find('maph') then
      local v = st[k]
      emu.log(string.format('  %-40s %s%s', k, tostring(v),
              (type(v) == 'number' and v == math.floor(v)) and string.format('  ($%X)', v) or ''))
    end
  end
end

emu.addEventCallback(function()
  frames = frames + 1
  if frames == 60 then save('f60') end
end, emu.eventType.startFrame)

emu.addEventCallback(function()
  if saved == 0 then save('end') else save('end') end
end, emu.eventType.scriptEnded)

emu.log('PROBE_VDC_LAYOUT 0.1.1 loaded')
emu.log('  음성 대사 장면에서 1 초만 두면 알아서 저장된다.  게임은 안 건드린다')
