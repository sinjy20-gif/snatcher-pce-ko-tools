-- Snatcher KO runtime text audit 0.2.2 -- captures at the buffer base.
-- Portable tool copy: snatcher_tool\mesen\runtime_text_audit_0.2.2.lua
--
-- 0.2.1 (2026-08-18) -- 왜 고쳤나
--
--   PROBE 0.6.8 실측: $3471 은 53 종의 값을 가지며, 렌더 사이클은
--       $3610 -> $3612 -> ... -> $3619 -> $5B90(치환 출력) -> INSTALL
--   으로 돈다.  0.2.0 은 $3471 == $3619 인 순간에만 읽었는데, 그 순간
--   $3619 는 187 회 중 184 회 이미 0xFF 였다 (UI 는 366 회 중 363 회).
--   원문은 그 9 바이트 앞, $3610 에 프리픽스와 함께 통째로 놓여 있다.
--
--   그래서 잡던 것이 전체의 일부였다.  문서 뷰어(가우디 사전)가 0 건이었던
--   것도 '다른 렌더러라서' 가 아니라 이 때문이다 -- 렌더러는 같다.
--
--   고친 것: $3610 / $3490 에서도 잡는다.  본문은 +9 부터 읽으므로
--   source_hex 는 0.2.0 과 같은 형식이고 정적 대장 매칭이 깨지지 않는다.
--   프리픽스 9 바이트는 header_hex 열에 따로 남긴다 (FB xx yy 가 화면 행).
--
--   출력은 별도 파일이다.  raw_v020.tsv 에 섞으면 검증 전 행이
--   build_runtime_master.py 를 통해 마스터로 들어간다.
--
-- Run this script by itself in Mesen, power-cycle, and play normally.  Every
-- completed $3619 source buffer is captured before the Korean preloader and
-- again after it returns.  The file contains only hexadecimal bytes, so no
-- Japanese/Korean encoding support is required inside Mesen.
--
-- Requires:
-- Script -> Settings -> Script Window -> Restrictions -> Allow I/O and OS
--
-- ===========================================================================
-- 0.2.0 (2026-08-15) -- 문단 경계를 추측에서 관측으로
-- ===========================================================================
--
-- 0.1.x 가 무엇을 틀렸나
-- ---------------------
-- `resolveAfterControl` 은 경계를 3단으로 판정한다.  디코더가 0D:32/33(BR) 또는
-- 0D:36/37(PAGE) 를 쓴 것만 관측이고, 나머지는 **18칸을 채웠으면 CONT, 아니면
-- END** 라는 추측이다.  아카이브 원시 로그 4개 4,957행 실측:
--
--   END  · SHORT_BUFFER (추측)    3,491
--   CONT · FULL_18_CELLS (추측)     736
--   END  · UI_BUFFER                702
--   BR   · DECODER_WRITE (관측)      23
--   PAGE · DECODER_WRITE (관측)       5
--
-- 관측 28건, 나머지 99.3% 는 칸 수로 찍은 것이다.
--
-- 18칸 추측 자체는 대부분 맞다.  문제는 **레코드 끝에서 멈출 방법이 없다**는 것
-- 하나다.  문단의 마지막 줄이 마침 18칸을 채우면 CONT 로 판정되고, 그 다음에 오는
-- 캡처(= 다음 대사의 화자명)를 같은 블록으로 삼킨다.
--
--   <원문 12자>。<원문 5자> | いけど、<원문 13자>。 | ミカ
--   ギリアン | <원문 17자>。      <- 18칸으로 끝남
--
-- 아카이브 로그에서 129 블록(고유 69종)이 이 상태다.
--
-- PROBE 0.6.7 이 무엇을 확인했나 (dump\probe_v067_20260815_213958.tsv)
-- -------------------------------------------------------------------
-- 스크립트 명령 레코드가 곧 문단이고, 그 시작은 `$6FFD` 에서 관측된다.
--
--   $6FFD  LDA $3671 / STA $E0    새 레코드의 텍스트 포인터 설치 = 문단 시작
--
--   레코드                            130
--   첫 TEXT 렌더가 알려진 화자명       130/130   예외 0
--   마지막 줄이 18칸인 레코드           11/130   기존 수집기가 흘렸을 자리
--
-- 실제 모양:
--
--   -- START $28A9
--      受付嬢                                 <- 화자
--      <원문 18자>     <- 18칸
--      か？                                   <-  2칸
--
-- 두 가지가 같이 풀린다.  레코드가 문단이고, **첫 렌더가 화자다.**  0.1.x 는 화자
-- 판정을 구조적으로 불가능하다고 보고 포기했는데(rebuild_runtime_context.py 주석),
-- 그것은 렌더러만 봤을 때의 이야기였다.
--
-- 안 쓰기로 한 것
-- --------------
--   $3607  디코더의 "끝" 플래그.  레코드당 1~2회 뜨고 화면 줄 끝과 안 맞는다.
--          130 레코드 중 49개에서 2회 떴다.  경계로 쓸 수 없다
--   $7062  레코드 전진.  22,118회 떴다 -- 레코드당 한 번이 아니다
--
-- 필요가 없다.  레코드는 **다음 $6FFD 가 끊어준다.**
--
-- 0.2.0 이 바꾼 것
-- ---------------
--   열 3개 추가 (맨 뒤).  기존 열은 의미까지 그대로 둔다 -- 새 경계와 옛 추측을
--   나란히 두어야 이미 모아둔 로그와 대조가 되고, 어느 쪽이 틀렸는지 판정할 수
--   있다.  after_control 은 여전히 추측이며 그렇게 읽어야 한다.
--
--     record_seq    이 캡처가 속한 레코드 번호.  같은 번호 = 같은 문단
--     record_line   레코드 안에서 몇 번째 TEXT 캡처인가.  1 = 화자
--     record_ptr    그 레코드의 소스 포인터 ($3671/$3672)
--
--   출력 경로도 같이 올렸다.  0.1.x 로그를 덮으면 어느 코드가 그 숫자를 만들었는지
--   사라진다 (lua\README.md 규율).
--
-- 읽는 법
-- -------
--   문단 = record_seq 가 같은 행들.  record_line=1 이 화자, 2 이후가 본문
--   after_control 로 묶지 말 것.  그것이 0.1.x 가 틀린 지점이다
--
-- 알려진 예외 (7/130)
-- ------------------
--   `Judgement Uninfected Naked / Kind & Execute Ranger` 아크로님 연출은 여러
--   상자에 걸쳐 나오면서 레코드 중간에 화자명을 다시 찍는다.  record_line>1 인데
--   화자명인 행이 그것이다.  별도 취급할 것

local mem = emu.memType.pceMemory
local outputPath = "C:\\snatcher\\dump\\runtime_text_audit_raw_v020.tsv"
-- Generated from the static master before play.  The hook only sees the
-- completed renderer buffer, so this maps its exact source bytes/control
-- pair back to the canonical static text_key and scene.
local staticIndexPath = "C:\\snatcher\\snatcher_tool\\mesen\\runtime_static_index.tsv"
local voiceOutputPath = "C:\\snatcher\\snatcher_tool\\logs\\voice_events_raw.tsv"
-- Kept as a separate raw file because Studio's UI tab consumes this schema.
-- Unlike the stand-alone collector, this unified audit appends: a new Mesen
-- session must never erase UI strings collected during an earlier route.
local uiOutputPath = "C:\\snatcher\\dump\\runtime_ui_strings_raw_v020.tsv"

