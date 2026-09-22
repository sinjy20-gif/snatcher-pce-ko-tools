-- SUB 0.3.10 -- translated-sign boot AC verifier (read-only)
-- 0.4.5.9-signtest-boot-ac-subtitle CUE/BIOS 전용. 이 파일 하나만 실행한다.

local AC, MEM, CPU = emu.memType.pceArcadeCardRam, emu.memType.pceMemory, emu.memType.cpu
local checked, demandInit = false, false

local function readFile(path)
  local f = assert(io.open(path, 'rb'), 'cannot open ' .. path)
  local d = f:read('*a'); f:close(); return d
end

local translation = readFile('C:/snatcher/build/patch/0.4.5.9-signtest-base/ac_dynamic_packs/disc_package_image.bin')
translation = translation:sub(1, 0x10000)
  .. string.char(0xAC, 0x15, 0x51, 1, 1, 1)
  .. translation:sub(0x10007)

local pack = readFile('C:/snatcher/build/cutscene_subs/subtitle_pack.bin')
local helper = readFile('C:/snatcher/build/cutscene_subs/resident_helper_slot_native_poll_0_8_3.bin')
local renderer = readFile('C:/snatcher/build/cutscene_subs/resident_renderer_slot_native_poll_0_8_4_r3.bin')

local function mismatch(blob, base)
  local bad, first = 0, nil
  for i = 1, #blob do
    if (emu.read(base + i - 1, AC) or 0) ~= blob:byte(i) then
      bad = bad + 1
      if not first then first = i - 1 end
    end
  end
  return bad, first
end

emu.addMemoryCallback(function()
  demandInit = true
  emu.log('SUB 0.3.10 ★ FAIL: 기존 수요 적재 init_store 실행')
end, emu.callbackType.exec, 0xBD13, 0xBD13, emu.cpuType.pce, CPU)

emu.addMemoryCallback(function()
  if checked then return end
  checked = true
  emu.log('SUB 0.3.10 first Korean lookup -- translated sign AC audit')
  local rows = {
    {'translation', translation, 0x000000},
    {'subtitle pack', pack, 0x1C0000},
    {'subtitle helper', helper, 0x1F1C00},
    {'subtitle renderer', renderer, 0x1F1F00},
  }
  local total = 0
  for _, row in ipairs(rows) do
    local bad, first = mismatch(row[2], row[3])
    total = total + bad
    emu.log(string.format('  %-17s mismatch=%d/%d%s', row[1], bad, #row[2],
      first and string.format(' first=AC $%06X', row[3] + first) or ''))
  end
  if total == 0 and not demandInit then
    emu.log('SUB 0.3.10 ★ SIGNTEST AC PASS: 번역 전체 + 자막 3종 exact · 수요 적재 0')
  else
    emu.log(string.format('SUB 0.3.10 ★ SIGNTEST AC FAIL: mismatch=%d demand_init=%s',
                          total, tostring(demandInit)))
  end
end, emu.callbackType.exec, 0x5E40, 0x5E40, emu.cpuType.pce, CPU)

emu.log('SUB 0.3.10 loaded -- translated-sign AC verifier / 완전 읽기 전용')
emu.log('  새 CUE+BIOS로 전원 재시작 · 코나미 빌딩 한글/적재 위치/접수처 UI 확인')
