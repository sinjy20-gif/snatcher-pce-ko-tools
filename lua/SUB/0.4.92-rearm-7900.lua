-- SUB 0.4.92 -- 글리프 base 를 $1600 에서 $7900 으로 옮긴 대조판.
--
-- 왜
-- ---------------------------------------------------------------------------
-- 0.4.91 실측으로 국장실 증상의 원인이 갈렸다.  **주소가 남의 자리였다.**
--
--     배경 그림 데이터는 $1100 에서 시작해 그림 크기만큼 위로 자란다
--     그림이 작은 장면   $1100-$110F · $1100-$330F   ->  겹침 0
--     그림이 큰 장면     $1100-$1A1F / $1F5F / $18CF ->  겹침 165 / 78 / 45 엔트리
--
-- $1600 은 그 성장 구간 한복판이다.  그래서 정커 본부에서는 멀쩡하고 국장실
-- 에서는 배경 타일 위에 글리프를 쓴다.  한 글자(0.4.87)도 VDC 재무장(0.4.89)도
-- 안 먹혔던 이유가 이것이다 -- 주소는 정확히 지정한 대로 쓰이고 있었다.
--
-- 이 판
-- ---------------------------------------------------------------------------
-- 0.4.89 체인 그대로에 엔진만 $7900 판으로 바꾼다.  VDC 재무장도 같이 들어
-- 있으므로, 이 실행에서 남는 증상은 base 문제도 래치 문제도 아닌 것이 된다.
--
--     python tools/build_subtitle_engine_vdc_rearm.py --pat-vram 0x7900
--     -> engine_ac_lua_frame_rearm_7900.bin  ·  글리프 $7900-$7DBF
--
-- $7900 은 예전 설계값이다.  **여기도 안전하다는 보장은 아직 없다.**
-- 스프라이트 패턴이 위쪽 VRAM 을 쓰므로, 0.4.91 을 같이 올려 겹침을 확인한다
-- (아래에서 프로브의 감시 대상도 $7900 으로 맞춰 둔다).
--
-- 판정
-- ---------------------------------------------------------------------------
--     국장실 증상이 사라지면   base 가 원인이었다.  남은 것은 "장면마다 안전한
--                              base 를 어떻게 정하는가" 하나로 좁혀진다
--     그대로면                 $7900 도 남의 자리다.  0.4.91 겹침 수를 볼 것
--     떨림만 남으면            예상대로다.  전송량 경로는 별개 작업이다
--
-- Power Cycle 뒤 이 파일 하나만 로드한다 (0.4.91 은 아래에서 같이 올린다).

SUB_REARM_INFO_PATH =
  'C:/snatcher/build/cutscene_subs/engine_ac_lua_frame_rearm_7900.lua'

-- 0.4.48 forceRenderer 는 631 B 기준 오프셋을 하드코딩한다.  재무장 엔진에서
-- 켜면 코드를 부순다 (0.4.89 와 같은 가드).
assert(rawget(_G, 'SUB_FRAGMENT_FORCE_KEY') == nil and
       rawget(_G, 'SUB_FRAGMENT_FORCE_BASE') == nil,
       '재무장 엔진에서는 SUB_FRAGMENT_FORCE_KEY/BASE 를 쓸 수 없다')

SUB_FRAGMENT_WIPE_VERSION = '0.4.92-rearm-7900'
SUB_FRAGMENT_WIPE_CHILD = 'C:/snatcher/lua/SUB/0.4.89-marker.lua'

dofile('C:/snatcher/lua/SUB/0.4.48-fragment-wipe.lua')

SUB_FRAGMENT_WIPE_VERSION = nil
SUB_FRAGMENT_WIPE_CHILD = nil
SUB_REARM_INFO_PATH = nil

-- 겹침 감시를 같은 base 로 맞춰서 올린다.  읽기 전용이다.
SUB_PROBE_PAT_VRAM = 0x7900
dofile('C:/snatcher/lua/SUB/0.4.91-bg-pattern-overlap.lua')
SUB_PROBE_PAT_VRAM = nil

emu.log('SUB 0.4.92-rearm-7900 armed -- 글리프 $7900-$7DBF · VDC 재무장 엔진 653 B')
emu.log('  로그의 engine 653 B · STAGE $5D8D · PATCHED base=$7900 을 확인할 것')
emu.log('  0.4.91 겹침 수가 0 이어야 이 base 가 안전한 것이다')