-- 0.2.3 (2026-08-24): 음성 클립 덤프를 되살린다.
--
-- 왜 되살리나 -- 이 파일에는 없었다
-- ---------------------------------------------------------------------------
-- 같은 0.2.2 판이 둘 있었고, **이쪽(lua\)에는 음성 덤프가 없었다.**  표
-- (voice_events_raw.tsv)만 쌓고 소리는 한 개도 안 떴다.  2026-08-21 엔딩 주행을
-- 이걸로 돌려서 그 판의 음성이 통째로 날아갔다.  덤프가 있는 쪽은
-- snatcher_tool\mesen\runtime_text_audit_0.2.2.lua 였다.
-- 아래는 그쪽 0.2.2 의 덤프 코드를 옮기고 중복 방지와 카운터를 얹은 것이다.
--
-- 폴더는 미리 있어야 한다.  없으면 첫 클립에서 크게 알린다.
--
-- 폴더 이름에 판 번호를 안 붙인다 -- 프로브 로그와 달리 이 폴더는 **세션을 넘어
-- 쌓이는 수집물**이고, 중복 판정이 "이미 이 파일이 있나" 로 이뤄진다.  판마다
-- 폴더를 가르면 지금까지 모은 것을 못 보게 되어 같은 대사를 다시 뜬다.
local voiceDumpDir = "C:\\snatcher\\snatcher_tool\\logs\\voice_clips\\"
local ADPCM_RAM_SIZE = 0x10000
-- 이름으로 찾는다.  숫자(63)를 박아 넣으면 Mesen 판이 바뀔 때 조용히 밀린다.
local adpcmMem = emu.memType.pceAdpcmRam
local voiceDumpFailed = 0
-- 카운터.  화면 왼쪽 위에 그대로 찍는다.
--   voiceClipNew   이번 주행에서 처음 본 음성 (파일이 새로 생긴 것)
--   voiceClipDup   같은 음성이 또 나온 것 (파일을 다시 안 쓴다)
--   voiceClipFail  뜨지 못한 것 (폴더 없음 · 길이 0 · ADPCM 메모리 없음)
local voiceClipNew = 0
local voiceClipDup = 0
local voiceClipFail = 0
-- 지문 -> true.  한 세션 안에서는 파일을 열어 보지 않고 이걸로 먼저 거른다.
local voiceClipSeen = {}
local pending = nil
local sequence = 0
-- 0.2.0: the observed record boundary.  $6FFD installs the next command
-- record's text pointer, so it fires exactly once per paragraph -- unlike
-- $3607 (1-2 per record) and $7062 (22,118 in an 11-minute run).
local recordSeq = 0
local recordLine = 0
local recordPtr = 0
local voiceWasPlaying = false
local activeVoice = nil
local voiceSequence = 0
local voiceSession = "session"
-- CD-DA (오프닝 나레이션 계열).  일반 대사는 ADPCM 이지만 오프닝은 Mesen 의
-- cdrom.audioPlayer 경로를 쓴다 -- 그래서 ADPCM 감시만으로는 안 잡혔다.
-- (additional\SNATCHER_OPENING_CD_AUDIO_HANDOFF.md 실측)
--   START = currentSector 가 전진하기 시작
--   END   = CDDA_STOP_GRACE_FRAMES 동안 전진이 없음
-- 유예를 두는 이유는 섹터 갱신이 잠깐 끊길 때 한 재생이 여러 이벤트로 쪼개지는
-- 것을 막기 위해서다.  12프레임 = 약 0.2초.
local CDDA_STOP_GRACE_FRAMES = 12
local cddaActive = nil
local cddaPreviousSector = nil
local cddaLastAdvanceFrame = nil
local uiSeen = {}
local uiCount = 0
-- The $7272 decoder writes its reconstructed pair through $360D/$360E.  A
-- small subset of 0D:xx pairs is consumed by $7405 as a structural command
-- rather than being rendered as text.  Keep the most recent structural
-- command so the next completed renderer buffer can record its real suffix.
-- This removes Studio's former "everything is END" guess.
local pendingDecoderHigh = nil
local latestStructuralControl = nil
-- The decoder writes the control while assembling, a few frames before the
-- renderer hands the line over.  The old value of 2 frames was tight enough to
-- lose the control on a slow line; a second is generous for one line yet still
-- far shorter than the gap to the next unrelated capture.
local CONTROL_MAX_AGE_FRAMES = 60
-- $349A is the renderer-visible low-byte position, but the completed Shift-JIS
-- menu string actually starts one byte earlier at $3499.  Starting at $349A
-- drops every first lead byte (e.g. 92 86 "中" becomes the invalid 86).
local uiBufferStart = 0x3499

if os ~= nil and os.date ~= nil then
  voiceSession = os.date("%Y%m%d_%H%M%S")
end

local function byte(address)
  return emu.read(address, mem) or 0
end

local function word(address)
  return byte(address) + byte(address + 1) * 0x100
end

local function readString(address)
  local values = {}
  for index = 0, 0x3F do
    local value = byte(address + index)
    if value == 0xFF then break end
    values[#values + 1] = value
  end
  return values
end

local function toHex(values)
  local parts = {}
  for index, value in ipairs(values) do
    parts[index] = string.format("%02X", value)
  end
  return table.concat(parts, " ")
end

local staticIndex = {}

local function compactHex(value)
  return (value or ""):gsub("%s+", "")
end

local function loadStaticIndex()
  local file, openError = io.open(staticIndexPath, "rb")
  if file == nil then
    emu.log("RTA STATIC INDEX missing: " .. staticIndexPath .. " (runtime-only capture will continue)")
    return
  end
  -- Header is deliberately ASCII.  Mesen Lua never has to parse Japanese.
  file:read("*l")
  local count = 0
  for line in file:lines() do
    local source, control, refs, scene = line:match("^([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)$")
    if source ~= nil and control ~= nil then
      staticIndex[source .. "|" .. control] = { refs = refs or "", scene = scene or "" }
      count = count + 1
    end
  end
  file:close()
  emu.log("RTA STATIC INDEX loaded rows=" .. count)
end

local function staticLocation(sourceHex, afterControl)
  local entry = staticIndex[compactHex(sourceHex) .. "|" .. (afterControl or "")]
  if entry == nil then return "", "" end
  return entry.refs, entry.scene
end

-- Reject snapshots taken while the menu builder is still halfway through a
-- string.  UI_BUFFER is plain Shift-JIS; unlike narrative replacement text it
-- must not contain custom F0-F7 leads.
local function isCompleteUiShiftJis(values)
  if #values == 0 then return false end
  local index = 1
  while index <= #values do
    local value = values[index]
    if value >= 0x81 and value <= 0x9F or value >= 0xE0 and value <= 0xEF then
      if index == #values then return false end
      local trail = values[index + 1]
      if not ((trail >= 0x40 and trail <= 0x7E) or (trail >= 0x80 and trail <= 0xFC)) then
        return false
      end
      index = index + 2
    elseif value >= 0x20 and value <= 0x7E or value >= 0xA1 and value <= 0xDF then
      index = index + 1
    else
      return false
    end
  end
  return true
end

local function currentFrame()
  local state = emu.getState()
  return state["frameCount"] or 0
end

-- The bank mapped at MPR6 when the renderer hands text over.  Measured across a
-- full JUNKER HQ playthrough (MPR 0.1.1): it is constant for every line of a
-- scene, changes the moment the scene does, reproduces across power cycles
-- (reception read $74 in two independent sessions), and puts the shared
-- "where to next" prompt on its own bank -- which is what the build already
-- calls the resident `shared` pack.
--
-- That makes it the pack key, recorded as fact at capture time.  It replaces
-- inferring a scene afterwards by finding the nearest text match in a catalog,
-- which needed static extraction to be trustworthy and could not classify a
-- line the extractor never saw.  The number is a RAM staging bank, not a CD
-- offset, so it does not translate to a `scene_111800` name -- but the build
-- only needs a stable grouping key, and `classify` returns a plain string.
-- `cdrom.scsi.sector` is the CD coordinate the drive last served, verified
-- separately while tracing the title graphics.  It complements the bank: MPR6
-- groups lines that must be co-resident, the sector says where on the disc that
-- group came from.  Both come out of one getState so the capture still costs a
-- single call.
local function captureContext()
  local ok, state = pcall(emu.getState)
  if not ok or state == nil then return "??", -1 end

  local bank = state["memoryManager.mpr[6]"]
  if bank == nil and type(state.memoryManager) == "table"
      and type(state.memoryManager.mpr) == "table" then
    bank = state.memoryManager.mpr[6]
  end

  local sector = state["cdrom.scsi.sector"]
  if type(sector) ~= "number" then sector = -1 end

  return bank == nil and "??" or string.format("%02X", bank), sector
end

-- 0.2.0 appends record_seq/record_line/record_ptr at the end.  Appending rather
-- than inserting keeps every positional reader of the 0.1.x schema working.
local auditHeader = "seq\tframe\tptr\tafter_ptr\tstate_before\tstate_after\tread_status\tchanged\tsource_hex\tafter_hex\tchannel\tafter_control\tcontrol_origin\tcontrol_hex\tsource_cells\tstatic_refs\tstatic_scene\tpack\tsector\trecord_seq\trecord_line\trecord_ptr\tcapture_at\theader_hex\n"

local function sourceCells(values)
  local cells, index = 0, 1
  while index <= #values do
    local value = values[index]
    -- FE:n is a non-printing renderer state token.  It consumes two bytes in
    -- the source buffer but no visible character cell.
    if value == 0xFE and index < #values then
      index = index + 2
    elseif (value >= 0x81 and value <= 0x9F) or (value >= 0xE0 and value <= 0xEF) then
      cells = cells + 1
      index = index + (index < #values and 2 or 1)
    else
      cells = cells + 1
      index = index + 1
    end
  end
  return cells
end

local function structuralControlForPair(high, low)
  if high ~= 0x0D then return nil end
  if low == 0x32 or low == 0x33 then return "BR" end
  if low == 0x36 or low == 0x37 then return "PAGE" end
  -- 0D:38..3C become inline FE renderer controls. They are already retained
  -- inside source_hex, so they do not determine a buffer suffix.
  return nil
end

local function onDecoderHighWrite(address, value)
  pendingDecoderHigh = value
end

local function onDecoderLowWrite(address, value)
  local control = structuralControlForPair(pendingDecoderHigh, value)
  if control == nil then return end
  latestStructuralControl = {
    name = control,
    frame = currentFrame(),
    hex = string.format("%02X %02X", pendingDecoderHigh, value),
  }
  emu.log(string.format("RTA CONTROL %s pair=%s frame=%d", control, latestStructuralControl.hex, latestStructuralControl.frame))
end

-- The decoder writes the structural control while it is assembling the line, so
-- the control seen since the previous capture is this line's terminator.  The
-- old two-frame window was both too narrow and too wide: a slow line lost its
-- BR, and a control left in the variable could be re-attributed to the next
-- line as well.  Claiming it -- clearing it on use -- makes the association
-- exactly one-to-one.
local function resolveAfterControl(source, frame)
  if latestStructuralControl ~= nil then
    local control = latestStructuralControl
    -- Claim it either way: a control older than the window belongs to a line
    -- that was never captured (a menu, a skipped box), and leaving it in place
    -- would let it attach to some unrelated line later.
    latestStructuralControl = nil
    if frame - control.frame <= CONTROL_MAX_AGE_FRAMES then
      return control.name, "DECODER_WRITE", control.hex
    end
  end
  if sourceCells(source) >= 18 then
    return "CONT", "FULL_18_CELLS", ""
  end
  -- No decoder evidence at all.  END is the right guess for a short buffer, but
  -- the origin column keeps it distinguishable from a confirmed one so the
  -- Studio never presents a guess as fact.
  return "END", "SHORT_BUFFER", ""
end

local function ensureAuditHeader()
  local existing = io.open(outputPath, "rb")
  local needsHeader = existing == nil
  if existing ~= nil then
    local length = existing:seek("end") or 0
    existing:seek("set", 0)
    local existingHeader = existing:read("*l") or ""
    existing:close()
    needsHeader = length == 0
    -- Do not append v2 rows below the old v1 header: every field would shift
    -- during Studio import. Preserve the legacy session beside the new file.
    if not needsHeader and existingHeader ~= auditHeader:sub(1, -2) then
      local suffix = os and os.date and os.date("%Y%m%d_%H%M%S") or "legacy"
      local legacyPath = outputPath:gsub("%.tsv$", "_legacy_" .. suffix .. ".tsv")
      local renamed, renameError = os.rename(outputPath, legacyPath)
      if not renamed then
        emu.log("RTA ERROR preserving legacy log: " .. tostring(renameError))
        return false
      end
      emu.log("RTA migrated legacy raw log to " .. legacyPath)
      needsHeader = true
    end
  end
  if not needsHeader then return true end
  local output, openError = io.open(outputPath, "ab")
  if output == nil then
    emu.log("RTA ERROR opening " .. outputPath .. ": " .. tostring(openError))
    return false
  end
  output:write(auditHeader)
  output:flush()
  output:close()
  return true
end

if not ensureAuditHeader() then return end
loadStaticIndex()

-- Do not keep the audit file locked while Mesen is running.  Opening it only
-- for each append lets the portable Studio analyze and watch it in real time.
local function appendLine(line)
  if not ensureAuditHeader() then return false end
  local file, err = io.open(outputPath, "ab")
  if file == nil then
    emu.log("RTA ERROR appending " .. outputPath .. ": " .. tostring(err))
    return false
  end
  file:write(line)
  file:flush()
  file:close()
  return true
end

local function stateNumber(state, key)
  local value = state[key]
  if type(value) == "number" then return value end
  return 0
end

-- 내용 지문.  전체를 훑지 않고 성기게 뽑아 섞는다 -- 대사 하나가 수만 바이트라
-- 매 프레임 전수 순회는 비싸다.
--
-- **끝에서부터 잡는다.**  2026-08-20 실측: 같은 대사를 두 세션에서 잡으면 시작이
-- 몇 바이트 흔들리는데 끝은 고정이다.
--
--     15:01  read=006B  len=6795  write=6800
--     15:09  read=006D  len=6793  write=6800      같은 대사, 시작만 2 B 차이
--
-- 앞에서 잡으면 이 둘이 다른 지문이 되어 같은 대사가 파일 둘로 갈린다 (그렇게
-- 갈린 쌍이 실제로 3 개 나왔다).  뒤에서 잡으면 겹친다.
--
-- 한계 -- 8,192 B 보다 짧은 클립에는 꼬리 고정이 안 걸린다
-- ---------------------------------------------------------------------------
-- 아래 순회는 `first` 부터 앞으로 걸어간다.  클립이 8,192 보다 길면 first 가
-- 끝에서 8,191 자리라 뽑는 위치가 **끝에서부터** 세어져 길이가 몇 B 흔들려도
-- 같은 곳을 뽑는다.  짧으면 first 가 1 이 되어 **시작에서부터** 세어지므로
-- 시작이 2 B 밀리면 다른 지문이 나온다 (2026-08-24 실측 확인).
-- voice_events.tsv 644 행 중 89 행(13.8%)이 8,192 미만이다.
--
-- 그래도 안 고친다.  지문이 곧 파일 이름이고 그 이름이 표의 `clip_file` 열에
-- 644 행 적혀 있다.  섞는 법을 바꾸면 지금까지 모은 클립이 전부 "처음 보는 것"
-- 이 되어 같은 대사가 두 벌로 쌓인다.  고칠 거면 이름을 새로 매기는 작업과
-- 같이 해야 한다.
local FINGERPRINT_TAIL = 8192

local function voiceFingerprint(bytes)
  local first = math.max(1, #bytes - FINGERPRINT_TAIL + 1)
  local h = 2166136261
  local step = math.max(1, math.floor((#bytes - first + 1) / 512))
  for i = first, #bytes, step do
    h = (h ~ bytes:byte(i)) * 16777619 % 4294967296
  end
  return h
end

-- 재생 시작 순간의 ADPCM RAM 을 파일로 떠내고 그 이름을 돌려준다.
--
-- 이름을 **내용 지문**으로 짓는 이유: `sequence` 는 세션 안에서만 유효한 번호라
-- 세션마다 1 부터 다시 세고, 실제로 서로 다른 대사가 같은 번호를 받았다
-- (2026-08-20: 173 개 중 23 개 겹침).  지문은 세션을 넘어 같으므로 같은 대사를
-- 몇 번을 들어도 파일 하나로 모인다.
--
-- 0.2.3 의 중복 방지는 두 겹이다.
--   1  voiceClipSeen[지문]      이번 주행에서 이미 뜬 것.  파일을 열지도 않는다
--   2  이미 있는 파일인지 확인   지난 주행에서 뜬 것.  같은 내용을 다시 안 쓴다
-- 2 번이 있어야 세션을 넘어서도 안 겹친다.  폴더 목록을 읽는 방법은 안 쓴다 --
-- Mesen 의 Lua 에는 디렉터리 훑기가 없다.  "열어 보고 있으면 있다" 로 충분하다.
--
-- 지문을 내려면 RAM 을 어차피 다 읽어야 하므로 중복이어도 읽기는 든다.  아끼는
-- 것은 디스크 쓰기다 (한 클립이 수만 바이트다).
--
-- 클립마다 열고 닫는다.  수집기가 표를 그렇게 다루는 것과 같은 이유다 --
-- 중간에 그냥 꺼도 이미 떠낸 것은 디스크에 온전히 남는다.
--
-- 두 번째 반환값은 이 클립이 새것이었는지다.  로그와 화면에만 쓴다 -- 표에는
-- 열을 안 늘린다 (위 ensureVoiceHeader 참고).
local function dumpVoiceClip(readAddress, length)
  if adpcmMem == nil or length <= 0 then
    voiceClipFail = voiceClipFail + 1
    return "", false
  end
  local buffer, chunk = {}, {}
  for index = 0, length - 1 do
    chunk[#chunk + 1] = string.char(
      emu.read((readAddress + index) % ADPCM_RAM_SIZE, adpcmMem) or 0)
    if #chunk >= 4096 then buffer[#buffer + 1] = table.concat(chunk); chunk = {} end
  end
  if #chunk > 0 then buffer[#buffer + 1] = table.concat(chunk) end
  local data = table.concat(buffer)

  -- 이름에 길이를 넣지 않는다.  길이는 같은 대사라도 몇 바이트씩 흔들려서
  -- (6795 vs 6793) 이름에 넣으면 지문이 겹쳐도 파일이 갈린다.  길이는 표에 있다.
  local fingerprint = voiceFingerprint(data)
  local name = string.format("v%08X.bin", fingerprint)

  if voiceClipSeen[fingerprint] then
    voiceClipDup = voiceClipDup + 1
    return name, false
  end

  local existing = io.open(voiceDumpDir .. name, "rb")
  if existing ~= nil then
    existing:close()
    voiceClipSeen[fingerprint] = true
    voiceClipDup = voiceClipDup + 1
    return name, false
  end

  local file = io.open(voiceDumpDir .. name, "wb")
  if file == nil then
    voiceDumpFailed = voiceDumpFailed + 1
    voiceClipFail = voiceClipFail + 1
    if voiceDumpFailed == 1 then
      emu.log("★★★ 음성 덤프 폴더가 없다.  만들 것: " .. voiceDumpDir)
    end
    return "", false
  end
  file:write(data)
  file:close()
  voiceClipSeen[fingerprint] = true
  voiceClipNew = voiceClipNew + 1
  return name, true
end

local function ensureVoiceHeader()
  local existing = io.open(voiceOutputPath, "rb")
  local needsHeader = existing == nil
  if existing ~= nil then
    needsHeader = (existing:seek("end") or 0) == 0
    existing:close()
  end
  -- 이 판은 열 둘(clip_file · buffer_delta)을 뒤에 붙인다 -- snatcher_tool\mesen
  -- 쪽 0.2.2 와 **똑같은 12 칸**이다.  살아 있는 표가 이미 그 12 칸이므로 여기서
  -- 열을 더 늘리면 안 된다 (새것/중복은 화면과 로그에 있다).
  -- 이 파일은 세션을 넘어 이어붙이므로 lua\ 쪽 0.2.2 가 만든 파일에는 10 칸짜리
  -- 옛 헤더가 남아 있다.  그러면 헤더 10 칸 위로 12 칸짜리 행이 쌓여 읽는 쪽이
  -- 어긋난다.  조용히 두면 나중에 표만 보고는 알 수 없으므로 여기서 크게 알린다.
  if not needsHeader then
    local check = io.open(voiceOutputPath, "rb")
    if check ~= nil then
      local first = check:read("l") or ""
      check:close()
      if not string.find(first, "clip_file", 1, true) then
        emu.log("★★★ voice_events_raw.tsv 헤더가 옛 것이다 (clip_file 열 없음).")
        emu.log("     새 행은 열 12 개로 쌓이는데 헤더는 10 개다 -- 읽는 쪽이 어긋난다.")
        emu.log("     기존 파일을 옮기고 새로 시작할 것: " .. voiceOutputPath)
      end
    end
    return true
  end
  local file, err = io.open(voiceOutputPath, "ab")
  if file == nil then
    emu.log("VOICE ERROR opening " .. voiceOutputPath .. ": " .. tostring(err))
    return false
  end
  file:write("event_type\tevent_id\tsequence\tframe\taudio_type\tread_address\twrite_address\taudio_length\tplayback_rate\tsector\tclip_file\tbuffer_delta\n")
  file:flush()
  file:close()
  return true
end

local function ensureUiHeader()
  local existing = io.open(uiOutputPath, "rb")
  local needsHeader = existing == nil
  if existing ~= nil then
    needsHeader = (existing:seek("end") or 0) == 0
    existing:close()
  end
  if not needsHeader then return true end
  local file, err = io.open(uiOutputPath, "ab")
  if file == nil then
    emu.log("UI ERROR opening " .. uiOutputPath .. ": " .. tostring(err))
    return false
  end
  file:write("order\tframe\tbuffer_pointer\theader_hex\traw_hex\tbytes_including_ff\n")
  file:flush()
  file:close()
  return true
end

local function appendUiLine(line)
  if not ensureUiHeader() then return false end
  local file, err = io.open(uiOutputPath, "ab")
  if file == nil then
    emu.log("UI ERROR appending " .. uiOutputPath .. ": " .. tostring(err))
    return false
  end
  file:write(line)
  file:flush()
  file:close()
  return true
end

local function uiHeaderHex()
  local values = {}
  for index = 0, 8 do values[#values + 1] = byte(0x3610 + index) end
  return toHex(values)
end

local function appendVoiceEvent(kind, item, state)
  local file, err = io.open(voiceOutputPath, "ab")
  if file == nil then
    emu.log("VOICE ERROR appending " .. voiceOutputPath .. ": " .. tostring(err))
    return false
  end
  file:write(string.format(
    "%s\t%s\t%d\t%d\tADPCM\t%04X\t%04X\t%04X\t%02X\t%06X\t%s\t%d\n",
    kind, item.id, item.sequence, stateNumber(state, "frameCount"),
    item.readAddress, item.writeAddress, item.length, item.rate,
    stateNumber(state, "cdrom.scsi.sector"),
    item.clipFile or "", item.bufferDelta or 0
  ))
  file:flush()
  file:close()
  return true
end

-- CD-DA 를 같은 파일·같은 스키마로 흘린다.  `audio_type` 열이 원래부터 있었고
-- Studio 의 음성 탭은 그 값을 그대로 통과시키므로 스튜디오는 손댈 필요가 없다.
--
-- 지문은 `audio_type_read_length_rate` 로 만들어진다.  CD-DA 에는 ADPCM 의
-- 주소·길이·레이트가 없으므로 넷을 다 0 으로 두면 모든 CD-DA 가 한 지문으로
-- 뭉쳐 하나의 행으로 합쳐진다.  그래서 시작 섹터를 주소 칸에 나눠 넣어
-- 재생 구간마다 다른 지문이 나오게 한다 (오프닝 본편 184018 과 seek 잡음이
-- 구분돼야 한다).
local function appendCdAudioEvent(kind, item, frame, endSector)
  local file, err = io.open(voiceOutputPath, "ab")
  if file == nil then
    emu.log("CDDA ERROR appending " .. voiceOutputPath .. ": " .. tostring(err))
    return false
  end
  -- %X 는 소수부가 있는 수를 받으면 죽는다.  getState 가 돌려주는 값이 실수로
  -- 올 수 있으므로 찍기 직전에 정수로 내린다.
  local startSector = math.floor(item.startSector)
  local finalSector = math.floor(endSector or item.lastSector or item.startSector)
  file:write(string.format(
    -- CD-DA 에는 뜰 클립이 없다.  그래도 열 수는 ADPCM 과 같게 맞춘다 --
    -- 0.2.2 는 헤더보다 두 칸 짧은 행을 쌓았고 읽는 쪽이 어긋났다.
    "%s\t%s\t%d\t%d\tCDDA\t%04X\t%04X\t%04X\t%02X\t%06X\t\t0\n",
    kind, item.id, item.sequence, frame,
    startSector % 0x10000, math.floor(startSector / 0x10000), 0, 0,
    finalSector
  ))
  file:flush()
  file:close()
  return true
end

local function auditCdAudioAtFrame(state)
  local frame = stateNumber(state, "frameCount")
  local sector = state["cdrom.audioPlayer.currentSector"]

  local function finish()
    if cddaActive == nil then return end
    appendCdAudioEvent("END", cddaActive, frame, cddaActive.lastSector)
    emu.log(string.format("CDDA END[%d] id=%s frame=%d sector=%d duration=%.3fs",
      cddaActive.sequence, cddaActive.id, frame, cddaActive.lastSector,
      (frame - cddaActive.startFrame) / 60.0))
    cddaActive = nil
    cddaLastAdvanceFrame = nil
  end

  if type(sector) ~= "number" then
    cddaPreviousSector = nil
    if cddaActive ~= nil and cddaLastAdvanceFrame ~= nil
        and frame - cddaLastAdvanceFrame >= CDDA_STOP_GRACE_FRAMES then finish() end
    return
  end

  if cddaPreviousSector == nil then cddaPreviousSector = sector; return end

  if sector ~= cddaPreviousSector then
    if cddaActive == nil then
      -- ADPCM 과 같은 카운터를 쓴다.  한 파일 안에서 event_id 가 겹치면
      -- Studio 가 두 소리를 한 행으로 본다.
      voiceSequence = voiceSequence + 1
      cddaActive = {
        id = string.format("%s_%04d", voiceSession, voiceSequence),
        sequence = voiceSequence,
        startFrame = frame,
        startSector = sector,
        lastSector = sector,
      }
      cddaLastAdvanceFrame = frame
      appendCdAudioEvent("START", cddaActive, frame, sector)
      emu.log(string.format("CDDA START[%d] id=%s frame=%d sector=%d",
        cddaActive.sequence, cddaActive.id, frame, sector))
    else
      cddaActive.lastSector = sector
      cddaLastAdvanceFrame = frame
    end
  elseif cddaActive ~= nil and cddaLastAdvanceFrame ~= nil
      and frame - cddaLastAdvanceFrame >= CDDA_STOP_GRACE_FRAMES then
    finish()
  end

  cddaPreviousSector = sector
end

local function auditVoiceAtFrame()
  local state = emu.getState()
  local playing = state["cdrom.adpcm.playing"] == true

  if playing and not voiceWasPlaying then
    voiceSequence = voiceSequence + 1
    activeVoice = {
      id = string.format("%s_%04d", voiceSession, voiceSequence),
      sequence = voiceSequence,
      frame = stateNumber(state, "frameCount"),
      readAddress = stateNumber(state, "cdrom.adpcm.readAddress"),
      writeAddress = stateNumber(state, "cdrom.adpcm.writeAddress"),
      length = stateNumber(state, "cdrom.adpcm.adpcmLength"),
      rate = stateNumber(state, "cdrom.adpcm.playbackRate"),
    }
    -- 0.2.3: 소리를 여기서 뜬다.  판정 로직(playing and not voiceWasPlaying)은
    -- 건드리지 않는다 -- 인계서 §9 가 손대지 말라고 한 자리가 그것이다.
    -- 이 블록은 이미 결정된 START 에 파일 하나를 덧붙일 뿐이다.
    -- (write - read) - length.  0 이면 딱 맞고, 2048(CD 섹터)의 배수면 로더가
    -- 미리 읽어 둔 것이라 정상이다.  둘 다 아니면 들여다볼 값이다.
    activeVoice.bufferDelta =
      ((activeVoice.writeAddress - activeVoice.readAddress) % ADPCM_RAM_SIZE)
        - activeVoice.length
    activeVoice.clipFile, activeVoice.clipNew =
      dumpVoiceClip(activeVoice.readAddress, activeVoice.length)
    appendVoiceEvent("START", activeVoice, state)
    emu.log(string.format(
      "VOICE START[%d] id=%s frame=%d read=%04X write=%04X len=%04X rate=%02X  %s %s  [음성 %d개 · 중복 %d]%s",
      activeVoice.sequence, activeVoice.id, activeVoice.frame,
      activeVoice.readAddress, activeVoice.writeAddress,
      activeVoice.length, activeVoice.rate,
      activeVoice.clipFile ~= "" and activeVoice.clipFile or "(못 뜸)",
      activeVoice.clipNew and "새것" or "이미 있음",
      voiceClipNew, voiceClipDup,
      (activeVoice.bufferDelta % 2048 == 0) and ""
        or string.format("  ★버퍼차 %d (섹터 배수가 아니다)", activeVoice.bufferDelta)
    ))
  elseif not playing and voiceWasPlaying and activeVoice ~= nil then
    appendVoiceEvent("END", activeVoice, state)
    local endFrame = stateNumber(state, "frameCount")
    emu.log(string.format(
      "VOICE END[%d] id=%s frame=%d duration=%.3fs",
      activeVoice.sequence, activeVoice.id, endFrame,
      (endFrame - activeVoice.frame) / 60.0
    ))
    activeVoice = nil
  end

  voiceWasPlaying = playing

  -- ADPCM 판정은 위에서 끝났다.  CD-DA 는 그 뒤에 덧붙일 뿐 위 로직을 건드리지
  -- 않는다 (인계서 §9: 일반 음성 수집은 정상 작동 중이므로 손대지 말 것).
  -- getState 를 한 번만 부르려고 여기서 같은 state 를 넘긴다.
  auditCdAudioAtFrame(state)
end

-- $6FFD: `LDA $3671 / STA $E0` -- the next command record's text pointer is
-- about to be installed.  The exec callback fires before the LDA, so $3671/
-- $3672 still hold this record's pointer.  PROBE 0.6.7: 130 records, every one
-- of them opening with its speaker (130/130, no exception).
local function onRecordStart()
  recordSeq = recordSeq + 1
  recordLine = 0
  recordPtr = word(0x3671)
end

-- 0.2.1: where the renderer pointer may sit when this hook fires.
--
--   $3619 / $349A   the pointer has already advanced past the 9-byte control
--                   prefix.  0.2.0 only knew these, and the buffer is usually
--                   already 0xFF here -- 3 of 187 (text) and 3 of 366 (UI).
--   $3610 / $3490   the buffer base.  The prefix occupies +0..+8 and the text
--                   begins at +9, which is exactly $3619 / $3499.  This is
--                   where the string actually lives, and it is what the
--                   document viewer (Gaudi dictionary) uses.
--
-- Reading text at base+9 keeps source_hex byte-identical to what 0.2.0 wrote,
-- so runtime_static_index matching is unaffected.
-- 0.2.1a (2026-08-18): capture at the text address only.
--
-- 0.2.1 also captured at the buffer base ($3610/$3490) after PROBE 0.6.8 seemed
-- to show the text address was usually empty.  It was not: the probe logged
-- every pointer position mid-render, including the moments the buffer is
-- transiently empty, which this hook already skips (`#source == 0`).  Measured
-- side by side, base capture found nothing extra -- 35 unique strings either
-- way -- and put every line in the log twice.  The duplicates reached the
-- master as doubled lines (174 of them, 2026-08-18) before being merged out.
--
-- What the base is still good for is the 9-byte control prefix that sits there.
-- Read it as text - 9 instead of capturing there.
local HEADER_OFFSET = 9

local function beforePreloader(address, value)
  local rendererPointer = word(0x3471)
  if rendererPointer ~= 0x3619 and rendererPointer ~= 0x349A then return end

  local isUi = rendererPointer == 0x349A
  local pointer = isUi and uiBufferStart or rendererPointer
  -- FE xx tells the window apart (FE 01 dialogue, FE 06 the Gaudi dictionary)
  -- and FB xx yy carries the screen row, which resets to 00 at each paragraph.
  local header = {}
  for index = 0, HEADER_OFFSET - 1 do
    header[#header + 1] = byte(pointer - HEADER_OFFSET + index)
  end
  local headerHex = toHex(header)

  local source = readString(pointer)
  if #source == 0 then return end
  -- A custom lead means this buffer has already been replaced and is being
  -- revisited by the renderer.  It is not a new Japanese source occurrence.
  if source[1] >= 0xF0 and source[1] <= 0xF7 then return end

  -- A table constructor takes `Name = exp` fields, not a multiple assignment:
  -- written inline, `afterControl, controlOrigin, controlHex = f()` stored the
  -- two globals (nil) as array entries and gave controlHex the control NAME,
  -- leaving after_control empty in every row.  Resolve first, then build.
  local afterControl, controlOrigin, controlHex = resolveAfterControl(source, currentFrame())
  local pack, sector = captureContext()

  -- Stamp the record here, not in afterPreloader: the row is written at $66E8
  -- and the next record can start in between, which would file this capture
  -- under the following paragraph.  UI captures keep line 0 -- the blue menu
  -- buffer is not part of a dialogue record.
  local isText = not isUi
  if isText then recordLine = recordLine + 1 end

  pending = {
    recordSeq = recordSeq,
    recordLine = isText and recordLine or 0,
    recordPtr = recordPtr,
    frame = currentFrame(),
    pointer = pointer,
    rendererPointer = rendererPointer,
    state = word(0x7FEC),
    source = source,
    sourceHex = toHex(source),
    channel = isUi and "UI_PRELOADER" or "TEXT",
    captureAt = rendererPointer,
    headerHex = headerHex,
    afterControl = afterControl,
    controlOrigin = controlOrigin,
    controlHex = controlHex,
    pack = pack,
    sector = sector,
  }
end

local function afterPreloader(address, value)
  if pending == nil then return end

  -- SRT4 normally preserves the Japanese source buffer and redirects the
  -- renderer pointer to translated text in the CD cache.  Therefore success
  -- must be detected from the live pointer, not by rereading $3619.
  local afterPointer = word(0x3471)
  -- 0.2.1: the pointer may now land on a base as well; resolve it the same way
  -- the capture did, or the change test compares text against a control prefix.
  local afterSourcePointer = afterPointer == 0x349A and uiBufferStart or afterPointer
  local after = readString(afterSourcePointer)
  local afterHex = toHex(after)
  local changed = (afterPointer ~= pending.rendererPointer or pending.sourceHex ~= afterHex) and "yes" or "no"
  local staticRefs, staticScene = staticLocation(pending.sourceHex, pending.afterControl)
  sequence = sequence + 1
  appendLine(string.format(
    "%d\t%d\t%04X\t%04X\t%04X\t%04X\t%02X\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%d\t%s\t%s\t%s\t%d\t%d\t%d\t%04X\t%04X\t%s\n",
    sequence,
    pending.frame,
    pending.pointer,
    afterPointer,
    pending.state,
    word(0x7FEC),
    byte(0x7FEE),
    changed,
    pending.sourceHex,
    afterHex,
    pending.channel,
    pending.afterControl,
    pending.controlOrigin,
    pending.controlHex,
    sourceCells(pending.source),
    staticRefs,
    staticScene,
    pending.pack or "??",
    pending.sector or -1,
    pending.recordSeq or 0,
    pending.recordLine or 0,
    pending.recordPtr or 0,
    pending.captureAt or 0,
    pending.headerHex or ""
  ))
  if changed == "no" then
    emu.log(string.format(
      "RTA UNCHANGED[%d] state=%04X after=%s/%s source=%s",
      sequence,
      pending.state,
      pending.afterControl,
      pending.controlOrigin,
      pending.sourceHex
    ))
  end
  pending = nil
end

-- The blue action/menu UI reuses one scratch buffer for every item.  Capture it
-- only when the renderer is about to consume the completed item.  Watching
-- buffer writes records transient prefixes that disappear as soon as the next
-- menu item overwrites the same buffer.
local function onUiRendererRead(address, value)
  local rendererPointer = word(0x3471)
  if rendererPointer ~= 0x3499 and rendererPointer ~= 0x349A then return end
  local source = readString(rendererPointer)
  if not isCompleteUiShiftJis(source) then return end

  local sourceHex = toHex(source)
  local frame = currentFrame()
  local headerHex = uiHeaderHex()
  local uiKey = string.format("%04X|%s|%s", rendererPointer, headerHex, sourceHex)
  if uiSeen[uiKey] then return end
  uiSeen[uiKey] = true
  uiCount = uiCount + 1
  local uiPack, uiSector = captureContext()

  -- Canonical UI collection for the Studio UI tab.
  appendUiLine(string.format(
    "%d\t%d\t%04X\t%s\t%s\t%d\n",
    uiCount, frame, rendererPointer, headerHex, sourceHex, #source + 1
  ))

  -- 0.2.0: this writer has its own format string, so the three appended columns
  -- have to be repeated here or every UI row comes out one field short and the
  -- file stops being rectangular (measured: DictReader hands back nil).
  --
  -- record_line stays 0 -- a menu item is not a line of a dialogue record.  But
  -- record_seq/record_ptr are stamped anyway: they place the UI string in the
  -- record stream, which is a finer location key than `pack` alone and is what
  -- the location-pack work needs to bind UI to a place.
  sequence = sequence + 1
  appendLine(string.format(
    "%d\t%d\t%04X\t%04X\t%04X\t%04X\t%02X\tno\t%s\t%s\tUI_BUFFER\tEND\tUI_BUFFER\t\t%d\t\t\t%s\t%d\t%d\t0\t%04X\t%04X\t%s\n",
    sequence,
    frame,
    rendererPointer,
    rendererPointer,
    word(0x7FEC),
    word(0x7FEC),
    byte(0x7FEE),
    sourceHex,
    sourceHex,
    sourceCells(source),
    uiPack,
    uiSector,
    recordSeq,
    recordPtr,
    rendererPointer,
    uiHeaderHex()
  ))
  emu.log(string.format("RTA UI[%d] ptr=%04X source=%s", sequence, rendererPointer, sourceHex))
end

-- Registered before beforePreloader so a record that starts and renders in the
-- same instant is stamped with the record it belongs to, not the previous one.
emu.addMemoryCallback(
  onRecordStart,
  emu.callbackType.exec,
  0x6FFD,
  0x6FFD,
  emu.cpuType.pce,
  mem
)
emu.addMemoryCallback(
  beforePreloader,
  emu.callbackType.exec,
  0x5E40,
  0x5E40,
  emu.cpuType.pce,
  mem
)
emu.addMemoryCallback(
  onDecoderHighWrite,
  emu.callbackType.write,
  0x360D,
  0x360D,
  emu.cpuType.pce,
  mem
)
emu.addMemoryCallback(
  onDecoderLowWrite,
  emu.callbackType.write,
  0x360E,
  0x360E,
  emu.cpuType.pce,
  mem
)
emu.addMemoryCallback(
  onUiRendererRead,
  emu.callbackType.exec,
  0x66E5,
  0x66E5,
  emu.cpuType.pce,
  mem
)
emu.addMemoryCallback(
  afterPreloader,
  emu.callbackType.exec,
  0x66E8,
  0x66E8,
  emu.cpuType.pce,
  mem
)

-- ---------------------------------------------------------------------------
-- 장소별 프레임 예산 (2026-08-15 추가)
--
-- 왜 여기 붙였나
--   폐공장의 그림 밀림은 우리 코드가 레코드마다 쓰는 약 11 스캔라인이 게임 쪽
--   여유를 넘을 때 난다.  그 비용은 어디서나 같다는 것이 실측됐고(본부 16,185 /
--   폐공장 15,132 masterClock, 오히려 본부가 비싸다), 다른 것은 게임이 그 장면에
--   프레임을 얼마나 쓰느냐뿐이다.
--
--   그러면 **번역이 안 된 구역도 미리** 위험한지 알 수 있다.  우리 코드가 안
--   돌아도 게임의 프레임 여유는 재지므로, 수집하러 전 구간을 도는 김에 "폐공장
--   보다 빡빡한 곳이 있는가" 가 같이 나온다.  따로 시간을 쓸 필요가 없어서
--   수집기에 얹었다.
--
-- 무엇을 재나
--   프레임 간격(masterClock 차).  게임이 프레임 안에 일을 못 끝내면 간격이
--   늘어난다.  MPR6 로 장소를 묶어 장소별 분포를 낸다.
--
-- 기존 수집에 영향이 없다
--   자기 파일에만 쓰고, 기존 함수·경로·콜백을 건드리지 않는다.  프레임당 하는
--   일은 getState 한 번과 뺄셈 하나다 -- captureContext 가 이미 매 캡처마다
--   부르는 그 호출과 같은 비용이다.
-- 0.2.2: 세션 도장을 찍는다.  고정 이름이면 다음 판이 지난 판의 측정을 덮는다.
local budgetPath = "C:\\snatcher\\dump\\frame_budget_" .. voiceSession .. ".tsv"
local budgetLast, budgetFrame = nil, 0
local budgetStats = {}          -- pack -> {n=, sum=, max=, over=}

local function budgetTick()
  budgetFrame = budgetFrame + 1
  local ok, state = pcall(emu.getState)
  if not ok or state == nil then return end
  local clock = state["masterClock"]
  if type(clock) ~= "number" then return end
  local delta = budgetLast and (clock - budgetLast) or nil
  budgetLast = clock
  if delta == nil or delta <= 0 then return end

  local pack = state["memoryManager.mpr[6]"]
  if pack == nil and type(state.memoryManager) == "table"
      and type(state.memoryManager.mpr) == "table" then
    pack = state.memoryManager.mpr[6]
  end
  pack = pack == nil and "??" or string.format("%02X", pack)

  local slot = budgetStats[pack]
  if slot == nil then
    slot = { n = 0, sum = 0, max = 0, over = 0, first = budgetFrame }
    budgetStats[pack] = slot
  end
  slot.n = slot.n + 1
  slot.sum = slot.sum + delta
  if delta > slot.max then slot.max = delta end
  -- 한 프레임을 넘긴 것.  NTSC 한 프레임이 masterClock 약 357,366 이다
  -- (21.47727 MHz / 60.0988).  여유가 없는 장면일수록 이 비율이 높다.
  if delta > 380000 then slot.over = slot.over + 1 end
end

local function budgetReport()
  local file = io.open(budgetPath, "w")
  if file == nil then return end
  file:write("pack\tframes\tavg_clock\tmax_clock\tover_frames\tover_pct\tfirst_frame\n")
  for pack, s in pairs(budgetStats) do
    file:write(string.format("%s\t%d\t%.0f\t%d\t%d\t%.2f\t%d\n",
      pack, s.n, s.sum / s.n, s.max, s.over, 100 * s.over / s.n, s.first))
  end
  file:close()
  emu.log("FRAME BUDGET -> " .. budgetPath)
  for pack, s in pairs(budgetStats) do
    emu.log(string.format("  pack %s  프레임 %d  넘김 %d (%.2f%%)  최대 %d",
      pack, s.n, s.over, 100 * s.over / s.n, s.max))
  end
end

ensureVoiceHeader()
ensureUiHeader()
emu.addEventCallback(auditVoiceAtFrame, emu.eventType.endFrame)
emu.addEventCallback(budgetTick, emu.eventType.endFrame)
emu.addEventCallback(budgetReport, emu.eventType.scriptEnded)

-- 화면 왼쪽 위에 수집 개수를 찍는다.  로그를 안 봐도 지금 몇 개 떴는지 보인다.
-- 표시는 세 칸이다:  음성 N개 = 이번 주행에서 새로 뜬 것 · 중복 = 같은 음성이
-- 또 나와 안 뜬 것 · ★못뜸 = 폴더가 없거나 길이가 0 이라 못 뜬 것.
-- ADPCM 메모리 타입이 없으면 소리가 한 개도 안 뜨므로 그것부터 크게 알린다.
emu.addEventCallback(function()
  if adpcmMem == nil then
    emu.drawString(4, 4, "★ ADPCM 메모리 타입이 없다 -- 소리가 안 떠진다",
      0xFF6060, 0x80000000, 1)
    return
  end
  emu.drawString(4, 4, string.format("음성 %d개 · 중복 %d", voiceClipNew, voiceClipDup),
    0xFFFFFF, 0x80000000, 1)
  if voiceClipFail > 0 then
    emu.drawString(4, 14, string.format("★못뜸 %d -- 덤프 폴더 확인", voiceClipFail),
      0xFF6060, 0x80000000, 1)
  end
end, emu.eventType.endFrame)

emu.log("runtime_text_audit 0.2.3 loaded - text + voice(ADPCM+CDDA, 클립 덤프 포함) + UI collection enabled; power-cycle and play")
emu.log("  0.2.3: 음성 클립 덤프를 되살렸다 (0.2.2 lua\\ 판에는 없었다) -> " .. voiceDumpDir)
emu.log("         같은 음성은 다시 안 뜬다 (내용 지문 · 세션을 넘어서도).  개수는 화면 왼쪽 위")
if adpcmMem == nil then
  emu.log("  ★ ADPCM 메모리 타입이 없다.  소리는 안 떠지고 표만 쌓인다")
end
emu.log("  0.2.1a: header_hex 열 -- FE xx 로 창 종류(01 대사 / 06 사전), FB xx yy 로 화면 행")
emu.log("RTA output: " .. outputPath)
emu.log("VOICE output: " .. voiceOutputPath)
emu.log("  ADPCM = 일반 대사,  CDDA = 오프닝 나레이션 계열 (같은 파일, audio_type 으로 구분)")
emu.log("UI output: " .. uiOutputPath)
emu.log("FRAME BUDGET output: " .. budgetPath .. "  (Stop 해야 남는다)")
emu.log("  장소별 프레임 여유.  넘김 비율이 폐공장보다 높은 구역이 있으면 거기가 더 위험하다")

-- ===========================================================================
-- 0.2.2 (2026-08-21) -- 엔딩까지 한 판에 세 가지를 같이 잰다
-- ===========================================================================
--
-- 0.2.1 까지가 하던 일(텍스트·음성·UI·프레임예산)은 한 줄도 안 건드렸다.  아래는
-- 전부 덧붙이기이고, 각자 자기 파일에만 쓴다.  같은 플레이에 얹으면 되고 ROM 을
-- 새로 구울 필요가 없다 (인계서 2026-08-21 저녁 §6).
--
-- 1) 글리프 사용 관측  -- 오늘의 본진
--
--    배정표가 "게임이 쓴다" 고 보는 1,906 자 중 **런타임 관측은 1 자뿐**이고
--    나머지는 코퍼스 추정이다.  추정에는 화면에 실제로 안 나오는 한자가 섞여
--    있어서 자리를 잡아먹고, 그래서 지금 빈 칸이 4 개밖에 안 남았다 (31 자 부족).
--
--    EX_GETFNT 본체 $F124 에 실제로 들어간 SJIS 코드만 세면 추정을 걷어낼 수 있다.
--    진입 시점의 $20F9/$20F8 이 아직 원본 SJIS 다 ($F1E3 이 덮기 전) --
--    PROBE_FONT_ADDR 0.1.6 이 한자 표본 5/5 로 확인한 지점이다.
--
--    출력이 두 개다.
--      glyph_used_<세션>.tsv     코드별 횟수·첫 프레임.  읽고 판단하는 용도
--      observed_used_<세션>.txt  build/bios_font/observed_used.tsv 에 그대로
--                                이어붙일 수 있는 형식
--
-- 2) 레코드 목격 횟수 (seen)
--
--    마스터의 `seen` 열이 전부 0 이라 텍스트 수집에는 계기판이 없다.  음성은
--    표지재포획으로 커버리지 72% 가 나오는데 텍스트는 어디를 다 긁었는지 모른다.
--
--    $6FFD 는 이미 레코드 시작으로 관측된 지점이고 $3671 이 그 레코드의 포인터다.
--    그 포인터가 곧 마스터의 `source_refs` 다 (R00001 -> 250A).  그래서 여기서
--    센 숫자는 마스터 행에 그대로 얹힌다.
--
-- 3) 음성 구간 VDC/SATB 관측  -- 자막 A/B 를 가른다
--
--    A(매 프레임 IRQ 합성) 와 B(클립당 1 회 렌더) 중 아직 못 골랐고, 가르는
--    측정이 0 행이다.  기존 probe 는 실험 BIOS 를 물고 $5B80 엔진이 VDC 를 쓸
--    때만 행을 남기게 돼 있어서, 보통 부팅으로는 아무것도 안 나온다.
--
--    여기서는 **수동 관측**만 한다.  음성이 도는 동안 게임이
--      $0000-$0003 에 몇 번 쓰는가 · MAWR 이 어느 대역인가 · SATB($1000-$10FF)
--      를 다시 쓰는가 · SAT 을 몇 번까지 쓰는가
--    를 클립마다 한 줄로 남긴다.  실험 BIOS 도 AC 도 필요 없다.
--
--    읽는 법:  음성 구간에 SATB 재기록이 0 이고 SAT 최대 사용이 낮게 유지되면
--    B(클립당 1 회 렌더)로 충분하다.  매 클립 SATB 를 다시 쓰면 A 가 필요하다.
--
-- 안전장치
--   긴 판이라 크래시로 다 날리면 안 된다.  1 분(3,600 프레임)마다 세 파일을
--   통째로 다시 쓴다.  Stop 을 못 눌러도 직전 1 분까지는 남는다.

local sessionStamp = voiceSession
local glyphPath    = "C:\\snatcher\\dump\\glyph_used_" .. sessionStamp .. ".tsv"
local observedPath = "C:\\snatcher\\dump\\observed_used_" .. sessionStamp .. ".txt"
local seenPath     = "C:\\snatcher\\dump\\record_seen_" .. sessionStamp .. ".tsv"
local vdcPath      = "C:\\snatcher\\dump\\voice_vdc_" .. sessionStamp .. ".tsv"

local ZP = 0x2000
local GETFNT_BODY   = 0xF124      -- EX_GETFNT 본체.  $E060 이 여기로 점프한다
local GETFNT_VECTOR = 0xE060      -- 대조용.  둘이 어긋나면 BIOS 가 다른 것이다
local VRAM = emu.memType.pceVideoRam
local cpuMem = emu.memType.cpu
local SATB_WORD = 0x1000          -- 자막 인계서 실측: SATB 는 $1000-$10FF

local v022Frame = 0

-- --------------------------------------------------------------- 1) 글리프
local glyphTally, glyphKinds, glyphCalls, vectorCalls = {}, 0, 0, 0

emu.addMemoryCallback(function()
  glyphCalls = glyphCalls + 1
  local code = byte(ZP + 0xF9) * 256 + byte(ZP + 0xF8)
  local slot = glyphTally[code]
  if slot == nil then
    glyphTally[code] = { n = 1, first = v022Frame }
    glyphKinds = glyphKinds + 1
  else
    slot.n = slot.n + 1
  end
end, emu.callbackType.exec, GETFNT_BODY, GETFNT_BODY, emu.cpuType.pce, mem)

emu.addMemoryCallback(function()
  vectorCalls = vectorCalls + 1
end, emu.callbackType.exec, GETFNT_VECTOR, GETFNT_VECTOR, emu.cpuType.pce, mem)

-- ------------------------------------------------------------------ 2) seen
local recordSeen, recordKinds = {}, 0

emu.addMemoryCallback(function()
  local ptr = word(0x3671)
  local slot = recordSeen[ptr]
  if slot == nil then
    recordSeen[ptr] = { n = 1, first = v022Frame }
    recordKinds = recordKinds + 1
  else
    slot.n = slot.n + 1
  end
end, emu.callbackType.exec, 0x6FFD, 0x6FFD, emu.cpuType.pce, mem)

-- ------------------------------------------------------------- 3) VDC/SATB
local vdcReg, vdcLatchLo = 0, 0
local voiceVdc = nil            -- 지금 도는 클립의 누적치
local voiceVdcRows = {}
local vdcPrevVoiceId = nil

local function newVoiceVdc(id, frame)
  return { id = id, startFrame = frame, writes = 0, mawrSets = 0, vwr = 0,
           satbMawr = 0, satbData = 0, mawr = 0, bands = {},
           satStart = -1, satEnd = -1, frames = 0 }
end

-- SATB 를 훑어 실제로 쓰이는 스프라이트 최대 번호를 본다.  엔트리 하나가 4 워드,
-- 첫 워드가 Y 다.  Y=0 이면 안 쓰는 자리로 본다 (인계서의 "0-16 사용" 과 같은 척도).
local function satMaxUsed()
  local maxUsed = -1
  for i = 0, 63 do
    local w = (SATB_WORD + i * 4) * 2
    local y = (emu.read(w, VRAM) or 0) + (emu.read(w + 1, VRAM) or 0) * 256
    if y ~= 0 then maxUsed = i end
  end
  return maxUsed
end

emu.addMemoryCallback(function(address, value)
  -- 음성이 안 돌면 아무 것도 안 한다.  VDC 쓰기는 프레임마다 수백 번이라 엔딩까지
  -- 도는 판에서 통째로 세면 그 자체가 프레임 예산을 먹는다.  레지스터 선택값도
  -- 여기서만 따라가는데, MAWR 은 쓰기 직전에 매번 다시 잡히므로 클립 시작 직후
  -- 몇 번을 놓쳐도 곧 제 값이 된다.
  local acc = voiceVdc
  if acc == nil then return end
  if address == 0x0000 then
    vdcReg = value % 32
    return
  end
  acc.writes = acc.writes + 1
  if address == 0x0002 then
    vdcLatchLo = value
    return
  end
  if address ~= 0x0003 then return end   -- $0001 은 미사용
  if vdcReg == 0x00 then                 -- MAWR: VRAM 쓰기 주소 설정
    local addr = value * 256 + vdcLatchLo
    acc.mawr = addr
    acc.mawrSets = acc.mawrSets + 1
    local band = math.floor(addr / 256)
    acc.bands[band] = (acc.bands[band] or 0) + 1
    if addr >= 0x1000 and addr <= 0x10FF then acc.satbMawr = acc.satbMawr + 1 end
  elseif vdcReg == 0x02 then             -- VWR: 실제 데이터.  주소는 자동증가
    acc.vwr = acc.vwr + 1
    if acc.mawr >= 0x1000 and acc.mawr <= 0x10FF then
      acc.satbData = acc.satbData + 1
    end
    acc.mawr = (acc.mawr + 1) % 0x10000
  end
end, emu.callbackType.write, 0x0000, 0x0003, emu.cpuType.pce, cpuMem)

-- ------------------------------------------------------------------ 출력
local function topBands(bands)
  local list = {}
  for band, n in pairs(bands) do list[#list + 1] = { band = band, n = n } end
  table.sort(list, function(a, b) return a.n > b.n end)
  local out = {}
  for i = 1, math.min(6, #list) do
    out[#out + 1] = string.format("%02X:%d", list[i].band, list[i].n)
  end
  return table.concat(out, ",")
end

local function flushAll()
  local file = io.open(glyphPath, "w")
  if file ~= nil then
    file:write("sjis\tcount\tfirst_frame\n")
    for code, s in pairs(glyphTally) do
      file:write(string.format("%02X %02X\t%d\t%d\n",
        math.floor(code / 256), code % 256, s.n, s.first))
    end
    file:close()
  end

  file = io.open(observedPath, "w")
  if file ~= nil then
    file:write("# runtime_text_audit 0.2.2 관측 -- EX_GETFNT($F124) 에 실제로 들어간 SJIS\n")
    file:write("# 세션 " .. sessionStamp .. "\n")
    file:write("# build/bios_font/observed_used.tsv 에 그대로 이어붙일 수 있다\n")
    for code, s in pairs(glyphTally) do
      file:write(string.format("%02X%02X   # %d 회, 첫 프레임 %d\n",
        math.floor(code / 256), code % 256, s.n, s.first))
    end
    file:close()
  end

  file = io.open(seenPath, "w")
  if file ~= nil then
    file:write("record_ptr\tseen\tfirst_frame\n")
    for ptr, s in pairs(recordSeen) do
      file:write(string.format("%04X\t%d\t%d\n", ptr, s.n, s.first))
    end
    file:close()
  end

  file = io.open(vdcPath, "w")
  if file ~= nil then
    file:write("voice_id\tframes\tvdc_writes\tmawr_sets\tvwr_writes\t" ..
               "satb_mawr\tsatb_data\tsat_max_start\tsat_max_end\tmawr_bands\n")
    for _, r in ipairs(voiceVdcRows) do
      file:write(string.format("%s\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%s\n",
        r.id, r.frames, r.writes, r.mawrSets, r.vwr, r.satbMawr, r.satbData,
        r.satStart, r.satEnd, topBands(r.bands)))
    end
    file:close()
  end
end

-- endFrame.  auditVoiceAtFrame 이 먼저 등록돼 있으므로 여기서는 그것이 만든
-- activeVoice 의 전이만 본다 (START/END 판정을 두 번 하지 않는다).
emu.addEventCallback(function()
  v022Frame = v022Frame + 1

  local id = activeVoice ~= nil and activeVoice.id or nil
  if id ~= vdcPrevVoiceId then
    if voiceVdc ~= nil then
      voiceVdc.frames = v022Frame - voiceVdc.startFrame
      voiceVdc.satEnd = satMaxUsed()
      voiceVdcRows[#voiceVdcRows + 1] = voiceVdc
      voiceVdc = nil
    end
    if id ~= nil then
      voiceVdc = newVoiceVdc(id, v022Frame)
      voiceVdc.satStart = satMaxUsed()
    end
    vdcPrevVoiceId = id
  end

  if v022Frame % 3600 == 0 then flushAll() end
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  if voiceVdc ~= nil then
    voiceVdc.frames = v022Frame - voiceVdc.startFrame
    voiceVdc.satEnd = satMaxUsed()
    voiceVdcRows[#voiceVdcRows + 1] = voiceVdc
    voiceVdc = nil
  end
  flushAll()
  emu.log(string.format(
    "GLYPH  EX_GETFNT %d 회 · 고유 %d 자  (벡터 $E060 %d 회)",
    glyphCalls, glyphKinds, vectorCalls))
  if glyphCalls == 0 then
    emu.log("  ★ 0 회다.  $F124 가 이 BIOS 의 EX_GETFNT 본체가 아니다 -- 코드 확인 필요")
  end
  emu.log("  -> " .. glyphPath)
  emu.log("  -> " .. observedPath .. "  (observed_used.tsv 에 이어붙일 것)")
  emu.log(string.format("SEEN   레코드 고유 %d 개  -> %s", recordKinds, seenPath))
  emu.log(string.format("VDC    음성 클립 %d 개  -> %s", #voiceVdcRows, vdcPath))
  emu.log(string.format("VOICE  음성 %d개 떴다 · 중복 %d · 못뜸 %d  -> %s",
    voiceClipNew, voiceClipDup, voiceClipFail, voiceDumpDir))
  if voiceClipNew == 0 then
    emu.log("  ★ 한 개도 안 떴다.  폴더가 있는지 · 대사가 나오는 곳을 지났는지 볼 것")
  end
end, emu.eventType.scriptEnded)

emu.log("0.2.2: 글리프 관측 + 레코드 seen + 음성구간 VDC/SATB 를 같이 잰다 (1분마다 자동 저장)")
