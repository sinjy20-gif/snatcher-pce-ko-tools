using System.Diagnostics;
using System.Text.RegularExpressions;

namespace SnatcherTranslationStudio;

internal sealed class MainForm : Form
{
    private const string RuntimeMissUneditedMarker = "[RUNTIME_MISS_UNEDITED]";
    private readonly string root;
    private readonly string translationDir;
    private readonly string backupDir;
    private TsvDocument master = null!;
    private TsvDocument speakers = null!;
    private TsvDocument ui = null!;
    private TsvDocument voiceEvents = null!;
    private TsvDocument voiceSubtitles = null!;
    private TsvDocument voiceExcluded = null!;
    private HashSet<string> excludedVoiceFingerprints = new(StringComparer.Ordinal);

    private readonly TabControl mainTabs = new() { Dock = DockStyle.Fill };
    private readonly DataGridView masterGrid = NewGrid();
    private readonly SplitContainer masterSplit = new()
    {
        Dock = DockStyle.Fill,
        Orientation = Orientation.Vertical,
        SplitterWidth = 6,
    };
    private readonly TextBox searchBox = new() { Width = 280, PlaceholderText = "일본어·한국어·키 검색" };
    private readonly System.Windows.Forms.Timer masterSearchDebounce = new() { Interval = 280 };
    private readonly ComboBox sceneFilter = new() { Width = 115, DropDownStyle = ComboBoxStyle.DropDownList };
    private readonly ComboBox rowFilter = new() { Width = 145, DropDownStyle = ComboBoxStyle.DropDownList };
    private readonly Button sceneOrderButton = new() { AutoSize = true, Height = 28, Text = "장면 순서: 원본" };
    private readonly Label summaryLabel = new() { AutoSize = true, Padding = new Padding(8, 7, 0, 0) };
    private readonly Label identityLabel = new() { AutoSize = true, Font = new Font("맑은 고딕", 10, FontStyle.Bold) };
    private readonly TextBox jpBox = new() { Multiline = true, ReadOnly = true, Height = 72, Dock = DockStyle.Top, Font = new Font("맑은 고딕", 11), BackColor = Theme.SurfaceAlt };
    private readonly TextBox koBox = new() { Multiline = true, Height = 78, Dock = DockStyle.Top, Font = new Font("맑은 고딕", 12) };
    private readonly ComboBox controlBox = new() { Width = 85, DropDownStyle = ComboBoxStyle.DropDownList, Enabled = false };
    private readonly ComboBox chapterBox = new() { Width = 125, DropDownStyle = ComboBoxStyle.DropDownList };
    private readonly Label metricLabel = new() { AutoSize = true, Font = new Font("맑은 고딕", 10, FontStyle.Bold) };
    private readonly TextBox contextBox = new() { Multiline = true, ReadOnly = true, ScrollBars = ScrollBars.Vertical, Dock = DockStyle.Fill, Font = new Font("맑은 고딕", 10), BackColor = Theme.SurfaceAlt };
    private readonly ListBox duplicateList = new() { Dock = DockStyle.Fill, Font = new Font("맑은 고딕", 9) };
    private readonly TabPage cddaPage = new("CD-DA 자막");
    private TsvDocument cddaSegments = null!;   // 읽기 전용 원본 (트랙·구간·일본어)
    private TsvDocument cddaSubs = null!;       // 여기에 한국어를 쓴다
    private readonly DataGridView cddaGrid = NewEditableGrid();
    private readonly Label cddaSummary = new() { AutoSize = true, Padding = new Padding(8, 7, 0, 0) };
    // 일본어 원문은 그리드 칸에서 잘린다.  오른쪽에 큰 창으로 따로 보여준다.
    private readonly TextBox voiceJapanese = new() {
        Dock = DockStyle.Fill, Multiline = true, ReadOnly = true, WordWrap = true,
        ScrollBars = ScrollBars.Vertical, BorderStyle = BorderStyle.FixedSingle
    };
    // 자막 한 줄이 화면에 들어가는지 바로 보이게 한다.  Galmuri9 는 비례폭이라
    // 글자 수로는 못 재고 글자별 폭을 더해야 한다 (SubtitleWidthPx).
    private readonly Label voiceWidthLabel = new() { Dock = DockStyle.Top, Height = 22, Padding = new Padding(2, 3, 0, 0) };
    private readonly Label cddaWidthLabel = new() { Dock = DockStyle.Top, Height = 22, Padding = new Padding(2, 3, 0, 0) };
    private readonly TextBox cddaKoBox = new() {
        Dock = DockStyle.Fill, Multiline = true, WordWrap = true,
        ScrollBars = ScrollBars.Vertical, BorderStyle = BorderStyle.FixedSingle
    };
    private readonly Label cddaIdentityLabel = new() { Dock = DockStyle.Top, Height = 28, Padding = new Padding(2, 5, 0, 0) };
    private readonly CheckBox cddaFocusMode = new() {
        Text = "🔍 싱크 확대", AutoSize = true, Checked = false, Padding = new Padding(5, 5, 2, 0)
    };
    // ★ 기본은 꺼짐 (2026-09-07).  켜져 있으면 재생이 자막을 지날 때마다 목록의
    //   행이 바뀌고, 그 바람에 확대 창이 통째로 점프한다 -- 싱크를 맞추던 손에서
    //   화면이 빠져나간다.  지금은 재생 중인 자막을 **타임라인이 표시만** 한다
    //   (♪ 딱지 + 밑줄).  옛 동작이 필요하면 여기를 켠다.
    private readonly CheckBox cddaFollowPlayback = new() {
        Text = "따라가기", AutoSize = true, Checked = false, Padding = new Padding(5, 5, 2, 0)
    };
    private readonly Panel cddaFocusPanel = new() { Dock = DockStyle.Top, Height = 92, Visible = false };
    private readonly Label cddaFocusPrevious = new() { Dock = DockStyle.Fill, AutoEllipsis = true, Padding = new Padding(8, 3, 8, 1) };
    private readonly Label cddaFocusCurrent = new() {
        Dock = DockStyle.Fill, AutoEllipsis = true, Padding = new Padding(8, 3, 8, 1),
        Font = new Font("맑은 고딕", 13, FontStyle.Bold)
    };
    private readonly Label cddaFocusNext = new() { Dock = DockStyle.Fill, AutoEllipsis = true, Padding = new Padding(8, 3, 8, 1) };
    private double cddaFocusWindowSeconds = 12.0;
    private List<string>? currentCddaPartRow;
    // 확대 창을 마지막으로 맞춰 준 조각.  **고른 조각이 바뀔 때만** 창을 다시
    // 맞춘다 -- 그렇지 않으면 편집 한 번마다(RefreshCddaTimeline) 창이 되돌아가
    // 손으로 밀어 둔 자리를 잃는다.
    private List<string>? cddaFocusAnchorRow;
    // 타임라인의 블록을 눌러서 고른 것인가.  그 경우 창을 다시 맞추면 안 된다 --
    // SelectionChanged 가 MouseDown 중에 먼저 뜨므로, 여기서 창을 옮기면
    // 잡으려던 블록이 좌표계와 함께 커서 밑에서 도망간다.
    private bool selectingCddaFromTimeline;
    private readonly Label voiceJapaneseHead = new() { Dock = DockStyle.Top, Height = 24, Padding = new Padding(6, 5, 0, 0) };
    private readonly DataGridView cddaPartGrid = NewEditableGrid();
    private readonly TextBox cddaJapanese = new() {
        Dock = DockStyle.Fill, Multiline = true, ReadOnly = true, WordWrap = true,
        ScrollBars = ScrollBars.Vertical, BorderStyle = BorderStyle.FixedSingle
    };
    private readonly Label cddaJapaneseHead = new() { Dock = DockStyle.Top, Height = 24, Padding = new Padding(6, 5, 0, 0) };
    private readonly Label cddaPartSummary = new() { AutoSize = true, Padding = new Padding(8, 6, 0, 0) };
    // ★★ 2026-09-03: 기준을 **픽셀 하나**로 통일했다.
    //
    //   렌더러는 가운데 정렬이다:  x = 160 + (cell.x - 폭/2)
    //   그래서 한 줄의 오른쪽 끝은 언제나  160 + 폭/2  이고, 화면(256) 안에
    //   있으려면
    //
    //       160 + 폭/2 <= 256   ->   폭 <= 192 px
    //
    //   **192 는 가운데 정렬에서 유도되는 정확한 값이다.**  옛 16 칸 한도는
    //   그것을 12 px/자 로 어림한 대용품이었는데, 실제 글꼴의 최대 advance 는
    //   10 px 이고 띄어쓰기·문장부호는 4~6 px 다.  그래서 같은 칸 수라도 폭이
    //   딴판이라 칸으로는 판정이 안 된다:
    //
    //       "메탈, JUNKER 본부로 서두르자"        19 칸인데 140 px  -> 넉넉
    //       (전부 넓은 글자인 가상의 19 칸)       19 칸에 190 px    -> 아슬아슬
    //
    //   그래서 화면 판정은 **폭**으로만 한다.
    private const int SubtitleLimitPx = 192;
    // 엔진의 하드 한도.  VRAM 글리프 슬롯 수이고 넘으면 글자가 조용히 사라진다.
    // 폭과 성격이 다른 관문이라 같이 검사하되, 평소에 걸리는 쪽은 폭이다.
    private const int SubtitleLimitCells = 19;
    private Dictionary<char, int>? subtitleAdvance;
    private readonly CheckBox cddaSpeechOnly = new() { Text = "말 있는 것만", AutoSize = true, Checked = false, Padding = new Padding(8, 6, 0, 0) };
    private readonly TabPage speakerPage = new("화자명");
    private readonly TabPage uiPage = new("UI");
    private readonly DataGridView speakerGrid = NewEditableGrid();
    private readonly DataGridView uiGrid = NewEditableGrid();
    private readonly SplitContainer uiSplit = new()
    {
        Dock = DockStyle.Fill,
        Orientation = Orientation.Vertical,
        SplitterWidth = 6,
    };
    private readonly TextBox uiSearchBox = new() { Width = 310, PlaceholderText = "UI ID / Japanese / Korean search" };
    private readonly System.Windows.Forms.Timer uiSearchDebounce = new() { Interval = 280 };
    private readonly Label uiSummaryLabel = new() { AutoSize = true, Padding = new Padding(8, 7, 0, 0) };
    private readonly Label uiIdentityLabel = new() { AutoSize = true, Font = new Font("맑은 고딕", 10, FontStyle.Bold) };
    private readonly TextBox uiJpBox = new() { Multiline = true, ReadOnly = true, Height = 88, Dock = DockStyle.Top, Font = new Font("맑은 고딕", 11), BackColor = Theme.SurfaceAlt };
    private readonly TextBox uiKoBox = new() { Multiline = true, Height = 94, Dock = DockStyle.Top, Font = new Font("맑은 고딕", 12) };
    private readonly Label uiMetricLabel = new() { AutoSize = true, Font = new Font("맑은 고딕", 10, FontStyle.Bold), Padding = new Padding(8, 7, 0, 0) };
    private readonly DataGridView auditGrid = NewGrid();
    private readonly DataGridView voiceEventGrid = NewEditableGrid();
    private readonly DataGridView voiceSubtitleGrid = NewEditableGrid();
    private readonly TextBox voiceSearchBox = new() { Dock = DockStyle.Top, Height = 30, PlaceholderText = "음성 키·파일·화자·일본어·한국어 자막·상태·메모 검색" };
    private readonly System.Windows.Forms.Timer voiceSearchDebounce = new() { Interval = 240 };
    private readonly TextBox cddaSearchBox = new() { Dock = DockStyle.Top, Height = 30, PlaceholderText = "클립·트랙·일본어·한국어 자막 검색" };
    private readonly System.Windows.Forms.Timer cddaSearchDebounce = new() { Interval = 240 };
    // 재생기.  SoundPlayer 에서 MCI 로 바꿨다 -- 일시정지·자리 이동이 필요했고
    // SoundPlayer 에는 그것이 원리적으로 없다 (ClipPlayer 주석 참고).
    private readonly ClipPlayer clipPlayer = new();
    private readonly SubtitleTimeline voiceTimeline = new() { Dock = DockStyle.Bottom, Height = 82 };
    private readonly SubtitleTimeline cddaTimeline = new() { Dock = DockStyle.Bottom, Height = 82 };
    private readonly Stopwatch subtitlePlaybackClock = new();
    private readonly System.Windows.Forms.Timer subtitlePlaybackTimer = new() { Interval = 50 };
    private SubtitleTimeline? activeSubtitleTimeline;
    private readonly Label voiceSummary = new() { AutoSize = true, Padding = new Padding(8, 7, 0, 0) };
    private readonly Label selectedVoiceSummary = new() { AutoSize = true, Padding = new Padding(8, 8, 0, 0), Font = new Font("맑은 고딕", 9, FontStyle.Bold) };
    private readonly Label voiceSubtitleIdentityLabel = new() { AutoSize = true, Font = new Font("맑은 고딕", 10, FontStyle.Bold) };
    private readonly TextBox voiceSubtitleKoBox = new() { Multiline = true, Dock = DockStyle.Fill, Font = new Font("맑은 고딕", 12), Enabled = false };
    private readonly ComboBox auditCategory = new() { Width = 135, DropDownStyle = ComboBoxStyle.DropDownList };
    private readonly ComboBox buildVersion = new() { Width = 100, DropDownStyle = ComboBoxStyle.DropDownList };
    private readonly Label auditSummary = new() { AutoSize = true, Padding = new Padding(8, 7, 0, 0) };
    private readonly System.Windows.Forms.Timer auditDebounce = new() { Interval = 600 };
    private readonly System.Windows.Forms.Timer voiceDebounce = new() { Interval = 600 };
    private readonly System.Windows.Forms.Timer uiDebounce = new() { Interval = 600 };
    private FileSystemWatcher? watcher;
    private FileSystemWatcher? voiceWatcher;
    private FileSystemWatcher? uiWatcher;
    private bool shuttingDown;
    private List<AuditItem> auditItems = new();
    private HashSet<int>? duplicateConflictCache;
    private HashSet<int>? silentRootConflictCache;
    private Dictionary<int, HashSet<string>>? auditStatusCache;
    private List<int> filteredMaster = new();
    private int currentMasterIndex = -1;
    private List<string>? currentUiRow;
    private List<string>? currentVoiceSubtitleRow;
    private DataGridViewRow? currentVoiceSubtitleGridRow;
    private bool loadingVoiceSubtitles;
    private bool loadingMaster;
    private bool loadingChapter;
    private bool loadingStatic;
    // This affects only the grid.  master.Rows stays untouched: BR/CONT/END
    // order is authored record order and must never be physically reordered.
    private bool orderMasterByScene;

    // ListBox display text is not a stable identity. Keep the actual TSV row
    // index so a duplicate entry can open its exact source record.
    private sealed record DuplicateListEntry(int MasterIndex, string Display)
    {
        public override string ToString() => Display;
    }

    public MainForm()
    {
        root = ResolveRoot();
        translationDir = Path.Combine(root, "translation");
        backupDir = Path.Combine(root, "backups");
        Text = "Snatcher 한국어 패치 스튜디오";
        Width = 1560; Height = 930; MinimumSize = new Size(1180, 720);
        Font = new Font("맑은 고딕", 9);
        LoadDocuments();
        BuildUi();
        subtitlePlaybackTimer.Tick += (_, _) => TickSubtitleTimeline();
        WireSubtitleTimelines();   // BuildUi 뒤라야 그리드가 다 만들어져 있다
        RefreshMasterGrid();
        PopulateStaticTables();
        // Paint after the tree is built.  Row-level status colours are applied
        // by the refresh methods and are already theme tokens, so they survive.
        Theme.Apply(this);
        Shown += (_, _) => { SetInitialMasterSplit(); SetInitialUiSplit(); };
        FormClosing += OnClosing;
        // Program.cs 의 Environment.Exit(0) 은 Application.Run() 이 반환해야 도달한다.
        // 외부 빌드 대기 같은 작업이 메시지 루프를 붙잡으면 창이 사라진 뒤에도
        // 프로세스가 남았다.  저장 확인과 백그라운드 정리가 모두 끝난 이 시점에
        // 프로세스를 직접 끝낸다.
        FormClosed += (_, _) => { ShutdownBackgroundServices(); Environment.Exit(0); };
        KeyPreview = true;
        KeyDown += (_, e) =>
        {
            if (e.Control && e.KeyCode == Keys.S) { SaveAll(); e.SuppressKeyPress = true; return; }
            // 스페이스는 모든 입력칸에서 평범한 띄어쓰기로 남긴다.
            // 재생/일시정지는 글 입력과 충돌하지 않는 F5 하나만 쓴다.
            if (e.KeyCode == Keys.F5)
            {
                TogglePlayback();
                e.SuppressKeyPress = true;
                e.Handled = true;
                return;
            }
            if (mainTabs.SelectedTab == cddaPage && e.KeyCode == Keys.F6)
            {
                SetCddaBoundaryFromPlayhead(setStart: true);
                e.SuppressKeyPress = true;
                e.Handled = true;
                return;
            }
            if (mainTabs.SelectedTab == cddaPage && e.KeyCode == Keys.F7)
            {
                SetCddaBoundaryFromPlayhead(setStart: false);
                e.SuppressKeyPress = true;
                e.Handled = true;
            }
        };
    }

    protected override void OnHandleCreated(EventArgs e)
    {
        base.OnHandleCreated(e);
        Theme.ApplyDarkTitleBar(Handle);
    }

    private static string ResolveRoot()
    {
        var configured = Environment.GetEnvironmentVariable("SNATCHER_TOOL_ROOT");
        if (!string.IsNullOrWhiteSpace(configured) && HasTranslationFiles(configured))
            return Path.GetFullPath(configured);

        var portable = Path.GetFullPath(AppContext.BaseDirectory);
        if (HasTranslationFiles(portable)) return portable;

        var development = @"C:\snatcher\snatcher_tool";
        if (HasTranslationFiles(development)) return development;

        var legacy = @"C:\snatcher";
        if (HasTranslationFiles(legacy)) return legacy;

        throw new DirectoryNotFoundException(
            "EXE 옆 translation 폴더에서 snatcher_ko_master.tsv, " +
            "speaker_name_standard.tsv, ui_text.tsv를 찾을 수 없습니다.");
    }

    private static bool HasTranslationFiles(string rootPath)
    {
        var dir = Path.Combine(rootPath, "translation");
        return File.Exists(Path.Combine(dir, "snatcher_ko_master.tsv"))
            && File.Exists(Path.Combine(dir, "speaker_name_standard.tsv"))
            && File.Exists(Path.Combine(dir, "ui_text.tsv"));
    }

    // 수집기 0.2.0 이 쓰는 파일 이름.  0.1.x 는 문단 경계를 "18칸을 채웠나" 로
    // 추측했고 그것이 문단을 2.4배로 부수고 있었다 (PROBE 0.6.7: 블록 215 vs 실제
    // 레코드 90).  0.2.0 은 $6FFD 에서 레코드 시작을 관측해 record_seq/record_line/
    // record_ptr 을 남긴다.  이름이 달라진 덕에 옛 로그가 덮이지 않는다.
    private const string RuntimeAuditFileName = "runtime_text_audit_raw_v020.tsv";
    private const string RuntimeUiFileName = "runtime_ui_strings_raw_v020.tsv";
    private const string RuntimeAuditLuaName = "runtime_text_audit_0.2.0.lua";
    // 옛 정적 마스터.  현역 마스터가 런타임 골격으로 교체되면서 참조 대장으로
    // 내려갔다.  새로 잡힌 대사의 번역을 여기서 끌어온다 -- 이것이 없으면 수집할
    // 때마다 사람이 배치 도구를 따로 돌려야 한다.
    private const string LegacyMasterFileName = "legacy_static_master.tsv";

    private void LoadDocuments()
    {
        master = TsvDocument.Load(Path.Combine(translationDir, "snatcher_ko_master.tsv"));
        // The MPR6 bank the renderer had mapped when a line was captured.  It is
        // the pack key the build groups by, recorded as fact instead of inferred
        // afterwards from nearest-sequence text matching.  Rows collected before
        // the Lua logged it stay blank until that line is seen in play again.
        master.EnsureColumn("pack");
        master.EnsureColumn("speaker");
        master.EnsureColumn("chapter");
        // Explicit opt-in for roots that need the captured pack/speaker key.
        // Users never type a state number; AUTO is resolved by the builder.
        master.EnsureColumn("root_mode");
        speakers = TsvDocument.Load(Path.Combine(translationDir, "speaker_name_standard.tsv"));
        ui = TsvDocument.Load(Path.Combine(translationDir, "ui_text.tsv"));
        var uiReviewColumnMissing = ui.Column("review") < 0;
        ui.EnsureColumn("review");
        if (uiReviewColumnMissing) ui.Save(backupDir);
        EnsureTsv(Path.Combine(translationDir, "voice_events.tsv"), "event_id\tsequence\tstart_frame\tend_frame\tdetected_duration\taudio_type\tsource_key\tread_address\twrite_address\taudio_length\tplayback_rate\tsector\tscene_id\tnote\tstatus");
        EnsureTsv(Path.Combine(translationDir, "voice_subtitles.tsv"), "event_id	part	start_sec	duration_sec	gap_after_sec	ko_text	pos	status	note");
        voiceEvents = TsvDocument.Load(Path.Combine(translationDir, "voice_events.tsv"));
        // clip_file 은 runtime_text_audit 0.2.2 가 넣는다.  재생 시작 순간의 ADPCM
        // RAM 을 그대로 뜬 파일 이름이고, 이름 자체가 내용 지문이라 같은 대사면
        // 세션이 달라도 같은 값이다.  이것이 붙으면 소리와 원문이 한 줄에 놓인다.
        // vram_observed / vram_bases 는 tools/mark_vram_observed.py 가 찍는다.  옛 표에는
        // 없으므로 여기서 만들어 둔다 -- CD-DA 탭이 cddaSegments 에 하는 것과 같다.
        foreach (var column in new[] { "fingerprint", "occurrences", "active_count", "context", "kind", "speaker", "clip_file", "jp_whisper", "vram_observed", "vram_bases", "vram_status" }) voiceEvents.EnsureColumn(column);
        // Older portable databases used internal English values.  Keep the
        // on-disk value human-readable from now on, without losing old work.
        foreach (var row in voiceEvents.Rows)
        {
            var kind = voiceEvents.Get(row, "kind");
            if (kind.Equals("speech", StringComparison.OrdinalIgnoreCase)) voiceEvents.Set(row, "kind", "대사");
            else if (kind.Equals("sfx", StringComparison.OrdinalIgnoreCase)) voiceEvents.Set(row, "kind", "효과음");
            else if (kind.Length == 0 || kind.Equals("music", StringComparison.OrdinalIgnoreCase) || kind.Equals("unclassified", StringComparison.OrdinalIgnoreCase)) voiceEvents.Set(row, "kind", "기타");
        }
        LoadVoiceTranscript();
        LoadCddaTables();
        voiceSubtitles = TsvDocument.Load(Path.Combine(translationDir, "voice_subtitles.tsv"));
        // 자막 세로 자리.  빈칸이면 팩 빌더의 기본값 (ADPCM 중간 · CD-DA 아래)
        voiceSubtitles.EnsureColumn("pos");
        // 검토 표시 (2026-09-01).  대사·UI 탭과 같은 규약: "O" 만 출하한다.
        // 조금씩 검토하며 실기로 확인하려면 "검토된 것만" 골라 구울 수 있어야 한다.
        voiceSubtitles.EnsureColumn("review");
        EnsureTsv(Path.Combine(translationDir, "voice_excluded.tsv"), "fingerprint\tevent_id\tsource_key\tkind\texcluded_at\tnote");
        voiceExcluded = TsvDocument.Load(Path.Combine(translationDir, "voice_excluded.tsv"));
        excludedVoiceFingerprints = voiceExcluded.Rows
            .Select(row => voiceExcluded.Get(row, "fingerprint"))
            .Where(fingerprint => fingerprint.Length > 0)
            .ToHashSet(StringComparer.Ordinal);
    }

    private static void EnsureTsv(string path, string header)
    {
        if (File.Exists(path)) return;
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        File.WriteAllText(path, header + Environment.NewLine, new System.Text.UTF8Encoding(true));
    }

    private void BuildUi()
    {
        Controls.Add(mainTabs);
        var masterPage = new TabPage("대사 편집");
        var auditPage = new TabPage("플레이 감사 · 누락 수집");
        var voicePage = new TabPage("음성 자막");
        mainTabs.TabPages.AddRange(new[] { masterPage, speakerPage, uiPage, auditPage, voicePage, cddaPage });
        BuildMasterTab(masterPage);
        BuildUiTab(uiPage);
        BuildAuditTab(auditPage);
        BuildVoiceTab(voicePage);
        BuildCddaTab(cddaPage);
    }

    private void BuildVoiceTab(TabPage page)
    {
        var toolbar = new FlowLayoutPanel { Dock = DockStyle.Top, Height = 45, Padding = new Padding(7), WrapContents = false };
        toolbar.Controls.AddRange(new Control[] {
            Button("음성 로그 가져오기", (_, _) => ImportVoiceLog()),
            Button("▶ 소리 재생", (_, _) => PlaySelectedVoiceClip()),
            Button("■ 정지", (_, _) => StopVoiceClip()),
            Button("위", (_, _) => SetSelectedVoicePos("위")),
            Button("중간", (_, _) => SetSelectedVoicePos("중간")),
            Button("아래", (_, _) => SetSelectedVoicePos("아래")),
            Button("위치 기본", (_, _) => SetSelectedVoicePos("")),
            Button("+ 자막 추가", (_, _) => AddVoiceSubtitle()),
            Button("선택 자막 삭제", (_, _) => DeleteVoiceSubtitle()),
            Button("대사", (_, _) => SetSelectedVoiceKind("대사")),
            Button("효과음", (_, _) => SetSelectedVoiceKind("효과음")),
            Button("기타", (_, _) => SetSelectedVoiceKind("기타")),
            Button("선택 삭제(제외)", (_, _) => DeleteVoiceEvent()),
            // 검토 표시 -- 조금씩 검토하며 실기로 확인하려고 붙였다 (2026-09-01)
            Button("검토 O", (_, _) => SetVoiceSubtitleReview("O")),
            Button("검토 해제", (_, _) => SetVoiceSubtitleReview("")),
            Button("저장 Ctrl+S", (_, _) => SaveAll()),
            Button("로그 폴더 열기", (_, _) => OpenPath(Path.Combine(root, "logs"))),
            voiceSummary
        });

        foreach (var (name, title, width, readOnly) in new[] {
            ("event_id", "이벤트", 190, true), ("sequence", "순번", 55, true), ("detected_duration", "감지 길이", 70, true),
            ("audio_type", "형식", 65, true), ("source_key", "음성 키", 180, true),
            // VRAM 수집 현황.  tools/mark_vram_observed.py 가 voice_events.tsv 에
            // 찍어 둔 것을 그대로 보여준다.  CD-DA 탭에만 있던 열을 음성에도 붙였다
            // (2026-08-31) -- 값은 예전부터 표에 있었는데 보여줄 칸이 없었다.
            ("vram_observed", "관측", 45, true),
            // 최종 핑퐁 표 기준. "미관측 대사"와 "안전없음 대사"를 따로 검색한다.
            ("vram_status", "VRAM 상태", 75, true),
            ("vram_bases", "자리수", 50, true),
            // 소리 파일.  이름이 곧 내용 지문이라 같은 대사면 세션이 달라도 같다
            ("clip_file", "소리", 110, true),
            ("occurrences", "재생", 55, true), ("active_count", "재생중", 60, true), ("kind", "구분", 80, false),
            ("speaker", "화자", 100, false),
            // 일본어 원문.  소리 파일 이름으로 logs/voice_transcript.tsv 에서 끌어온다
            ("jp_whisper", "일본어 원문", 320, true),
            ("scene_id", "장면", 100, false),
            ("status", "상태", 90, false), ("note", "메모", 260, false) })
        { var i = voiceEventGrid.Columns.Add(name, title); voiceEventGrid.Columns[i].Width = width; voiceEventGrid.Columns[i].ReadOnly = readOnly; }
        var kindIndex = voiceEventGrid.Columns["kind"].Index;
        voiceEventGrid.Columns.Remove("kind");
        voiceEventGrid.Columns.Insert(kindIndex, new DataGridViewComboBoxColumn {
            Name = "kind", HeaderText = "구분", Width = 80, FlatStyle = FlatStyle.Flat,
            DataSource = new[] { "대사", "효과음", "기타" }
        });
        // 대사/효과음/기타를 여러 행에 한 번에 매기려면 다중 선택이 필요하다
        voiceEventGrid.MultiSelect = true;
        voiceEventGrid.SelectionChanged += (_, _) => { RefreshVoiceSubtitles(); ShowVoiceJapanese(); };
        // 행을 더블클릭하면 그 소리를 듣는다 -- 번역하며 반복해 듣게 된다
        voiceEventGrid.CellDoubleClick += (_, _) => PlaySelectedVoiceClip();
        voiceEventGrid.CellValueChanged += (_, e) => UpdateVoiceEvent(e.RowIndex, e.ColumnIndex);
        voiceSearchDebounce.Tick += (_, _) => { voiceSearchDebounce.Stop(); RefreshVoiceEvents(); };
        voiceSearchBox.TextChanged += (_, _) => { voiceSearchDebounce.Stop(); voiceSearchDebounce.Start(); };
        voiceSearchBox.KeyDown += (_, e) =>
        {
            if (e.KeyCode != Keys.Escape) return;
            voiceSearchBox.Clear();
            e.SuppressKeyPress = true;
        };

        foreach (var (name, title, width, readOnly) in new[] {
            ("event_id", "이벤트", 150, true), ("part", "자막", 45, true), ("start_sec", "시작(초)", 75, false),
            ("duration_sec", "지속(초)", 75, false), ("gap_after_sec", "다음 간격(초)", 85, false),
            ("ko_text", "한국어 자막", 260, true), ("pos", "위치", 60, false),
            ("review", "검토", 50, true),
            ("status", "상태", 80, false), ("note", "메모", 150, false) })
        { var i = voiceSubtitleGrid.Columns.Add(name, title); voiceSubtitleGrid.Columns[i].Width = width; voiceSubtitleGrid.Columns[i].ReadOnly = readOnly; }
        // 검토를 여러 줄에 한 번에 매기려면 다중 선택이 필요하다 (대사 탭과 같다)
        voiceSubtitleGrid.MultiSelect = true;
        // ko_text는 오른쪽 편집 칸에서만 입력한다 (대사 탭과 동일한 방식) -- 그리드
        // 칸은 미리보기 전용이라 위 readOnly에 true로 지정했다.
        voiceSubtitleGrid.CellValueChanged += (_, e) => UpdateVoiceSubtitle(e.RowIndex, e.ColumnIndex);
        voiceSubtitleGrid.SelectionChanged += (_, _) => SelectVoiceSubtitleRow();

        var split = new SplitContainer { Dock = DockStyle.Fill, Orientation = Orientation.Horizontal, SplitterDistance = 260 };
        var subtitleHeader = new Panel { Dock = DockStyle.Top, Height = 36, BackColor = Theme.Surface };
        subtitleHeader.Controls.Add(selectedVoiceSummary);
        // 입력칸은 오른쪽 세로줄로 올라갔다.  아래는 조각 목록이 폭을 다 쓴다
        var subtitleArea = new Panel { Dock = DockStyle.Fill };
        subtitleArea.Controls.Add(voiceSubtitleGrid);
        subtitleArea.Controls.Add(subtitleHeader);
        // 위쪽을 좌우로 다시 나눈다: 왼쪽 목록 · 오른쪽 일본어 원문 큰 창.
        // 그리드 칸에서는 긴 원문이 잘려 읽을 수가 없다.
        var topSplit = new SplitContainer {
            Dock = DockStyle.Fill, Orientation = Orientation.Vertical, SplitterWidth = 6
        };
        var japanesePanel = new Panel { Dock = DockStyle.Fill, Padding = new Padding(6, 0, 0, 0) };
        japanesePanel.Controls.Add(voiceJapanese);
        japanesePanel.Controls.Add(voiceJapaneseHead);
        // 오른쪽 세로줄: 원문 위 · 한국어 입력 아래.  대사 편집 탭과 같은 배치다
        var rightColumn = new SplitContainer {
            Dock = DockStyle.Fill, Orientation = Orientation.Horizontal, SplitterWidth = 6
        };
        rightColumn.Panel1MinSize = 0;
        rightColumn.Panel2MinSize = 0;
        rightColumn.Panel1.Controls.Add(japanesePanel);
        rightColumn.Panel2.Controls.Add(BuildVoiceSubtitleEditorPanel());
        rightColumn.HandleCreated += (_, _) => rightColumn.BeginInvoke(new Action(() => {
            var height = rightColumn.ClientSize.Height;
            if (height > rightColumn.SplitterWidth + 2)
                rightColumn.SplitterDistance = Math.Clamp((int)(height * 0.42), 1,
                                                          height - rightColumn.SplitterWidth - 1);
        }));
        var voiceListPanel = new Panel { Dock = DockStyle.Fill };
        voiceEventGrid.Dock = DockStyle.Fill;
        voiceListPanel.Controls.Add(voiceEventGrid);
        voiceListPanel.Controls.Add(voiceSearchBox);
        topSplit.Panel1.Controls.Add(voiceListPanel);
        topSplit.Panel2.Controls.Add(rightColumn);
        topSplit.Panel1MinSize = 0;
        topSplit.Panel2MinSize = 0;
        // 폭이 잡힌 뒤에 나눠야 한다 -- 레이아웃 전에는 SplitterDistance 가 튕긴다
        topSplit.HandleCreated += (_, _) => topSplit.BeginInvoke(new Action(() => {
            var width = topSplit.ClientSize.Width;
            if (width > topSplit.SplitterWidth + 2)
                topSplit.SplitterDistance = Math.Clamp((int)(width * 0.66), 1,
                                                       width - topSplit.SplitterWidth - 1);
        }));
        split.Panel1.Controls.Add(topSplit);
        split.Panel2.Controls.Add(subtitleArea);
        page.Controls.Add(split); page.Controls.Add(toolbar);
        ShowVoiceJapanese();
        RefreshVoiceEvents();
    }

    private Control BuildVoiceSubtitleEditorPanel()
    {
        var actions = new FlowLayoutPanel { Dock = DockStyle.Bottom, Height = 42, Padding = new Padding(0, 4, 0, 0) };
        actions.Controls.AddRange(new Control[] {
            // 재생 조작은 타임라인 바로 아래에 둔다 -- 노란 선을 끌어 자리를 잡고
            // 곧바로 듣는 동작이라 손이 멀면 안 된다.  스페이스바와 같은 일을 한다.
            Button("▶ / ⏸  (F5)", (_, _) => TogglePlayback()),
            Button("■ 정지", (_, _) => StopVoiceClip()),
            Button("적용", (_, _) => ApplyVoiceSubtitleCurrent()),
            Button("◀ 이전 자막", (_, _) => MoveVoiceSubtitle(-1)),
            Button("적용 후 다음 자막 ▶", (_, _) => MoveVoiceSubtitle(1))
        });
        var editor = new Panel { Dock = DockStyle.Fill, Padding = new Padding(8) };
        editor.Controls.Add(voiceTimeline);
        editor.Controls.Add(actions);
        editor.Controls.Add(voiceSubtitleKoBox);
        editor.Controls.Add(voiceWidthLabel);
        editor.Controls.Add(new Label { Text = "한국어 자막", Dock = DockStyle.Top, Height = 23 });
        editor.Controls.Add(voiceSubtitleIdentityLabel); voiceSubtitleIdentityLabel.Dock = DockStyle.Top; voiceSubtitleIdentityLabel.Height = 28;
        // 네이티브 ADPCM/CD-DA 팩과 같은 규칙: ...·⋯·…는 언제 입력해도
        // 한 칸짜리 말줄임표 하나로 저장한다.
        voiceSubtitleKoBox.TextChanged += NormalizeSubtitleEllipsisEditor;
        voiceSubtitleKoBox.TextChanged += (_, _) => ShowWidth(voiceWidthLabel, voiceSubtitleKoBox.Text);
        ShowWidth(voiceWidthLabel, voiceSubtitleKoBox.Text);
        return editor;
    }

    /// <summary>자막 한 줄의 실제 픽셀 폭을 보여준다.  넘으면 빨갛게.</summary>
    private void ShowWidth(Label label, string text)
    {
        text ??= "";
        var cells = text.Trim().Length;
        var width = SubtitleWidthPx(text ?? "");
        // ★ 기준은 **폭(px)** 하나다 (2026-09-03).  가운데 정렬이라 오른쪽 끝이
        //   160 + 폭/2 이고, 192 px 를 넘으면 마지막 글자가 화면 밖으로 나간다.
        //   칸 수는 엔진 슬롯이 모자랄 때만 따로 경고한다 (평소엔 폭이 먼저 걸린다).
        var overPx = width > SubtitleLimitPx;
        var overCells = cells > SubtitleLimitCells;
        label.Text = $"폭 {width} / {SubtitleLimitPx} px"
            + (overPx ? $"   ★ {width - SubtitleLimitPx}px 넘침 -- 나눠야 한다" : "")
            + (overCells ? $"   ★ 엔진 슬롯 초과 {cells}/{SubtitleLimitCells}칸" : "");
        var over = overPx || overCells;
        label.ForeColor = over ? Theme.Bad : Theme.TextMuted;
    }

    // 재생 상태가 바뀔 때마다 이 메서드가 불린다.  행을 전부 지우고 다시 만들면
    // 편집 중이던 선택과 스크롤 위치가 사라지고, 재생이 끝날 때마다 커서가 재생 중인
    // 행으로 끌려가 손으로 잡고 있기가 어렵다.  행 구성이 그대로면 배경색만 갱신한다.
    private bool VoiceGridMatchesData(IReadOnlyList<List<string>> visibleRows)
    {
        if (voiceEventGrid.Rows.Count != visibleRows.Count) return false;
        for (var index = 0; index < visibleRows.Count; index++)
            if (!ReferenceEquals(voiceEventGrid.Rows[index].Tag, visibleRows[index])) return false;
        return true;
    }

    private static bool SearchTermsMatch(string query, IEnumerable<string> values)
    {
        var terms = query.Split(' ', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
        if (terms.Length == 0) return true;
        var haystack = string.Join(" ", values);
        return terms.All(term => haystack.Contains(term, StringComparison.OrdinalIgnoreCase));
    }

    /// <summary>요약줄.  VRAM 관측이 몇 건까지 왔는지 같이 보여준다 -- 수집은 여러 판에
    /// 걸쳐 도는 일이라 "남은 것이 몇 개인가" 가 다음 판을 어디로 돌지 정한다.</summary>
    private string VoiceSummaryText(int visible)
    {
        var observed = voiceEvents.Rows.Count(r => voiceEvents.Get(r, "vram_observed").Length > 0);
        var unobserved = voiceEvents.Rows.Count(r => voiceEvents.Get(r, "vram_status") == "미관측");
        var safe = voiceEvents.Rows.Count(r => int.TryParse(voiceEvents.Get(r, "vram_bases"), out var n) && n > 0);
        var singleSafe = voiceEvents.Rows.Count(r => voiceEvents.Get(r, "vram_status") == "단일안전");
        var noSafe = voiceEvents.Rows.Count(r => voiceEvents.Get(r, "vram_status") == "안전없음");
        var testExcluded = voiceEvents.Rows.Count(r => voiceEvents.Get(r, "vram_bases") == "시험제외");
        // ★ 2026-09-03: 검토 진도를 같이 보여준다.  음성 단위로 끊어 작업하시므로
        //   실제로 보고 싶은 숫자는 **남은 음성**이다.  줄 수도 같이 낸다.
        var lines = voiceSubtitles.Rows.Count;
        var lineOk = voiceSubtitles.Rows.Count(
            r => voiceSubtitles.Get(r, "review").Equals("O", StringComparison.OrdinalIgnoreCase));
        var voices = voiceSubtitles.Rows.GroupBy(r => voiceSubtitles.Get(r, "event_id")).ToList();
        var subtitleVoiceIds = voices.Select(g => g.Key).ToHashSet(StringComparer.Ordinal);
        var unobservedSubtitle = voiceEvents.Rows.Count(r =>
            voiceEvents.Get(r, "vram_status") == "미관측" &&
            subtitleVoiceIds.Contains(voiceEvents.Get(r, "event_id")));
        var noSafeSubtitle = voiceEvents.Rows.Count(r =>
            voiceEvents.Get(r, "vram_status") == "안전없음" &&
            subtitleVoiceIds.Contains(voiceEvents.Get(r, "event_id")));
        var voiceOk = voices.Count(g => g.All(
            r => voiceSubtitles.Get(r, "review").Equals("O", StringComparison.OrdinalIgnoreCase)));
        var pct = voices.Count > 0 ? voiceOk * 100.0 / voices.Count : 0;
        return $"음성 {voiceEvents.Rows.Count}건 · 자막 {lines}줄 · 보이는 것 {visible}"
             + $" · 관측 {observed} / 미관측 {unobserved}(자막 {unobservedSubtitle})"
             + $" · 안전자리 {safe}(단일 {singleSafe}) / 안전없음 {noSafe}(자막 {noSafeSubtitle})"
             + (noSafe > noSafeSubtitle ? $" / 자막없음 {noSafe - noSafeSubtitle}" : "")
             + (testExcluded > 0 ? $" / 시험제외 {testExcluded}" : "")
             + $"   ★ 검토 {voiceOk:N0}/{voices.Count:N0} 음성 ({pct:F1}%) · 남은 음성 {voices.Count - voiceOk:N0}"
             + $" · 줄 {lineOk:N0}/{lines:N0}";
    }

    /// <summary>이벤트별 자막 본문을 모은다 (event_id -> 한국어 + 메모).
    ///
    /// ★ 2026-09-05.  음성 검색이 <c>voiceEvents</c> 행만 뒤지고 있었다.  그런데
    /// 자막 본문은 <c>voice_subtitles.tsv</c> 에 따로 있어서, **번역해 둔 한국어로는
    /// 그 음성을 찾을 수 없었다** -- 정작 제일 자주 찾는 것이 그건데.
    /// (voice_subtitles 에는 일본어 열이 없다.  일본어는 이벤트 쪽 jp_whisper 이고
    ///  그건 이미 검색에 걸린다.)
    /// </summary>
    private Dictionary<string, string> BuildVoiceSubtitleIndex()
    {
        var map = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var row in voiceSubtitles.Rows)
        {
            var id = voiceSubtitles.Get(row, "event_id");
            if (id.Length == 0) continue;
            var text = voiceSubtitles.Get(row, "ko_text") + " " + voiceSubtitles.Get(row, "note");
            map[id] = map.TryGetValue(id, out var prev) ? prev + " " + text : text;
        }
        return map;
    }

    private bool VoiceMatchesSearch(List<string> row, Dictionary<string, string> subtitles)
    {
        if (voiceSearchBox.Text.Trim().Length == 0) return true;
        var id = voiceEvents.Get(row, "event_id");
        return subtitles.TryGetValue(id, out var lines)
            ? SearchTermsMatch(voiceSearchBox.Text, row.Append(lines))
            : SearchTermsMatch(voiceSearchBox.Text, row);
    }

    // 대사가 필요 없는 효과음 · 기타는 빨간 계열로 표시해 삭제 후보를 한눈에 보이게 한다.
    private static Color VoiceKindColor(string kind) => kind is "효과음" or "기타" ? Theme.RowOverLimit : Color.Empty;

    private Color VoiceRowColor(List<string> row) =>
        voiceEvents.Get(row, "vram_status") == "안전없음"
            ? Theme.RowOverLimit
            : VoiceKindColor(voiceEvents.Get(row, "kind"));

    private void PaintVoiceActivity(IReadOnlySet<string>? activeFingerprints)
    {
        foreach (DataGridViewRow gridRow in voiceEventGrid.Rows)
        {
            if (gridRow.Tag is not List<string> row) continue;
            var active = activeFingerprints != null && activeFingerprints.Contains(voiceEvents.Get(row, "fingerprint"));
            var wanted = active ? Theme.RowNew : VoiceRowColor(row);
            var style = gridRow.DefaultCellStyle;
            if (style.BackColor == wanted) continue;          // 바뀐 행만 다시 그린다
            style.BackColor = wanted;
            style.SelectionBackColor = active ? Theme.SelectActive : wanted == Color.Empty ? Color.Empty : Theme.SelectOverLimit;
            style.SelectionForeColor = active ? Color.White : Color.Empty;
        }
    }

    private void RefreshVoiceEvents(IReadOnlySet<string>? activeFingerprints = null)
    {
        var subtitleIndex = BuildVoiceSubtitleIndex();
        var visibleRows = voiceEvents.Rows.Where(r => VoiceMatchesSearch(r, subtitleIndex)).ToList();
        if (VoiceGridMatchesData(visibleRows))
        {
            PaintVoiceActivity(activeFingerprints);
            voiceSummary.Text = VoiceSummaryText(visibleRows.Count);
            return;
        }

        // 여기부터는 행 구성 자체가 바뀐 경우(가져오기·삭제·병합)뿐이다.
        var previous = voiceEventGrid.SelectedRows.Count > 0 ? voiceEventGrid.SelectedRows[0].Tag : null;
        loadingStatic = true;
        voiceEventGrid.Rows.Clear();
        foreach (var row in visibleRows)
        {
            var index = voiceEventGrid.Rows.Add();
            var values = new[] { "event_id", "sequence", "detected_duration", "audio_type", "source_key", "vram_observed", "vram_status", "vram_bases", "clip_file", "occurrences", "active_count", "kind", "speaker", "jp_whisper", "scene_id", "status", "note" };
            for (var column = 0; column < values.Length; column++) voiceEventGrid.Rows[index].Cells[column].Value = voiceEvents.Get(row, values[column]);
            voiceEventGrid.Rows[index].Tag = row;
            var active = activeFingerprints != null && activeFingerprints.Contains(voiceEvents.Get(row, "fingerprint"));
            var wanted = active ? Theme.RowNew : VoiceRowColor(row);
            if (wanted != Color.Empty)
            {
                voiceEventGrid.Rows[index].DefaultCellStyle.BackColor = wanted;
                voiceEventGrid.Rows[index].DefaultCellStyle.SelectionBackColor = active ? Theme.SelectActive : Theme.SelectOverLimit;
                voiceEventGrid.Rows[index].DefaultCellStyle.SelectionForeColor = active ? Color.White : Color.Empty;
            }
        }
        voiceSummary.Text = VoiceSummaryText(visibleRows.Count);

        // 다시 만든 뒤에도 보고 있던 행을 그대로 돌려준다.  선택이 아예 없었을 때만
        // 재생 중인 행으로 옮긴다 -- 작업 중인 커서를 빼앗지 않기 위해서다.
        var restored = previous == null ? null : voiceEventGrid.Rows.Cast<DataGridViewRow>()
            .FirstOrDefault(r => ReferenceEquals(r.Tag, previous));
        var target = restored ?? (activeFingerprints == null ? null : voiceEventGrid.Rows.Cast<DataGridViewRow>()
            .FirstOrDefault(r => r.Tag is List<string> row && activeFingerprints.Contains(voiceEvents.Get(row, "fingerprint"))));
        if (target != null)
        {
            target.Selected = true;
            voiceEventGrid.CurrentCell = target.Cells[0];
            voiceEventGrid.FirstDisplayedScrollingRowIndex = target.Index;
        }
        else if (voiceEventGrid.Rows.Count > 0 && voiceEventGrid.SelectedRows.Count == 0) voiceEventGrid.Rows[0].Selected = true;
        loadingStatic = false;
    }

    private void UpdateVoiceEvent(int rowIndex, int columnIndex)
    {
        if (loadingStatic || rowIndex < 0 || columnIndex < 0 || rowIndex >= voiceEventGrid.Rows.Count) return;
        if (voiceEventGrid.Rows[rowIndex].Tag is not List<string> row) return;
        var name = voiceEventGrid.Columns[columnIndex].Name;
        if (name is not ("speaker" or "scene_id" or "status" or "note" or "kind")) return;
        voiceEvents.Set(row, name, voiceEventGrid.Rows[rowIndex].Cells[columnIndex].Value?.ToString() ?? "");
        UpdateTitle();
        if (name == "kind") RefreshVoiceEvents();
    }

    /// <summary>선택한 행 전부의 구분을 바꾼다.</summary>
    /// <remarks>
    /// 예전에는 SelectedRows[0] 만 보고, 비어 있으면 조용히 return 했다.
    /// 콤보 셀을 편집하는 중에는 SelectedRows 가 비고 CurrentRow 만 있어서
    /// 버튼이 아무 반응도 안 하는 것처럼 보였다.  이제 CurrentRow 로 되돌아가고,
    /// 다중 선택이면 선택한 행 전부에 매긴다.
    /// </remarks>
    private void SetSelectedVoiceKind(string kind)
    {
        var targets = SelectedVoiceRows();
        if (targets.Count == 0) { voiceSummary.Text = "먼저 행을 고르세요"; return; }
        foreach (var row in targets) voiceEvents.Set(row, "kind", kind);
        voiceEvents.Dirty = true;
        RefreshVoiceEvents();
        UpdateTitle();
        voiceSummary.Text = $"{targets.Count}행을 '{kind}' 로";
    }

    /// <summary>선택된 행들.  선택이 없으면 커서가 있는 행 하나.</summary>
    private List<List<string>> SelectedVoiceRows()
    {
        var out_ = new List<List<string>>();
        foreach (DataGridViewRow gridRow in voiceEventGrid.SelectedRows)
            if (gridRow.Tag is List<string> row) out_.Add(row);
        if (out_.Count == 0 && voiceEventGrid.CurrentRow?.Tag is List<string> current)
            out_.Add(current);
        return out_;
    }

    /// <summary>오른쪽 큰 창에 선택한 행의 일본어 원문을 보여준다.</summary>
    private void ShowVoiceJapanese()
    {
        var rows = SelectedVoiceRows();
        if (rows.Count == 0) { voiceJapaneseHead.Text = "일본어 원문"; voiceJapanese.Text = ""; return; }
        if (rows.Count > 1)
        {
            voiceJapaneseHead.Text = $"일본어 원문 — {rows.Count}행 선택됨";
            voiceJapanese.Text = string.Join(Environment.NewLine, rows.Select(r =>
                $"{voiceEvents.Get(r, "event_id")}  {voiceEvents.Get(r, "jp_whisper")}"));
            return;
        }
        var only = rows[0];
        var speaker = voiceEvents.Get(only, "speaker");
        voiceJapaneseHead.Text = $"일본어 원문 — {voiceEvents.Get(only, "detected_duration")}초"
            + (speaker.Length > 0 ? $" · {speaker}" : "");
        voiceJapanese.Text = voiceEvents.Get(only, "jp_whisper");
    }

    /// <summary>선택한 음성 이벤트를 목록에서 지운다.</summary>
    /// <remarks>
    /// 예전에는 `SelectedRows.Count == 0` 이면 조용히 `return` 했다.  콤보 셀을
    /// 편집하는 중에는 선택이 비고 `CurrentRow` 만 남아서, 눌러도 아무 반응이
    /// 없는 것처럼 보였다.  같은 뿌리로 구분 버튼도 안 먹었다.
    ///
    /// **조용한 return 은 버그를 숨긴다.**  이제 커서 행으로 되돌아가고,
    /// 여러 행을 고르면 전부 지우고, 결과를 툴바에 찍는다.
    ///
    /// 지우면서 지문을 `voice_excluded.tsv` 에 남긴다 -- 로그를 다시 가져와도
    /// 같은 소리가 되살아나지 않게 하려는 것이다.
    /// </remarks>
    private void DeleteVoiceEvent()
    {
        var targets = SelectedVoiceRows();
        if (targets.Count == 0) { voiceSummary.Text = "먼저 지울 행을 고르세요"; return; }

        var subtitleTotal = targets.Sum(r => voiceSubtitles.Rows.Count(
            x => voiceSubtitles.Get(x, "event_id") == voiceEvents.Get(r, "event_id")));
        var warn = subtitleTotal > 0 ? $"{Environment.NewLine}{Environment.NewLine}연결된 자막 {subtitleTotal}개도 함께 삭제됩니다." : "";
        var what = targets.Count == 1
            ? $"'{voiceEvents.Get(targets[0], "event_id")}' 항목"
            : $"선택한 {targets.Count}개 항목";
        var answer = MessageBox.Show(
            $"{what}을 목록에서 삭제할까요?{warn}",
            "음성 이벤트 삭제", MessageBoxButtons.YesNo, MessageBoxIcon.Warning);
        if (answer != DialogResult.Yes) return;

        var excludedAdded = false;
        foreach (var row in targets)
        {
            var eventId = voiceEvents.Get(row, "event_id");

            foreach (var subtitle in voiceSubtitles.Rows
                         .Where(r => voiceSubtitles.Get(r, "event_id") == eventId).ToList())
            {
                if (ReferenceEquals(subtitle, currentVoiceSubtitleRow))
                {
                    currentVoiceSubtitleRow = null;
                    currentVoiceSubtitleGridRow = null;
                }
                voiceSubtitles.Rows.Remove(subtitle);
                voiceSubtitles.Dirty = true;
            }

            var fingerprint = voiceEvents.Get(row, "fingerprint");
            if (fingerprint.Length > 0 && excludedVoiceFingerprints.Add(fingerprint))
            {
                var record = Enumerable.Repeat("", voiceExcluded.Headers.Count).ToList();
                voiceExcluded.Set(record, "fingerprint", fingerprint);
                voiceExcluded.Set(record, "event_id", eventId);
                voiceExcluded.Set(record, "source_key", voiceEvents.Get(row, "source_key"));
                voiceExcluded.Set(record, "kind", voiceEvents.Get(row, "kind"));
                voiceExcluded.Set(record, "excluded_at", DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss"));
                voiceExcluded.Rows.Add(record);
                voiceExcluded.Dirty = true;
                excludedAdded = true;
            }

            voiceEvents.Rows.Remove(row);
        }

        // 즉시 기록 -- 저장을 누르지 않고 닫아도 재수집을 막는다
        if (excludedAdded) voiceExcluded.Save(backupDir);
        voiceEvents.Dirty = true;
        RefreshVoiceEvents();
        UpdateTitle();
        voiceSummary.Text = $"{targets.Count}개 삭제";
    }

    private string SelectedVoiceEventId()
    {
        var rows = SelectedVoiceRows();
        return rows.Count == 0 ? "" : voiceEvents.Get(rows[0], "event_id");
    }

    private void RefreshVoiceSubtitles()
    {
        if (voiceSubtitles == null) return;
        ApplyVoiceSubtitleCurrent(); // 목록을 다시 만들기 전에 오른쪽 입력칸 내용부터 반영한다
        var eventId = SelectedVoiceEventId();
        loadingVoiceSubtitles = true;
        voiceSubtitleGrid.Rows.Clear();
        // ★ 위 그리드 열 정의와 **순서가 같아야 한다** (여기는 자리로 채운다)
        var columns = new[] { "event_id", "part", "start_sec", "duration_sec", "gap_after_sec", "ko_text", "pos", "review", "status", "note" };
        DataGridViewRow? restoreTarget = null;
        foreach (var row in voiceSubtitles.Rows.Where(r => voiceSubtitles.Get(r, "event_id") == eventId).OrderBy(r => ParseInt(voiceSubtitles.Get(r, "part"), 0)))
        {
            var index = voiceSubtitleGrid.Rows.Add(columns.Select(c => voiceSubtitles.Get(row, c)).ToArray());
            voiceSubtitleGrid.Rows[index].Tag = row;
            if (ReferenceEquals(row, currentVoiceSubtitleRow)) restoreTarget = voiceSubtitleGrid.Rows[index];
        }
        loadingVoiceSubtitles = false;
        ValidateVoiceSubtitleTimeline();
        RefreshVoiceTimeline();

        var target = restoreTarget ?? (voiceSubtitleGrid.Rows.Count > 0 ? voiceSubtitleGrid.Rows[0] : null);
        if (target != null)
        {
            target.Selected = true;
            voiceSubtitleGrid.CurrentCell = target.Cells[0];
        }
        else
        {
            currentVoiceSubtitleRow = null;
            currentVoiceSubtitleGridRow = null;
        }
        SelectVoiceSubtitleRow();
    }

    private void SelectVoiceSubtitleRow()
    {
        if (loadingVoiceSubtitles) return;
        if (voiceSubtitleGrid.SelectedRows.Count == 0 || voiceSubtitleGrid.SelectedRows[0].Tag is not List<string> source)
        {
            if (currentVoiceSubtitleRow == null) return;
            currentVoiceSubtitleRow = null;
            currentVoiceSubtitleGridRow = null;
            voiceSubtitleIdentityLabel.Text = "";
            voiceSubtitleKoBox.Text = "";
            voiceSubtitleKoBox.Enabled = false;
            return;
        }
        if (ReferenceEquals(currentVoiceSubtitleRow, source)) return;
        ApplyVoiceSubtitleCurrent();
        currentVoiceSubtitleRow = source;
        currentVoiceSubtitleGridRow = voiceSubtitleGrid.SelectedRows[0];
        voiceTimeline.SelectByTag(source);   // 목록에서 고르면 타임라인에도 표시된다
        voiceSubtitleKoBox.Enabled = true;
        voiceSubtitleIdentityLabel.Text = $"{voiceSubtitles.Get(source, "event_id")} · {voiceSubtitles.Get(source, "part")}번째 자막 · 시작 {voiceSubtitles.Get(source, "start_sec")}초";
        voiceSubtitleKoBox.Text = voiceSubtitles.Get(source, "ko_text");
    }

    // "적용 후 다음 자막"이 매번 그리드를 훑지 않도록 화면 행을 캐시해 둔다
    // (UI 탭 CurrentUiGridRow()와 동일한 패턴). RefreshVoiceSubtitles가 그리드를
    // 다시 만들면 캐시가 어긋나고, 그때만 Tag로 다시 찾는다.
    private DataGridViewRow? CurrentVoiceSubtitleGridRow()
    {
        if (currentVoiceSubtitleRow == null) return null;
        var cached = currentVoiceSubtitleGridRow;
        if (cached != null && cached.DataGridView == voiceSubtitleGrid && cached.Index >= 0
            && ReferenceEquals(cached.Tag, currentVoiceSubtitleRow)) return cached;
        currentVoiceSubtitleGridRow = voiceSubtitleGrid.Rows.Cast<DataGridViewRow>()
            .FirstOrDefault(gridRow => ReferenceEquals(gridRow.Tag, currentVoiceSubtitleRow));
        return currentVoiceSubtitleGridRow;
    }

    private void ApplyVoiceSubtitleCurrent()
    {
        if (currentVoiceSubtitleRow == null) return;
        var before = voiceSubtitles.Get(currentVoiceSubtitleRow, "ko_text");
        var after = voiceSubtitleKoBox.Text;
        if (before == after) return;
        voiceSubtitles.Set(currentVoiceSubtitleRow, "ko_text", after);
        var gridRow = CurrentVoiceSubtitleGridRow();
        if (gridRow != null) gridRow.Cells["ko_text"].Value = after;
        UpdateTitle();
    }

    private void MoveVoiceSubtitle(int delta)
    {
        ApplyVoiceSubtitleCurrent();
        if (voiceSubtitleGrid.Rows.Count == 0) return;
        var current = voiceSubtitleGrid.CurrentRow?.Index ?? -1;
        var next = Math.Clamp(current + delta, 0, voiceSubtitleGrid.Rows.Count - 1);
        var row = voiceSubtitleGrid.Rows[next];
        voiceSubtitleGrid.ClearSelection();
        row.Selected = true;
        voiceSubtitleGrid.CurrentCell = row.Cells[0];
        SelectVoiceSubtitleRow();
        voiceSubtitleKoBox.Focus();
    }

    /// <summary>고른 자막 줄의 세로 자리를 정한다.  빈칸이면 기본값(중간).</summary>
    private void SetSelectedVoicePos(string pos)
    {
        var rows = voiceSubtitleGrid.SelectedRows.Cast<DataGridViewRow>()
            .Select(r => r.Tag).OfType<List<string>>().ToList();
        if (rows.Count == 0 && voiceSubtitleGrid.CurrentRow?.Tag is List<string> one) rows.Add(one);
        if (rows.Count == 0) { voiceSummary.Text = "먼저 자막 줄을 고르세요"; return; }
        foreach (var row in rows) voiceSubtitles.Set(row, "pos", pos);
        voiceSubtitles.Dirty = true;
        UpdateTitle();
        RefreshVoiceSubtitles();
        voiceSummary.Text = $"자막 {rows.Count}줄을 '{(pos.Length == 0 ? "기본" : pos)}' 자리로";
    }

    private void AddVoiceSubtitle()
    {
        var eventId = SelectedVoiceEventId();
        if (eventId.Length == 0) { MessageBox.Show("먼저 왼쪽에서 음성 이벤트를 선택하세요."); return; }
        if (voiceEventGrid.SelectedRows.Count > 0 && voiceEventGrid.SelectedRows[0].Tag is List<string> voiceRow
            && !voiceEvents.Get(voiceRow, "kind").Equals("대사", StringComparison.OrdinalIgnoreCase))
        {
            MessageBox.Show("구분을 ‘대사’로 지정한 음성에만 자막을 추가할 수 있습니다. 효과음·기타는 수집만 유지됩니다.");
            return;
        }
        var existing = voiceSubtitles.Rows.Where(r => voiceSubtitles.Get(r, "event_id") == eventId).OrderBy(r => ParseInt(voiceSubtitles.Get(r, "part"), 0)).ToList();
        var start = 0.0;
        if (existing.Count > 0)
        {
            var last = existing[^1];
            start = ParseDouble(voiceSubtitles.Get(last, "start_sec")) + ParseDouble(voiceSubtitles.Get(last, "duration_sec")) + ParseDouble(voiceSubtitles.Get(last, "gap_after_sec"));
        }
        var row = Enumerable.Repeat("", voiceSubtitles.Headers.Count).ToList();
        voiceSubtitles.Set(row, "event_id", eventId);
        voiceSubtitles.Set(row, "part", (existing.Count + 1).ToString());
        voiceSubtitles.Set(row, "start_sec", start.ToString("0.000"));
        var eventDuration = SelectedVoiceDuration();
        var suggestedDuration = eventDuration > start ? Math.Min(2.5, eventDuration - start) : 2.5;
        voiceSubtitles.Set(row, "duration_sec", Math.Max(0.1, suggestedDuration).ToString("0.000"));
        voiceSubtitles.Set(row, "gap_after_sec", "0.000");
        voiceSubtitles.Set(row, "status", "draft");
        voiceSubtitles.Rows.Add(row); voiceSubtitles.Dirty = true;
        RefreshVoiceSubtitles(); UpdateTitle();
        if (voiceSubtitleGrid.Rows.Count > 0)
        {
            var target = voiceSubtitleGrid.Rows[^1];
            voiceSubtitleGrid.ClearSelection();
            target.Selected = true;
            voiceSubtitleGrid.CurrentCell = target.Cells[0];
            SelectVoiceSubtitleRow();
            voiceSubtitleKoBox.Focus();
            voiceSubtitleKoBox.SelectAll();
        }
        voiceSummary.Text = $"음성 {voiceEvents.Rows.Count}건 · 자막 {voiceSubtitles.Rows.Count}줄";
    }

    private void DeleteVoiceSubtitle()
    {
        if (voiceSubtitleGrid.SelectedRows.Count == 0) return;
        if (voiceSubtitleGrid.SelectedRows[0].Tag is not List<string> row) return;
        var eventId = voiceSubtitles.Get(row, "event_id");
        if (ReferenceEquals(row, currentVoiceSubtitleRow)) { currentVoiceSubtitleRow = null; currentVoiceSubtitleGridRow = null; }
        voiceSubtitles.Rows.Remove(row);
        var remaining = voiceSubtitles.Rows.Where(r => voiceSubtitles.Get(r, "event_id") == eventId).OrderBy(r => ParseInt(voiceSubtitles.Get(r, "part"), 0)).ToList();
        for (var i = 0; i < remaining.Count; i++) voiceSubtitles.Set(remaining[i], "part", (i + 1).ToString());
        voiceSubtitles.Dirty = true; RefreshVoiceSubtitles(); UpdateTitle();
    }

    private void UpdateVoiceSubtitle(int rowIndex, int columnIndex)
    {
        // 타임라인에서 끄는 중이면 값은 이미 WriteSpanTimes 가 넣었다.  여기서
        // 다시 전체 갱신을 돌리면 잡고 있던 블록이 사라진다.
        if (draggingSubtitleBlock) return;
        if (rowIndex < 0 || columnIndex < 0 || rowIndex >= voiceSubtitleGrid.Rows.Count) return;
        if (voiceSubtitleGrid.Rows[rowIndex].Tag is not List<string> row) return;
        var column = voiceSubtitleGrid.Columns[columnIndex].Name;
        voiceSubtitles.Set(row, column, Convert.ToString(voiceSubtitleGrid.Rows[rowIndex].Cells[columnIndex].Value) ?? "");
        ValidateVoiceSubtitleTimeline();
        RefreshVoiceTimeline();
        UpdateTitle();
    }

    private double SelectedVoiceDuration()
    {
        if (voiceEventGrid.SelectedRows.Count == 0) return 0;
        var detected = ParseDouble(Convert.ToString(voiceEventGrid.SelectedRows[0].Cells["detected_duration"].Value) ?? "");
        // ★ 2026-09-05.  CD-DA 와 같은 병이 ADPCM 에도 있다.  `detected_duration`
        //   은 계측이라 클립 파일보다 짧을 수 있고, 실제로 세 건은 **0.000** 이라
        //   타임라인이 0.01 초로 접혀 싱크를 아예 걸 수 없었다 (k005922 16.4 초 ·
        //   k005381 4.6 초 · k006835 3.8 초.  뒤 둘은 한국어를 이미 써 둔 채였다).
        //   그러니 클립 WAV 가 더 길면 그쪽을 쓴다.
        var wav = SelectedVoiceWavPath();
        return wav == null ? detected : Math.Max(detected, WavLengthSeconds(wav));
    }

    /// <summary>고른 행의 클립 WAV 경로.  없으면 null.</summary>
    private string? SelectedVoiceWavPath()
    {
        if (voiceEventGrid.SelectedRows.Count == 0) return null;
        if (voiceEventGrid.SelectedRows[0].Tag is not List<string> row) return null;
        var clip = voiceEvents.Get(row, "clip_file");
        if (clip.Length == 0) return null;
        return Path.Combine(root, "logs", "voice_clips_wav",
                            Path.GetFileNameWithoutExtension(clip) + ".wav");
    }

    /// <summary>WAV 헤더만 읽어 길이(초)를 잰다.  못 읽으면 0.</summary>
    /// <remarks>
    /// 왜 헤더를 직접 읽나 -- 타임라인 폭은 **재생을 누르기 전에** 필요하다
    /// (RefreshCddaTimeline 이 목록을 고를 때마다 부른다).  ClipPlayer 의
    /// LengthSeconds 는 MCI 로 연 다음에야 나오므로 그때는 늦다.  RIFF 는
    /// 청크 몇 개만 훑으면 되니 여는 값이 싸고, 같은 파일은 캐시해 둔다.
    /// </remarks>
    private readonly Dictionary<string, double> wavLengthCache = new(StringComparer.OrdinalIgnoreCase);

    private double WavLengthSeconds(string path)
    {
        if (wavLengthCache.TryGetValue(path, out var cached)) return cached;
        double seconds = 0;
        try
        {
            using var stream = File.OpenRead(path);
            using var reader = new BinaryReader(stream);
            if (new string(reader.ReadChars(4)) == "RIFF")
            {
                reader.ReadUInt32();                                 // 파일 크기 - 8
                if (new string(reader.ReadChars(4)) == "WAVE")
                {
                    uint byteRate = 0;
                    while (stream.Position + 8 <= stream.Length)
                    {
                        var id = new string(reader.ReadChars(4));
                        var size = reader.ReadUInt32();
                        var next = stream.Position + size + (size & 1);   // 청크는 짝수 정렬
                        if (id == "fmt " && size >= 16)
                        {
                            reader.ReadUInt16(); reader.ReadUInt16();     // format · channels
                            reader.ReadUInt32();                          // sample rate
                            byteRate = reader.ReadUInt32();
                        }
                        else if (id == "data")
                        {
                            if (byteRate > 0) seconds = size / (double)byteRate;
                            break;
                        }
                        if (next <= stream.Position || next > stream.Length) break;
                        stream.Position = next;
                    }
                }
            }
        }
        catch { seconds = 0; }       // 없거나 깨졌으면 바깥이 TSV 값을 그대로 쓴다
        wavLengthCache[path] = seconds;
        return seconds;
    }

    private void ValidateVoiceSubtitleTimeline()
    {
        var eventId = SelectedVoiceEventId();
        var eventDuration = SelectedVoiceDuration();
        var maxEnd = 0.0;
        var invalid = 0;

        foreach (DataGridViewRow gridRow in voiceSubtitleGrid.Rows)
        {
            var start = ParseDouble(Convert.ToString(gridRow.Cells["start_sec"].Value) ?? "");
            var duration = ParseDouble(Convert.ToString(gridRow.Cells["duration_sec"].Value) ?? "");
            var end = start + duration;
            maxEnd = Math.Max(maxEnd, end);
            var exceeds = start < 0 || duration <= 0 || (eventDuration > 0 && end > eventDuration + 0.0005);
            gridRow.DefaultCellStyle.BackColor = exceeds ? Theme.RowOverLimit : Theme.RowDefault;
            gridRow.DefaultCellStyle.SelectionBackColor = exceeds ? Theme.SelectOverLimit : Theme.Selection;
            gridRow.DefaultCellStyle.SelectionForeColor = Color.White;
            if (exceeds) invalid++;
        }

        if (eventId.Length == 0)
        {
            selectedVoiceSummary.Text = "왼쪽에서 음성 이벤트를 선택한 뒤 + 자막 추가를 누르세요.";
            selectedVoiceSummary.ForeColor = Theme.TextMuted;
            return;
        }

        var durationText = eventDuration > 0 ? $"{eventDuration:0.000}초" : "미확정";
        selectedVoiceSummary.Text = $"선택 장면 {eventId} · 전체 {durationText} · 자막 {voiceSubtitleGrid.Rows.Count}개 · 마지막 {maxEnd:0.000}초" +
            (invalid > 0 ? $" · 범위 초과 {invalid}개" : "");
        selectedVoiceSummary.ForeColor = invalid > 0 ? Theme.Bad : Theme.Good;
    }

    private void ImportVoiceLog(bool showMessage = true)
    {
        var path = ResolveVoiceLogPath();
        if (!File.Exists(path)) { if (showMessage) MessageBox.Show($"음성 로그가 없습니다.\n{path}"); return; }
        var raw = TsvDocument.Load(path); var imported = 0; var updated = 0;
        var contexts = LoadVoiceContexts();
        var latestSession = raw.Rows.Where(r => raw.Get(r, "event_type") == "START")
            .Select(r => VoiceSession(raw.Get(r, "event_id"))).Where(v => v.Length > 0)
            .OrderBy(v => v, StringComparer.Ordinal).LastOrDefault() ?? "";
        var starts = raw.Rows.Where(r => raw.Get(r, "event_type") == "START").ToList();
        var ends = raw.Rows.Where(r => raw.Get(r, "event_type") == "END").GroupBy(r => raw.Get(r, "event_id")).ToDictionary(g => g.Key, g => g.Last());
        var known = voiceEvents.Rows
            .Where(r => voiceEvents.Get(r, "event_id").Length > 0)
            .GroupBy(r => voiceEvents.Get(r, "event_id"))
            .ToDictionary(g => g.Key, g => g.First());
        foreach (var source in starts)
        {
            var eventId = raw.Get(source, "event_id");
            if (eventId.Length == 0) continue;
            if (!known.TryGetValue(eventId, out var row))
            {
                // 사용자가 "선택 삭제(제외)"로 지운 소리는 event_id가 재사용돼도
                // 다시 만들지 않는다. fingerprint는 오디오 소스 특성에서 나오므로
                // 로그가 재생성돼도 같은 소리면 같은 값이 나온다.
                if (excludedVoiceFingerprints.Contains(VoiceFingerprint(raw, source))) continue;
                row = Enumerable.Repeat("", voiceEvents.Headers.Count).ToList();
                foreach (var pair in new[] { ("event_id", "event_id"), ("sequence", "sequence"), ("start_frame", "frame"), ("audio_type", "audio_type"), ("read_address", "read_address"), ("write_address", "write_address"), ("audio_length", "audio_length"), ("playback_rate", "playback_rate"), ("sector", "sector") })
                    voiceEvents.Set(row, pair.Item1, raw.Get(source, pair.Item2));
                var key = $"{raw.Get(source, "audio_type")}_{raw.Get(source, "read_address")}_{raw.Get(source, "audio_length")}";
                voiceEvents.Set(row, "source_key", key);
                voiceEvents.Set(row, "fingerprint", VoiceFingerprint(raw, source));
                if (VoiceSession(eventId) == latestSession)
                    voiceEvents.Set(row, "context", NearestVoiceContext(ParseInt(raw.Get(source, "frame"), 0), contexts));
                voiceEvents.Set(row, "status", "unlinked");
                voiceEvents.Set(row, "kind", "기타");
                voiceEvents.Rows.Add(row);
                known[eventId] = row;
                imported++;
            }
            // Recompute derived identity/context for existing rows too. This
            // migrates voice events imported by older Studio versions when the
            // user presses "음성 로그 가져오기" again.
            voiceEvents.Set(row, "fingerprint", VoiceFingerprint(raw, source));
            // 0.2.2 부터 원시 로그가 소리 파일 이름을 같이 적는다.  옛 로그에는
            // 없으므로 빈 값이면 덮지 않는다 -- 이미 붙은 것을 지우면 안 된다.
            var clip = raw.Get(source, "clip_file");
            if (clip.Length > 0) voiceEvents.Set(row, "clip_file", clip);
            if (VoiceSession(eventId) == latestSession)
            {
                var context = NearestVoiceContext(ParseInt(raw.Get(source, "frame"), 0), contexts);
                if (context.Length > 0) voiceEvents.Set(row, "context", context);
            }
            if (ends.TryGetValue(eventId, out var end))
            {
                var endFrame = raw.Get(end, "frame");
                var frames = ParseInt(raw.Get(end, "frame"), 0) - ParseInt(raw.Get(source, "frame"), 0);
                var duration = frames >= 0 ? (frames / 60.0).ToString("0.000") : "";
                if (voiceEvents.Get(row, "end_frame") != endFrame || voiceEvents.Get(row, "detected_duration") != duration)
                {
                    voiceEvents.Set(row, "end_frame", endFrame);
                    if (duration.Length > 0) voiceEvents.Set(row, "detected_duration", duration);
                    updated++;
                }
            }
        }
        var merged = ConsolidateVoiceEvents();
        var counts = starts.GroupBy(row => VoiceFingerprint(raw, row), StringComparer.Ordinal)
            .ToDictionary(group => group.Key, group => group.Count(), StringComparer.Ordinal);
        var activeCounts = starts.Where(row => !ends.ContainsKey(raw.Get(row, "event_id")))
            .GroupBy(row => VoiceFingerprint(raw, row), StringComparer.Ordinal)
            .ToDictionary(group => group.Key, group => group.Count(), StringComparer.Ordinal);
        var active = activeCounts.Keys.ToHashSet(StringComparer.Ordinal);
        var occurrenceChanged = false;
        foreach (var row in voiceEvents.Rows)
        {
            var fingerprint = voiceEvents.Get(row, "fingerprint");
            var occurrences = counts.TryGetValue(fingerprint, out var count) ? count.ToString() : "0";
            var activeCount = activeCounts.TryGetValue(fingerprint, out var current) ? current.ToString() : "";
            if (voiceEvents.Get(row, "occurrences") != occurrences || voiceEvents.Get(row, "active_count") != activeCount)
                occurrenceChanged = true;
            voiceEvents.Set(row, "occurrences", occurrences);
            voiceEvents.Set(row, "active_count", activeCount);
        }
        // 목록은 파일에 붙은 순서대로 나온다.  그래서 나중에 추가된 종류(CDDA)가
        // 재생 순서상 제일 앞이어도 맨 아래로 밀려 헷갈린다.  event_id 는
        // "세션시각_0000순번" 이라 사전순 정렬이 곧 재생 순서다 -- 세션이 여러 개
        // 섞여 있어도 시간순으로 서고, 한 세션 안에서는 순번이 0 채움이라 정렬이
        // 어긋나지 않는다.
        SortVoiceEventsByPlayOrder();
        if (imported > 0 || updated > 0 || merged > 0 || occurrenceChanged || active.Count > 0)
        {
            voiceEvents.Dirty = true;
            // 가져오기로 clip_file 이 새로 붙은 행에 일본어 원문을 다시 이어준다.
            // LoadVoiceTranscript 는 시작할 때 한 번만 돌므로, 이걸 빼면
            // 가져오기 뒤에 늘어난 행은 일본어가 영영 빈 채로 남는다
            // (실측: 1083 행 중 clip_file 248 · jp_whisper 34).
            LoadVoiceTranscript();
            RefreshVoiceEvents(active);
            UpdateTitle();
        }
        if (showMessage) MessageBox.Show($"새 음성 이벤트 {imported}건 · 종료 정보 갱신 {updated}건 · 중복 병합 {merged}건");
    }

    /// <summary>
    /// 음성 이벤트를 재생 순서로 세운다.  event_id 가 비어 있는 수동 행은 순서를
    /// 알 수 없으므로 뒤로 보내되 서로의 상대 순서는 유지한다.
    /// </summary>
    private void SortVoiceEventsByPlayOrder()
    {
        var ordered = voiceEvents.Rows
            .Select((row, index) => (row, index))
            .OrderBy(item => voiceEvents.Get(item.row, "event_id").Length == 0 ? 1 : 0)
            .ThenBy(item => voiceEvents.Get(item.row, "event_id"), StringComparer.Ordinal)
            .ThenBy(item => item.index)
            .Select(item => item.row)
            .ToList();
        if (ordered.SequenceEqual(voiceEvents.Rows)) return;
        voiceEvents.Rows.Clear();
        voiceEvents.Rows.AddRange(ordered);
        voiceEvents.Dirty = true;
    }

    private int ConsolidateVoiceEvents()
    {
        var removed = 0;
        var groups = voiceEvents.Rows
            .Where(row => voiceEvents.Get(row, "fingerprint").Length > 0)
            .GroupBy(row => voiceEvents.Get(row, "fingerprint"), StringComparer.Ordinal)
            .Where(group => group.Count() > 1)
            .ToList();

        foreach (var group in groups)
        {
            var rows = group.ToList();
            var representative = rows[0];
            var representativeId = voiceEvents.Get(representative, "event_id");

            foreach (var duplicate in rows.Skip(1))
            {
                // Keep the newest useful runtime metadata while preserving any
                // scene/status/note that the user already assigned.
                foreach (var column in new[] { "end_frame", "detected_duration", "context" })
                {
                    var value = voiceEvents.Get(duplicate, column);
                    if (value.Length > 0) voiceEvents.Set(representative, column, value);
                }
                foreach (var column in new[] { "scene_id", "note" })
                {
                    if (voiceEvents.Get(representative, column).Length == 0)
                        voiceEvents.Set(representative, column, voiceEvents.Get(duplicate, column));
                }
                var duplicateStatus = voiceEvents.Get(duplicate, "status");
                if (voiceEvents.Get(representative, "status") is "" or "unlinked"
                    && duplicateStatus.Length > 0 && duplicateStatus != "unlinked")
                    voiceEvents.Set(representative, "status", duplicateStatus);

                var duplicateId = voiceEvents.Get(duplicate, "event_id");
                foreach (var subtitle in voiceSubtitles.Rows.Where(row =>
                    voiceSubtitles.Get(row, "event_id").Equals(duplicateId, StringComparison.Ordinal)))
                    voiceSubtitles.Set(subtitle, "event_id", representativeId);

                voiceEvents.Rows.Remove(duplicate);
                removed++;
            }
        }

        if (removed > 0)
        {
            voiceEvents.Dirty = true;
            voiceSubtitles.Dirty = true;
        }
        return removed;
    }

    private List<(int Frame, string Text)> LoadVoiceContexts()
    {
        var path = Path.Combine(ResolveAuditDirectory(), RuntimeAuditFileName);
        if (!File.Exists(path)) return new();
        try
        {
            var raw = AuditEngine.LoadRuntimeAudit(path);
            return raw.Rows.Select(row => (
                    ParseInt(raw.Get(row, "frame"), 0),
                    AuditEngine.DecodeSource(raw.Get(row, "source_hex"))))
                .Where(item => item.Item1 > 0 && item.Item2.Length > 0)
                .OrderBy(item => item.Item1).ToList();
        }
        catch { return new(); }
    }

    private static string NearestVoiceContext(int frame, List<(int Frame, string Text)> contexts)
    {
        var nearest = contexts.OrderBy(item => Math.Abs(item.Frame - frame)).FirstOrDefault();
        if (nearest == default || Math.Abs(nearest.Frame - frame) > 600) return "";
        var direction = nearest.Frame <= frame ? "직전" : "직후";
        return $"{direction} {Math.Abs(nearest.Frame - frame) / 60.0:0.0}초: {nearest.Text}";
    }

    private static string VoiceSession(string eventId)
    {
        var match = Regex.Match(eventId ?? "", @"^(\d{8}_\d{6})_");
        return match.Success ? match.Groups[1].Value : "";
    }

    /// <summary>
    /// 같은 소리를 한 이벤트로 묶는 값.
    ///
    /// 소리 파일 이름이 있으면 그것을 쓴다.  runtime_text_audit 0.2.2 가 재생 시작
    /// 순간의 ADPCM RAM 을 그대로 뜨면서 **내용에서** 지은 이름이라, 같은 대사면
    /// 세션이 달라도 같은 값이다.
    ///
    /// 옛 방식(read_address + audio_length)은 틀렸다.  그 두 값은 세션마다 몇
    /// 바이트씩 흔들린다 -- 2026-08-20 실측으로 같은 대사가 이렇게 잡혔다:
    ///
    ///     15:08  read=006D  len=6793          15:15  read=006B  len=6795
    ///     15:08  read=0064  len=579C          15:15  read=0066  len=579A
    ///
    /// 끝(write_address)은 고정이고 시작만 밀린다.  그래서 옛 지문은 같은 대사를
    /// 매번 새 이벤트로 만들었고 occurrences 가 실제 재생 횟수와 어긋났다.
    ///
    /// 파일 이름이 없는 행(0.2.2 이전 로그, CD-DA)은 옛 방식으로 되돌아간다.
    /// </summary>
    private static string VoiceFingerprint(TsvDocument raw, List<string> row)
    {
        var clip = raw.Get(row, "clip_file");
        if (clip.Length > 0) return clip;
        static int Hex(string value) => int.TryParse(value, System.Globalization.NumberStyles.HexNumber, null, out var result) ? result : 0;
        var read = Hex(raw.Get(row, "read_address"));
        var length = Hex(raw.Get(row, "audio_length"));
        return $"{raw.Get(row, "audio_type")}_{read:X4}_{length:X4}_{raw.Get(row, "playback_rate")}";
    }

    private void BuildMasterTab(TabPage page)
    {
        var toolbar = new FlowLayoutPanel { Dock = DockStyle.Top, Height = 42, Padding = new Padding(7), WrapContents = false };
        toolbar.Controls.AddRange(new Control[] { new Label { Text = "검색", AutoSize = true, Padding = new Padding(0, 7, 0, 0) }, searchBox,
            new Label { Text = "장면", AutoSize = true, Padding = new Padding(8, 7, 0, 0) }, sceneFilter,
            new Label { Text = "필터", AutoSize = true, Padding = new Padding(8, 7, 0, 0) }, rowFilter,
            sceneOrderButton, Button("전체 목록에서 위치", (_, _) => RevealSelectedMasterInAllRows()),
            Button("저장 Ctrl+S", (_, _) => SaveAll()), summaryLabel });
        masterSearchDebounce.Tick += (_, _) => { masterSearchDebounce.Stop(); RefreshMasterGrid(); };
        searchBox.TextChanged += (_, _) => { masterSearchDebounce.Stop(); masterSearchDebounce.Start(); };
        searchBox.KeyDown += (_, e) =>
        {
            if (e.KeyCode != Keys.Enter) return;
            RevealSelectedMasterInAllRows();
            e.SuppressKeyPress = true;
        };
        sceneFilter.SelectedIndexChanged += (_, _) => RefreshMasterGrid();
        sceneOrderButton.Click += (_, _) =>
        {
            orderMasterByScene = !orderMasterByScene;
            sceneOrderButton.Text = orderMasterByScene ? "장면 순서: 정렬" : "장면 순서: 원본";
            RefreshMasterGrid();
        };
        rowFilter.Width = 175;
        rowFilter.Items.AddRange(new object[] {
            "전체", "미검토", "검토 O", "번역 없음", "18칸 초과", "예외처리", "조용한 통일", "중복 번역 충돌", "FE 확인",
            "초록 · 신규 누락", "주황 · LOOKUP_FAIL", "보라 · ROUTE_FAIL", "청회 · MASTER_ONLY",
            "분홍 · 18칸 초과", "노랑 · 중복 충돌", "하늘 · FE 확인"
        });

        var scenes = master.Rows.Select(r => SceneOf(master.Get(r, "source_refs"))).Where(v => v.Length > 0).SelectMany(v => v.Split(',')).Distinct().OrderBy(v => v).ToArray();
        sceneFilter.Items.Add("전체"); sceneFilter.Items.AddRange(scenes);

        masterGrid.Columns.Add("key", "text_key"); masterGrid.Columns.Add("line", "행"); masterGrid.Columns.Add("scene", "장면"); masterGrid.Columns.Add("chapter", "팩 분류");
        // 화자는 런타임 수집에서 귀속된다.  아직 지나가지 않은 구간은 비어 있다.
        masterGrid.Columns.Add("speaker", "화자");
        masterGrid.Columns.Add("jp", "일본어"); masterGrid.Columns.Add("ko", "한국어"); masterGrid.Columns.Add("control", "후속");
        masterGrid.Columns.Add("audit", "감사 상태"); masterGrid.Columns.Add("review", "검토"); masterGrid.Columns.Add("root", "문맥");
        masterGrid.Columns[0].Width = 125; masterGrid.Columns[1].Width = 42; masterGrid.Columns[2].Width = 72;
        masterGrid.Columns[3].Width = 90; masterGrid.Columns[4].Width = 70;
        masterGrid.Columns[5].Width = 280; masterGrid.Columns[6].Width = 330; masterGrid.Columns[7].Width = 55;
        masterGrid.Columns[8].Width = 110; masterGrid.Columns[9].Width = 65; masterGrid.Columns[10].Width = 65;
        masterGrid.MultiSelect = true;
        masterGrid.SelectionChanged += (_, _) => SelectMasterRow();
        masterGrid.CellDoubleClick += (_, _) => RevealSelectedMasterInAllRows();
        rowFilter.SelectedIndexChanged += (_, _) => RefreshMasterGrid();
        rowFilter.SelectedIndex = 0;
        sceneFilter.SelectedIndex = 0;

        var right = BuildEditorPanel();
        masterSplit.Panel1.Controls.Add(masterGrid); masterSplit.Panel2.Controls.Add(right);
        page.Controls.Add(masterSplit); page.Controls.Add(toolbar);
    }

    private void SetInitialMasterSplit()
    {
        var width = masterSplit.ClientSize.Width;
        if (width <= masterSplit.SplitterWidth + 2) return;

        // SplitContainer validates minimum sizes against its current width.
        // Set the live distance first, after the form has completed layout,
        // and only then install the panel minimums.
        masterSplit.Panel1MinSize = 0;
        masterSplit.Panel2MinSize = 0;
        var desired = Math.Clamp((int)Math.Round(width * 0.70), 1, width - masterSplit.SplitterWidth - 1);
        masterSplit.SplitterDistance = desired;
        masterSplit.Panel1MinSize = Math.Min(620, desired);
        masterSplit.Panel2MinSize = Math.Min(580, width - desired - masterSplit.SplitterWidth);
    }

    private void SetInitialUiSplit()
    {
        var width = uiSplit.ClientSize.Width;
        if (width <= uiSplit.SplitterWidth + 2) return;
        uiSplit.Panel1MinSize = 0;
        uiSplit.Panel2MinSize = 0;
        var desired = Math.Clamp((int)Math.Round(width * 0.70), 1, width - uiSplit.SplitterWidth - 1);
        uiSplit.SplitterDistance = desired;
        uiSplit.Panel1MinSize = Math.Min(580, desired);
        uiSplit.Panel2MinSize = Math.Min(420, width - desired - uiSplit.SplitterWidth);
    }

    private Control BuildEditorPanel()
    {
        controlBox.Items.AddRange(new object[] { "BR", "PAGE", "CONT", "END" });
        chapterBox.Items.AddRange(new object[] { "", "chapter_1", "chapter_2", "chapter_3", "shared" });
        chapterBox.SelectedIndexChanged += (_, _) => ApplyChapterToCurrentPage();
        var buttons1 = new FlowLayoutPanel { Dock = DockStyle.Top, Height = 38 };
        buttons1.Controls.AddRange(new Control[] {
            Button("{EMPTY} 토글", (_, _) => ToggleEmptyTranslation()),
            Button("행 삭제", (_, _) => DeleteSelectedMasterRows()),
            Button("예외처리", (_, _) => ToggleExceptionReview()),
            Button("문맥 분리", (_, _) => SetAutomaticRootContext()),
            Button("검토 O", (_, _) => SetReview("O")),
            Button("검토 해제", (_, _) => SetReview("")) });
        var colorButtons = new FlowLayoutPanel { Dock = DockStyle.Top, Height = 38 };
        colorButtons.Controls.AddRange(new Control[] {
            new Label { Text = "글자색 (0칸)", AutoSize = true, Padding = new Padding(0, 7, 4, 0) },
            Button("… 1칸", (_, _) => InsertTranslationToken("…")),
            Button("{FE:0}", (_, _) => InsertTranslationToken("{FE:0}")),
            Button("{FE:1}", (_, _) => InsertTranslationToken("{FE:1}")),
            Button("{FE:2}", (_, _) => InsertTranslationToken("{FE:2}")),
            Button("{FE:3}", (_, _) => InsertTranslationToken("{FE:3}")),
            Button("{FE:4}", (_, _) => InsertTranslationToken("{FE:4}")),
            Button("{FE:6}", (_, _) => InsertTranslationToken("{FE:6}")) });
        var options = new FlowLayoutPanel { Dock = DockStyle.Top, Height = 38 };
        options.Controls.AddRange(new Control[] { new Label { Text = "후속 (읽기 전용)", AutoSize = true, Padding = new Padding(0, 7, 0, 0) }, controlBox });
        var chapterOptions = new FlowLayoutPanel { Dock = DockStyle.Top, Height = 38 };
        chapterOptions.Controls.AddRange(new Control[] {
            new Label { Text = "팩 분류", AutoSize = true, Padding = new Padding(0, 7, 0, 0) }, chapterBox,
            new Label { Text = "같은 text_key 전체에 적용", AutoSize = true, Padding = new Padding(8, 7, 0, 0) }
        });
        // The gauge now reports four numbers and up to five warnings, which no
        // longer fits beside the control box -- give it its own row.
        var metricRow = new Panel { Dock = DockStyle.Top, Height = 24 };
        metricLabel.Dock = DockStyle.Fill;
        metricLabel.TextAlign = ContentAlignment.MiddleLeft;
        metricLabel.AutoSize = false;
        metricRow.Controls.Add(metricLabel);
        var nav = new FlowLayoutPanel { Dock = DockStyle.Top, Height = 38 };
        nav.Controls.AddRange(new Control[] { Button("◀ 이전", (_, _) => MoveRow(-1)), Button("적용 후 다음 ▶", (_, _) => MoveRow(1)) });
        koBox.TextChanged += (_, _) => UpdateMetrics();

        var duplicatesGroup = new GroupBox { Text = "같은 일본어 · 번역 일치 검사", Dock = DockStyle.Fill };
        // 같은 원문이 여러 행에 흩어져 있으면(실측 251종 744행) 한 줄씩 찍는 대신
        // 여기서 골라 한 번에 처리한다.  Ctrl/Shift 로 여러 개 선택된다.
        duplicateList.SelectionMode = SelectionMode.MultiExtended;
        var duplicateButtons = new FlowLayoutPanel { Dock = DockStyle.Bottom, Height = 36 };
        duplicateButtons.Controls.AddRange(new Control[]
        {
            Button("선택 검토 O", (_, _) => SetReviewForSelectedDuplicates("O")),
            Button("선택 검토 해제", (_, _) => SetReviewForSelectedDuplicates("")),
            Button("선택에 이 번역 적용", (_, _) => ApplyKoreanToSelectedDuplicates()),
        });
        // Dock 은 Controls 인덱스 역순으로 적용된다 -- 인덱스 0 이 가장 안쪽이다.
        // 리스트를 먼저 넣어야 버튼 줄이 바닥을 차지하고 리스트가 나머지를 채운다.
        duplicatesGroup.Controls.Add(duplicateList);
        duplicatesGroup.Controls.Add(duplicateButtons);
        duplicateList.DoubleClick += (_, _) => OpenSelectedDuplicate();
        var contextGroup = new GroupBox { Text = "같은 text_key 문맥", Dock = DockStyle.Top, Height = 150 };
        contextGroup.Controls.Add(contextBox);
        var editor = new Panel { Dock = DockStyle.Fill, Padding = new Padding(8) };
        editor.Controls.Add(duplicatesGroup); editor.Controls.Add(contextGroup); editor.Controls.Add(nav); editor.Controls.Add(buttons1); editor.Controls.Add(colorButtons); editor.Controls.Add(metricRow); editor.Controls.Add(options); editor.Controls.Add(chapterOptions);
        editor.Controls.Add(koBox); editor.Controls.Add(new Label { Text = "한국어 번역", Dock = DockStyle.Top, Height = 23 });
        editor.Controls.Add(jpBox); editor.Controls.Add(new Label { Text = "일본어 원문 (수정 금지)", Dock = DockStyle.Top, Height = 23 });
        editor.Controls.Add(identityLabel); identityLabel.Dock = DockStyle.Top; identityLabel.Height = 28;
        return editor;
    }

    private void BuildAuditTab(TabPage page)
    {
        var toolbar = new FlowLayoutPanel { Dock = DockStyle.Top, Height = 45, Padding = new Padding(7), WrapContents = false };
        var patchRoot = Path.Combine(ResolveHomeProjectRoot() ?? root, "build", "patch");
        if (Directory.Exists(patchRoot))
            foreach (var dir in Directory.GetDirectories(patchRoot).OrderByDescending(VersionKey))
                if (File.Exists(Path.Combine(dir, "direct_records.tsv"))) buildVersion.Items.Add(Path.GetFileName(dir));
        if (buildVersion.Items.Count > 0) buildVersion.SelectedIndex = 0;
        auditCategory.Items.AddRange(new object[] { "전체", "기술 문제", "번역 큐", "LOOKUP_FAIL", "ROUTE_FAIL", "MASTER_ONLY", "NEAR", "MISS" }); auditCategory.SelectedIndex = 0;
        auditCategory.SelectedIndexChanged += (_, _) => RefreshAuditGrid();
        var includeDialogue = Button("대사 포함 (비활성)", (_, _) => IncludeSelectedAudit());
        includeDialogue.Enabled = false;
        toolbar.Controls.AddRange(new Control[] { new Label { Text = "검수 빌드", AutoSize = true, Padding = new Padding(0, 7, 0, 0) }, buildVersion,
            Button("로그 분석", (_, _) => AnalyzeAudit(false)), Button("통합 실시간 감시", (_, _) => StartAuditWatch()), Button("감시 중지", (_, _) => StopAuditWatch()),
            Button("세션 로그 삭제", (_, _) => ClearAuditSessionLog()),
            new Label { Text = "분류", AutoSize = true, Padding = new Padding(8, 7, 0, 0) }, auditCategory,
            includeDialogue,
            Button("번역 큐 내보내기", (_, _) => ExportTranslationQueue()), Button("Lua 위치 열기", (_, _) => OpenPath(ResolveAuditLuaDirectory())), auditSummary });

        auditGrid.Columns.Add("class", "분류"); auditGrid.Columns.Add("target", "대상"); auditGrid.Columns.Add("count", "횟수"); auditGrid.Columns.Add("seq", "최초 순서"); auditGrid.Columns.Add("scene", "장면");
        auditGrid.Columns.Add("jp", "런타임 일본어"); auditGrid.Columns.Add("control", "후속"); auditGrid.Columns.Add("ko", "예상 한국어"); auditGrid.Columns.Add("state", "상태"); auditGrid.Columns.Add("refs", "참조"); auditGrid.Columns.Add("action", "조치");
        auditGrid.Columns[0].Width = 110; auditGrid.Columns[1].Width = 55; auditGrid.Columns[2].Width = 65; auditGrid.Columns[3].Width = 80;
        auditGrid.Columns[0].Width = 110; auditGrid.Columns[1].Width = 70; auditGrid.Columns[2].Width = 55; auditGrid.Columns[3].Width = 65; auditGrid.Columns[4].Width = 80;
        auditGrid.Columns[5].Width = 300; auditGrid.Columns[6].Width = 58; auditGrid.Columns[7].Width = 280; auditGrid.Columns[8].Width = 65; auditGrid.Columns[9].Width = 220; auditGrid.Columns[10].Width = 300;
        page.Controls.Add(auditGrid); page.Controls.Add(toolbar);
        auditDebounce.Tick += (_, _) => { auditDebounce.Stop(); AnalyzeAudit(true); };
        voiceDebounce.Tick += (_, _) => { voiceDebounce.Stop(); ImportVoiceLog(false); };
        uiDebounce.Tick += (_, _) => { uiDebounce.Stop(); ImportRuntimeUiCapture(false); };
    }

    private void PopulateStaticTables()
    {
        PopulateStaticPage(speakerPage, speakerGrid, speakers, "speaker_id", "jp_name", "ko_name", "status", "note");
        RefreshUiGrid();
    }

    // The UI data editor intentionally has no dependency on the experimental
    // in-game UI patch. It only edits translation/ui_text.tsv.
    private void BuildUiTab(TabPage page)
    {
        var toolbar = new FlowLayoutPanel { Dock = DockStyle.Top, Height = 42, Padding = new Padding(7), WrapContents = false };
        toolbar.Controls.AddRange(new Control[] {
            new Label { Text = "검색", AutoSize = true, Padding = new Padding(0, 7, 0, 0) },
            uiSearchBox,
            Button("전체 목록에서 위치", (_, _) => RevealSelectedUiInAllRows()),
            Button("저장 Ctrl+S", (_, _) => SaveAll()),
            new Label { Text = "UI 제한: 8칸", AutoSize = true, Padding = new Padding(8, 7, 0, 0) },
            uiSummaryLabel
        });
        uiSearchDebounce.Tick += (_, _) => { uiSearchDebounce.Stop(); RefreshUiGrid(); };
        uiSearchBox.TextChanged += (_, _) => { uiSearchDebounce.Stop(); uiSearchDebounce.Start(); };
        uiSearchBox.KeyDown += (_, e) =>
        {
            if (e.KeyCode != Keys.Enter) return;
            RevealSelectedUiInAllRows();
            e.SuppressKeyPress = true;
        };

        uiGrid.Columns.Clear();
        uiGrid.Columns.Add("ui_id", "UI ID");
        uiGrid.Columns.Add("category", "분류");
        uiGrid.Columns.Add("jp_text", "일본어 UI");
        uiGrid.Columns.Add("ko_text", "한국어 번역");
        // 칸수 컬럼이 빠져 있어서 Rows.Add 가 넘기는 8 개 값이 7 개 컬럼에 들어갔고,
        // 그 뒤가 전부 한 칸씩 밀렸다 -- 검토 칸에 "2/8", 상태 칸에 검토값 O,
        // 메모 칸에 상태값이 보이고 진짜 메모는 잘려나갔다 (2026-08-20 소유자 보고).
        uiGrid.Columns.Add("cells", "칸");
        uiGrid.Columns.Add("review", "검토");
        uiGrid.Columns.Add("status", "상태");
        uiGrid.Columns.Add("note", "메모");
        uiGrid.Columns["ui_id"].Width = 120;
        uiGrid.Columns["category"].Width = 85;
        uiGrid.Columns["jp_text"].Width = 280;
        uiGrid.Columns["ko_text"].Width = 320;
        uiGrid.Columns["cells"].Width = 48;
        uiGrid.Columns["review"].Width = 58;
        uiGrid.Columns["status"].Width = 85;
        uiGrid.Columns["note"].Width = 260;
        foreach (DataGridViewColumn column in uiGrid.Columns) column.ReadOnly = true;
        uiGrid.MultiSelect = true;
        uiGrid.SelectionChanged += (_, _) => SelectUiRow();
        uiGrid.CellDoubleClick += (_, _) => RevealSelectedUiInAllRows();
        uiKoBox.TextChanged += (_, _) => UpdateUiMetrics();

        var editor = BuildUiEditorPanel();
        uiSplit.Panel1.Controls.Add(uiGrid);
        uiSplit.Panel2.Controls.Add(editor);
        page.Controls.Add(uiSplit);
        page.Controls.Add(toolbar);
    }

    private Control BuildUiEditorPanel()
    {
        var actions = new FlowLayoutPanel { Dock = DockStyle.Top, Height = 42, Padding = new Padding(0, 4, 0, 0) };
        actions.Controls.AddRange(new Control[] {
            Button("적용", (_, _) => ApplyUiCurrent()),
            Button("적용 후 다음 ▶", (_, _) => ApplyUiAndMoveNext()),
            Button("검토 O", (_, _) => SetUiReview("O")),
            Button("검토 해제", (_, _) => SetUiReview(""))
        });
        var metric = new Panel { Dock = DockStyle.Top, Height = 34 };
        metric.Controls.Add(uiMetricLabel);

        var editor = new Panel { Dock = DockStyle.Fill, Padding = new Padding(8) };
        editor.Controls.Add(actions);
        editor.Controls.Add(metric);
        editor.Controls.Add(uiKoBox);
        editor.Controls.Add(new Label { Text = "한국어 번역", Dock = DockStyle.Top, Height = 23 });
        editor.Controls.Add(uiJpBox);
        editor.Controls.Add(new Label { Text = "일본어 원문 (수정 금지)", Dock = DockStyle.Top, Height = 23 });
        editor.Controls.Add(uiIdentityLabel); uiIdentityLabel.Dock = DockStyle.Top; uiIdentityLabel.Height = 28;
        return editor;
    }

    private void RefreshUiGrid()
    {
        if (uiGrid.Columns.Count == 0) return;
        ApplyUiCurrent();
        var query = uiSearchBox.Text.Trim();
        loadingStatic = true;
        uiGrid.Rows.Clear();
        var shown = 0;
        var overLimit = 0;
        foreach (var row in ui.Rows)
        {
            if (query.Length > 0 && !string.Join(" ", row).Contains(query, StringComparison.OrdinalIgnoreCase)) continue;
            var ko = ui.Get(row, "ko_text");
            var cells = WidestLineCells(ko);
            var gridRow = uiGrid.Rows.Add(
                ui.Get(row, "ui_id"), ui.Get(row, "category"), ui.Get(row, "jp_text"), ko,
                $"{CellsText(cells)}/8", ui.Get(row, "review"), ui.Get(row, "status"), ui.Get(row, "note"));
            uiGrid.Rows[gridRow].Tag = row;
            if (cells > 8)
            {
                overLimit++;
                uiGrid.Rows[gridRow].DefaultCellStyle.BackColor = Theme.RowOverLimit;
            }
            else if (ko.Trim().Length > 0)
            {
                uiGrid.Rows[gridRow].DefaultCellStyle.BackColor = Theme.RowComplete;
            }
            shown++;
        }
        loadingStatic = false;
        var reviewed = ui.Rows.Count(row => ui.Get(row, "review").Equals("O", StringComparison.OrdinalIgnoreCase));
        uiSummaryLabel.Text = $"표시 {shown}/{ui.Rows.Count} · 검토 O {reviewed}/{ui.Rows.Count} · 8칸 초과 {overLimit}";
        var selected = uiGrid.Rows.Cast<DataGridViewRow>()
            .FirstOrDefault(gridRow => ReferenceEquals(gridRow.Tag, currentUiRow));
        if (selected == null && uiGrid.Rows.Count > 0) selected = uiGrid.Rows[0];
        if (selected != null)
        {
            selected.Selected = true;
            uiGrid.CurrentCell = selected.Cells[0];
            SelectUiRow();
        }
    }

    private void SelectUiRow()
    {
        if (loadingStatic || uiGrid.SelectedRows.Count == 0 || uiGrid.SelectedRows[0].Tag is not List<string> source) return;
        if (ReferenceEquals(currentUiRow, source)) return;
        ApplyUiCurrent();
        currentUiRow = source;
        uiIdentityLabel.Text = $"{ui.Get(source, "ui_id")} · {ui.Get(source, "category")}";
        uiJpBox.Text = ui.Get(source, "jp_text");
        uiKoBox.Text = ui.Get(source, "ko_text");
        UpdateUiMetrics();
    }

    // "적용 후 다음" 은 992행 그리드를 매번 처음부터 훑어 현재 행을 찾고 있었다.
    // 한 행 넘길 때마다 ApplyUiCurrent / SetUiReview 가 각각 훑으므로 체감이 크다.
    // 화면 행을 캐시해 두고, 캐시가 어긋났을 때만(RefreshUiGrid 등) 다시 찾는다.
    private DataGridViewRow? currentUiGridRow;

    private DataGridViewRow? CurrentUiGridRow()
    {
        if (currentUiRow == null) return null;
        var cached = currentUiGridRow;
        if (cached != null && cached.DataGridView == uiGrid && cached.Index >= 0
            && ReferenceEquals(cached.Tag, currentUiRow)) return cached;
        currentUiGridRow = uiGrid.Rows.Cast<DataGridViewRow>()
            .FirstOrDefault(gridRow => ReferenceEquals(gridRow.Tag, currentUiRow));
        return currentUiGridRow;
    }

    private void ApplyUiCurrent()
    {
        if (currentUiRow == null) return;
        var before = ui.Get(currentUiRow, "ko_text");
        var after = uiKoBox.Text;
        if (before == after) return;
        ui.Set(currentUiRow, "ko_text", after);
        var cells = WidestLineCells(after);
        var gridRow = CurrentUiGridRow();
        if (gridRow != null)
        {
            gridRow.Cells["ko_text"].Value = after;
            gridRow.DefaultCellStyle.BackColor = cells > 8 ? Theme.RowOverLimit : after.Trim().Length > 0 ? Theme.RowComplete : Theme.RowDefault;
        }
        UpdateTitle();
        UpdateUiMetrics();
    }

    private void ApplyUiAndMoveNext()
    {
        ApplyUiCurrent();
        if (uiGrid.Rows.Count == 0) return;
        var current = uiGrid.CurrentRow?.Index ?? -1;
        var next = Math.Clamp(current + 1, 0, uiGrid.Rows.Count - 1);
        var row = uiGrid.Rows[next];
        uiGrid.ClearSelection();
        row.Selected = true;
        uiGrid.CurrentCell = row.Cells[0];
        uiGrid.FirstDisplayedScrollingRowIndex = Math.Max(0, row.Index - 3);
        SelectUiRow();
        uiKoBox.Focus();
    }

    // Mirrors the master tab: the grid allows multi-select, so apply the value
    // to every selected row.  Only the grid cells of rows that actually changed
    // are repainted -- there is no filter here whose membership could shift, so
    // a full rebuild is never needed.
    private void SetUiReview(string value)
    {
        if (uiGrid.SelectedRows.Count == 0 && currentUiRow == null) return;
        ApplyUiCurrent();

        var targets = uiGrid.SelectedRows.Cast<DataGridViewRow>()
            .Where(gridRow => gridRow.Tag is List<string>)
            .ToList();
        if (targets.Count == 0)
        {
            var single = CurrentUiGridRow();
            if (single != null) targets.Add(single);
        }

        var changed = 0;
        foreach (var gridRow in targets)
        {
            if (gridRow.Tag is not List<string> row) continue;
            if (ui.Get(row, "review") == value) continue;
            ui.Set(row, "review", value);
            gridRow.Cells["review"].Value = value;
            changed++;
        }
        if (changed == 0) return;

        var reviewed = ui.Rows.Count(row => ui.Get(row, "review").Equals("O", StringComparison.OrdinalIgnoreCase));
        uiSummaryLabel.Text = Regex.Replace(uiSummaryLabel.Text, @"검토 O [0-9,]+/[0-9,]+", $"검토 O {reviewed}/{ui.Rows.Count}");
        UpdateTitle();
    }

    private void RevealSelectedUiInAllRows()
    {
        var target = uiGrid.SelectedRows.Count > 0 && uiGrid.SelectedRows[0].Tag is List<string> selected
            ? selected
            : currentUiRow;
        if (target == null) return;
        ApplyUiCurrent();
        uiSearchBox.Text = "";
        uiSearchDebounce.Stop();
        RefreshUiGrid();
        foreach (DataGridViewRow gridRow in uiGrid.Rows)
        {
            if (!ReferenceEquals(gridRow.Tag, target)) continue;
            uiGrid.ClearSelection();
            gridRow.Selected = true;
            uiGrid.CurrentCell = gridRow.Cells[0];
            uiGrid.FirstDisplayedScrollingRowIndex = Math.Max(0, gridRow.Index - 3);
            SelectUiRow();
            break;
        }
    }

    private void UpdateUiMetrics()
    {
        if (currentUiRow == null) return;
        var cells = DisplayCells(uiKoBox.Text);
        var okay = cells <= 8;
        uiMetricLabel.Text = $"{CellsText(cells)}/8칸 · 약 {ApproxBytes(uiKoBox.Text)}바이트 · {(okay ? "OK" : $"초과 +{CellsText(cells - 8)}")}";
        uiMetricLabel.ForeColor = okay ? Theme.Good : Theme.Bad;
    }

    private void PopulateStaticPage(TabPage page, DataGridView grid, TsvDocument doc, params string[] columns)
    {
        page.Controls.Clear();
        grid.Columns.Clear();
        grid.Rows.Clear();
        if (false && ReferenceEquals(doc, ui))
        {
            var toolbar = new FlowLayoutPanel { Dock = DockStyle.Top, Height = 40, Padding = new Padding(7), WrapContents = false };
            toolbar.Controls.Add(Button("UI 런타임 수집 가져오기", (_, _) => ImportRuntimeUiCapture()));
            toolbar.Controls.Add(new Label { Text = "Imports unique UI strings from runtime_ui_strings_raw.tsv; existing translations stay untouched.", AutoSize = true, Padding = new Padding(8, 8, 0, 0) });
            page.Controls.Add(grid);
            page.Controls.Add(toolbar);
        }
        else page.Controls.Add(grid);
        var titles = new Dictionary<string, string> {
            ["speaker_id"] = "화자 ID", ["ui_id"] = "UI ID", ["category"] = "분류",
            ["jp_name"] = "일본어 이름", ["ko_name"] = "한국어 이름",
            ["jp_text"] = "일본어 UI", ["ko_text"] = "한국어 UI",
            ["status"] = "상태", ["note"] = "메모"
        };
        foreach (var column in columns)
        {
            var index = grid.Columns.Add(column, titles.TryGetValue(column, out var title) ? title : column);
            grid.Columns[index].Width = column is "jp_text" or "ko_text" or "note" ? 340 : column is "jp_name" or "ko_name" ? 220 : 110;
            grid.Columns[index].ReadOnly = !(column.StartsWith("ko_") || column is "status" or "note");
        }
        loadingStatic = true;
        for (var i = 0; i < doc.Rows.Count; i++) { var rowIndex = grid.Rows.Add(columns.Select(c => doc.Get(doc.Rows[i], c)).ToArray()); grid.Rows[rowIndex].Tag = i; }
        loadingStatic = false;
        grid.CellValueChanged += (_, e) =>
        {
            if (loadingStatic || e.RowIndex < 0 || e.ColumnIndex < 0) return;
            var sourceIndex = (int)grid.Rows[e.RowIndex].Tag!; var column = columns[e.ColumnIndex];
            doc.Set(doc.Rows[sourceIndex], column, Convert.ToString(grid[e.ColumnIndex, e.RowIndex].Value) ?? "");
            UpdateTitle();
        };
    }

    private void ImportRuntimeUiCapture(bool showMessage = true)
    {
        var path = Path.Combine(ResolveAuditDirectory(), RuntimeUiFileName);
        if (!File.Exists(path))
        {
            MessageBox.Show($"Runtime UI capture was not found. Run COLLECT_RUNTIME_UI_STRINGS.lua first.\n{path}");
            return;
        }

        var raw = TsvDocument.Load(path, new[] { "order", "frame", "buffer_pointer", "header_hex", "raw_hex", "bytes_including_ff" });
        var added = 0;
        var seen = 0;
        var known = ui.Rows
            .GroupBy(row => ui.Get(row, "jp_text"), StringComparer.Ordinal)
            .ToDictionary(group => group.Key, group => group.First(), StringComparer.Ordinal);
        // A note accumulates one identity per line, so the set has to be built
        // per line.  Taking the whole field meant a multi-identity note never
        // matched any single identity below, and a note whose first line is
        // something else (a reviewer comment) was skipped entirely -- so every
        // import re-appended everything.  Measured 2026-08-14: 803 distinct
        // identities had grown to 80,957 lines, 8.2 MB, and one row (UI0131)
        // held 1,701 copies of its 16.
        var importedIdentities = ui.Rows
            .SelectMany(row => ui.Get(row, "note").Split('\n'))
            .Select(line => line.Trim())
            .Where(line => line.StartsWith("[RUNTIME_UI]", StringComparison.Ordinal))
            .ToHashSet(StringComparer.Ordinal);

        foreach (var capture in raw.Rows)
        {
            var hex = raw.Get(capture, "raw_hex").Trim();
            if (hex.EndsWith(" FF", StringComparison.OrdinalIgnoreCase)) hex = hex[..^3];
            if (hex.Length == 0) continue;
            var japanese = AuditEngine.DecodeSource(hex);
            if (japanese.Length == 0 || japanese.StartsWith("<", StringComparison.Ordinal)) continue;
            var identity = $"[RUNTIME_UI] order={raw.Get(capture, "order")}; ptr={raw.Get(capture, "buffer_pointer")}; header={raw.Get(capture, "header_hex")}; raw={raw.Get(capture, "raw_hex")}";
            if (importedIdentities.Contains(identity)) continue;
            if (known.TryGetValue(japanese, out var existing))
            {
                // Same Japanese text in another UI location shares one
                // editable translation. Retain the new runtime provenance in
                // its note instead of endlessly incrementing on every watch.
                ui.Set(existing, "note", string.Join("\n", new[] { ui.Get(existing, "note"), identity }.Where(x => x.Length > 0)));
                importedIdentities.Add(identity);
                seen++;
                continue;
            }

            var row = Enumerable.Repeat("", ui.Headers.Count).ToList();
            ui.Set(row, "ui_id", $"UIR_{StableShortHash(identity)}");
            ui.Set(row, "category", "runtime");
            ui.Set(row, "occurrences", "1");
            ui.Set(row, "first_disc_offset", "");
            ui.Set(row, "all_disc_offsets", "");
            ui.Set(row, "jp_text", japanese);
            ui.Set(row, "ko_text", "");
            ui.Set(row, "status", "todo");
            ui.Set(row, "note", identity);
            ui.Rows.Add(row);
            known[japanese] = row;
            importedIdentities.Add(identity);
            added++;
        }

        if (added > 0 || seen > 0)
        {
            ui.Dirty = true;
            PopulateStaticTables();
            UpdateTitle();
        }
        if (showMessage)
            MessageBox.Show($"Runtime UI import complete: {added} new, {seen} existing captures counted. Existing UI translations were not changed.");
    }

    private static string StableShortHash(string value)
    {
        unchecked
        {
            uint hash = 2166136261;
            foreach (var ch in value) { hash ^= ch; hash *= 16777619; }
            return hash.ToString("X8");
        }
    }

    private void RefreshMasterGrid()
    {
        if (loadingMaster) return;
        ApplyCurrent();
        loadingMaster = true;
        // Adding thousands of rows one at a time makes the grid re-measure on
        // every Add.  Suspending layout for the rebuild is the difference
        // between a visible freeze and an instant redraw.
        masterGrid.SuspendLayout();
        masterGrid.Rows.Clear(); filteredMaster.Clear();
        var query = searchBox.Text.Trim(); var selectedScene = sceneFilter.SelectedItem?.ToString() ?? "전체"; var filter = rowFilter.SelectedItem?.ToString() ?? "전체";
        var duplicateConflicts = DuplicateConflictIndices();
        var silentRootConflicts = SilentRootConflictIndices();
        var auditStatuses = AuditStatusesByMasterIndex();
        var lookupFailures = AuditIndices(auditStatuses, "LOOKUP_FAIL");
        var routeFailures = AuditIndices(auditStatuses, "ROUTE_FAIL");
        var masterOnly = AuditIndices(auditStatuses, "MASTER_ONLY");
        IEnumerable<int> rowOrder = Enumerable.Range(0, master.Rows.Count);
        if (orderMasterByScene)
        {
            // Empty scene values belong at the end.  Index is the stable
            // second key, so BR/CONT/END chains stay in their exact source
            // order inside every scene.
            rowOrder = rowOrder
                .OrderBy(i =>
                {
                    var value = SceneOf(master.Get(master.Rows[i], "source_refs"));
                    return value.Length == 0 ? "\uFFFF" : value.Split(',')[0];
                }, StringComparer.Ordinal)
                .ThenBy(i => i);
        }
        foreach (var i in rowOrder)
        {
            var row = master.Rows[i]; var joined = string.Join(" ", row); if (query.Length > 0 && !joined.Contains(query, StringComparison.OrdinalIgnoreCase)) continue;
            var scene = SceneOf(master.Get(row, "source_refs")); if (selectedScene != "전체" && !scene.Split(',').Contains(selectedScene)) continue;
            // 18칸은 화면 한 줄의 제한이다.  한 레코드가 {BR} 로 두 줄을 담으면
            // 합계는 36칸이 되지만 각 줄은 18칸 안이므로 초과가 아니다.
            var ko = master.Get(row, "ko_text"); var review = ReviewValue(row); var cells = WidestLineCells(ko); var limit = ParseInt(master.Get(row, "max_cells"), 18);
            var feNeedsReview = !FeControlsMatch(master.Get(row, "jp_text"), ko);
            var isNewMiss = IsUneditedRuntimeMiss(row);
            if (filter == "미검토" && review.Equals("O", StringComparison.OrdinalIgnoreCase)) continue;
            if (filter == "검토 O" && !review.Equals("O", StringComparison.OrdinalIgnoreCase)) continue;
            if (filter == "번역 없음" && ko.Trim().Length > 0) continue;
            if (filter == "18칸 초과" && cells <= limit) continue;
            if (filter == "예외처리" && review != "예외처리") continue;
            if (filter == "조용한 통일" && !silentRootConflicts.Contains(i)) continue;
            if (filter == "중복 번역 충돌" && !duplicateConflicts.Contains(i)) continue;
            if (filter == "FE 확인" && !feNeedsReview) continue;
            if (filter == "초록 · 신규 누락" && !isNewMiss) continue;
            if (filter == "주황 · LOOKUP_FAIL" && !lookupFailures.Contains(i)) continue;
            if (filter == "보라 · ROUTE_FAIL" && !routeFailures.Contains(i)) continue;
            if (filter == "청회 · MASTER_ONLY" && !masterOnly.Contains(i)) continue;
            if (filter == "분홍 · 18칸 초과" && cells <= limit) continue;
            if (filter == "노랑 · 중복 충돌" && !duplicateConflicts.Contains(i)) continue;
            if (filter == "하늘 · FE 확인" && !feNeedsReview) continue;
            var auditStatus = auditStatuses.TryGetValue(i, out var statuses) ? string.Join("/", statuses.OrderBy(AuditStatusOrder)) : "";
            var n = masterGrid.Rows.Add(master.Get(row, "text_key"), master.Get(row, "line_no"), scene, master.Get(row, "chapter"), master.Get(row, "speaker"), master.Get(row, "jp_text"), ko, master.Get(row, "after_control"), auditStatus, review, master.Get(row, "root_mode"));
            masterGrid.Rows[n].Tag = i; filteredMaster.Add(i);
            // Anything the build refuses outranks every status colour.  The
            // others say where a row came from and can wait; these say the next
            // build dies on this row.  A freshly imported MISS is green, and
            // green used to win, so a 17-glyph line typed into a new row showed
            // no warning at all in the list.
            //
            // Encoded bytes belong here as much as cells do: a record holds 80
            // and stage 3 raises rather than truncating, but only the cell count
            // was ever coloured, so that one was invisible until the build failed.
            // (The 15-glyph ceiling that used to sit here went away with the BIOS
            // font path on 2026-08-18 -- see ExceedsRecordLimits.)
            if (ExceedsRecordLimits(row, ko, cells, limit)) masterGrid.Rows[n].DefaultCellStyle.BackColor = Theme.RowOverLimit;
            else if (isNewMiss) masterGrid.Rows[n].DefaultCellStyle.BackColor = Theme.RowNew;
            else if (lookupFailures.Contains(i)) masterGrid.Rows[n].DefaultCellStyle.BackColor = Theme.RowLookupFail;
            else if (routeFailures.Contains(i)) masterGrid.Rows[n].DefaultCellStyle.BackColor = Theme.RowRouteFail;
            // Yellow is reserved for an actual duplicate-translation conflict.
            // MASTER_ONLY is a build/audit coverage state, not a duplicate.
            else if (masterOnly.Contains(i)) masterGrid.Rows[n].DefaultCellStyle.BackColor = Theme.RowMasterOnly;
            else if (silentRootConflicts.Contains(i) || duplicateConflicts.Contains(i)) masterGrid.Rows[n].DefaultCellStyle.BackColor = Theme.RowConflict;
            else if (feNeedsReview) masterGrid.Rows[n].DefaultCellStyle.BackColor = Theme.RowNeedsReview;
        }
        // One pass for all three totals.  These were three separate scans of the
        // whole master, two of them running regexes per row.
        var reviewed = 0; var feReviewCount = 0; var newMissCount = 0;
        foreach (var r in master.Rows)
        {
            if (ReviewValue(r).Equals("O", StringComparison.OrdinalIgnoreCase)) reviewed++;
            if (!FeControlsMatch(master.Get(r, "jp_text"), master.Get(r, "ko_text"))) feReviewCount++;
            if (IsUneditedRuntimeMiss(r)) newMissCount++;
        }
        // 검토 진행도가 이 줄에서 유일하게 매일 보는 숫자다.  맨 앞에 두고 남은
        // 건수와 백분율까지 붙인다.  LOOKUP/ROUTE/MASTER 는 감사 탭에도 같은 값이
        // 있고 평소 0 이라, 줄만 길게 만들어 뒤쪽 항목을 잘라먹고 있었다.
        var total = master.Rows.Count;
        var percent = total > 0 ? reviewed * 100.0 / total : 0;
        summaryLabel.Text =
            $"검토 {reviewed:N0} / {total:N0} ({percent:F1}%) · 남음 {total - reviewed:N0}"
            + $" · 표시 {filteredMaster.Count:N0}"
            + $" · 신규 누락 {newMissCount:N0} · 조용한 통일 {silentRootConflicts.Count:N0}"
            + $" · 중복 충돌 {duplicateConflicts.Count:N0} · FE 확인 {feReviewCount:N0}";
        masterGrid.ResumeLayout();
        loadingMaster = false;
        SelectMasterRow();
    }

    private void SelectMasterRow()
    {
        if (loadingMaster || masterGrid.SelectedRows.Count == 0 || masterGrid.SelectedRows[0].Tag is not int selectedIndex) return;
        ApplyCurrent();
        currentMasterIndex = selectedIndex; var row = master.Rows[currentMasterIndex];
        identityLabel.Text = $"{master.Get(row, "text_key")} · line {master.Get(row, "line_no")} · 장면 {SceneOf(master.Get(row, "source_refs"))}";
        jpBox.Text = master.Get(row, "jp_text"); koBox.Text = master.Get(row, "ko_text"); controlBox.Text = master.Get(row, "after_control");
        loadingChapter = true;
        chapterBox.SelectedItem = master.Get(row, "chapter");
        if (chapterBox.SelectedIndex < 0) chapterBox.SelectedIndex = 0;
        loadingChapter = false;
        // Writing two lines into one record and blanking the rest is the way
        // out of the extractor's fragment boundaries, but a blanked record must
        // stay visible: its Japanese is still the only record of what the game
        // shows there, and reviewing the anchor alone would hide it.
        contextBox.Text = string.Join("\r\n\r\n", master.Rows
            .Where(r => master.Get(r, "text_key") == master.Get(row, "text_key"))
            .Select(r =>
            {
                var ko = master.Get(r, "ko_text");
                var mark = ReferenceEquals(r, row) ? "  ◀ 편집 중"
                    : ko.Trim().Equals("{EMPTY}", StringComparison.OrdinalIgnoreCase) ? "  ⚠ 비움"
                    : ko.Trim().Length == 0 ? "  ⚠ 미번역"
                    : "";
                var lines = LayoutLines(ko).Length;
                var span = lines > 1 ? $"  [{lines}줄]" : "";
                return $"[{master.Get(r, "line_no")}] JP  {master.Get(r, "jp_text")}\r\n"
                     + $"    KO  {ko}  → {master.Get(r, "after_control")}{span}{mark}";
            }));
        PopulateDuplicateList(row);
        UpdateMetrics();
    }

    private void PopulateDuplicateList(List<string> selectedRow)
    {
        duplicateList.Items.Clear();
        var jp = master.Get(selectedRow, "jp_text");
        foreach (var (row, index) in master.Rows.Select((row, index) => (row, index))
                     .Where(item => master.Get(item.row, "jp_text") == jp))
        {
            duplicateList.Items.Add(new DuplicateListEntry(
                index,
                $"{master.Get(row, "text_key")}:{master.Get(row, "line_no")}  [{ReviewValue(row)}]  {master.Get(row, "ko_text")}"));
        }
    }

    private void OpenSelectedDuplicate()
    {
        if (duplicateList.SelectedItem is not DuplicateListEntry item) return;
        NavigateToMasterIndex(item.MasterIndex);
    }

    /// <summary>
    /// 중복 목록에서 고른 행들의 검토값을 한 번에 바꾼다.  그리드 다중선택과
    /// 같은 일을 하지만, 같은 원문이 서로 다른 장면에 흩어져 있어 한 화면에
    /// 모이지 않을 때 쓴다.
    /// </summary>
    private void SetReviewForSelectedDuplicates(string value)
    {
        if (duplicateList.SelectedItems.Count == 0) return;
        var column = master.Headers.FindIndex(h => string.IsNullOrEmpty(h));
        if (column < 0) { MessageBox.Show("MASTER에 검토용 빈 열이 없습니다."); return; }
        ApplyCurrent();

        var changed = 0;
        foreach (var entry in duplicateList.SelectedItems.Cast<DuplicateListEntry>().ToList())
        {
            if (entry.MasterIndex < 0 || entry.MasterIndex >= master.Rows.Count) continue;
            var row = master.Rows[entry.MasterIndex];
            while (row.Count <= column) row.Add("");
            if (row[column] == value) continue;
            row[column] = value;
            changed++;
        }
        if (changed == 0) return;

        master.Dirty = true;
        duplicateConflictCache = null;
        UpdateTitle();
        // 검토값이 바뀌면 "미검토"/"검토 O" 필터 소속이 달라질 수 있으므로 다시 그린다.
        RefreshMasterGridKeeping(currentMasterIndex);
        MessageBox.Show(value.Length > 0 ? $"{changed}건을 검토 {value} 로 바꿨습니다."
                                         : $"{changed}건의 검토를 해제했습니다.");
    }

    /// <summary>
    /// 지금 편집 중인 한국어를 중복 목록에서 고른 행들에 그대로 넣는다.
    /// 같은 문장을 여러 번 치는 일을 없앤다.
    /// </summary>
    private void ApplyKoreanToSelectedDuplicates()
    {
        if (duplicateList.SelectedItems.Count == 0) return;
        ApplyCurrent();
        if (currentMasterIndex < 0 || currentMasterIndex >= master.Rows.Count) return;
        var korean = master.Get(master.Rows[currentMasterIndex], "ko_text");

        var changed = 0;
        foreach (var entry in duplicateList.SelectedItems.Cast<DuplicateListEntry>().ToList())
        {
            if (entry.MasterIndex < 0 || entry.MasterIndex >= master.Rows.Count) continue;
            if (entry.MasterIndex == currentMasterIndex) continue;
            var row = master.Rows[entry.MasterIndex];
            if (master.Get(row, "ko_text") == korean) continue;
            master.Set(row, "ko_text", korean);
            changed++;
        }
        if (changed == 0) { MessageBox.Show("바뀐 행이 없습니다."); return; }

        master.Dirty = true;
        duplicateConflictCache = null;
        UpdateTitle();
        RefreshMasterGridKeeping(currentMasterIndex);
        MessageBox.Show($"{changed}건에 같은 번역을 넣었습니다.");
    }

    private void RevealSelectedMasterInAllRows()
    {
        var target = masterGrid.SelectedRows.Count > 0 && masterGrid.SelectedRows[0].Tag is int selected
            ? selected
            : currentMasterIndex;
        if (target < 0) return;
        searchBox.Text = "";
        masterSearchDebounce.Stop();
        if (sceneFilter.Items.Count > 0) sceneFilter.SelectedIndex = 0;
        if (rowFilter.Items.Count > 0) rowFilter.SelectedIndex = 0;
        RefreshMasterGridKeeping(target);
    }

    private void NavigateToMasterIndex(int targetIndex)
    {
        if (targetIndex < 0 || targetIndex >= master.Rows.Count) return;
        ApplyCurrent();

        // The target can be hidden by the current search/filter. Clear only
        // view restrictions; existing TSV edits remain untouched.
        if (!filteredMaster.Contains(targetIndex))
        {
            searchBox.Text = "";
            if (sceneFilter.Items.Count > 0) sceneFilter.SelectedIndex = 0;
            if (rowFilter.Items.Count > 0) rowFilter.SelectedIndex = 0;
            RefreshMasterGrid();
        }

        foreach (DataGridViewRow gridRow in masterGrid.Rows)
        {
            if (gridRow.Tag is not int index || index != targetIndex) continue;
            masterGrid.ClearSelection();
            gridRow.Selected = true;
            masterGrid.CurrentCell = gridRow.Cells[0];
            masterGrid.FirstDisplayedScrollingRowIndex = gridRow.Index;
            SelectMasterRow();
            break;
        }
    }

    private void ApplyChapterToCurrentPage()
    {
        if (loadingChapter || currentMasterIndex < 0 || currentMasterIndex >= master.Rows.Count) return;
        var value = chapterBox.SelectedItem?.ToString() ?? "";
        var key = master.Get(master.Rows[currentMasterIndex], "text_key");
        var changed = 0;
        foreach (var row in master.Rows)
        {
            if (master.Get(row, "text_key") != key || master.Get(row, "chapter") == value) continue;
            master.Set(row, "chapter", value);
            changed++;
        }
        if (changed == 0) return;
        master.Dirty = true;
        UpdateTitle();
    }

    private void ApplyCurrent()
    {
        if (currentMasterIndex < 0 || currentMasterIndex >= master.Rows.Count) return; var row = master.Rows[currentMasterIndex];
        var previousKo = master.Get(row, "ko_text");
        if (IsUneditedRuntimeMiss(row) && master.Get(row, "ko_text") != koBox.Text)
            RemoveRuntimeMissMarker(row);
        master.Set(row, "ko_text", koBox.Text); master.Set(row, "after_control", controlBox.Text.Trim());
        // ko_cells/ko_line 도 화면 한 줄 기준이어야 한다.  여러 줄 레코드에서 합계를
        // 쓰면 byte_check 가 멀쩡한 행을 CELLS+ 로 표시한다.
        var cells = WidestLineCells(koBox.Text); master.Set(row, "ko_cells", CellsText(cells)); master.Set(row, "ko_line", CellsText(cells));
        master.Set(row, "ko_bytes", ApproxBytes(koBox.Text).ToString()); master.Set(row, "byte_check", cells <= ParseInt(master.Get(row, "max_cells"), 18) ? "OK" : $"CELLS+{CellsText(cells - ParseInt(master.Get(row, "max_cells"), 18))}");
        if (previousKo != koBox.Text)
        {
            duplicateConflictCache = null;
            // The grid held the pre-edit text until something forced a full
            // rebuild, so an edit only "appeared" after pressing save.  Repaint
            // just this row instead.
            if (!loadingMaster) UpdateMasterGridRow(currentMasterIndex);
        }
        UpdateTitle();
    }

    private void ToggleEmptyTranslation()
    {
        koBox.Text = koBox.Text.Trim().Equals("{EMPTY}", StringComparison.OrdinalIgnoreCase) ? "" : "{EMPTY}";
        koBox.SelectionStart = koBox.TextLength;
        koBox.Focus();
        UpdateMetrics();
    }
    /// <summary>
    /// 선택한 행을 MASTER 에서 아주 지운다.  번역만 비우는 {EMPTY} 와 다르다 --
    /// 런타임 수집이 잘못 잡은 조각처럼 행 자체가 있으면 안 되는 것을 위한 것이다.
    /// </summary>
    private void DeleteSelectedMasterRows()
    {
        if (masterGrid.SelectedRows.Count == 0) return;

        // Tag 로 실제 인덱스를 모은다.  그리드는 필터된 부분집합이라 화면 순서와
        // master.Rows 의 순서가 다르다.
        var targets = masterGrid.SelectedRows.Cast<DataGridViewRow>()
            .Where(r => r.Tag is int)
            .Select(r => (int)r.Tag!)
            .Distinct()
            .OrderByDescending(i => i)
            .ToList();
        if (targets.Count == 0) return;

        var sample = string.Join("\n", targets.OrderBy(i => i).Take(5)
            .Select(i => $"  {master.Get(master.Rows[i], "text_key")}:{master.Get(master.Rows[i], "line_no")}"
                       + $"  {master.Get(master.Rows[i], "jp_text")}"));
        var more = targets.Count > 5 ? $"\n  … 외 {targets.Count - 5}건" : "";
        if (MessageBox.Show($"{targets.Count}행을 MASTER 에서 삭제합니다.\n되돌릴 수 없습니다.\n\n{sample}{more}",
                            "행 삭제", MessageBoxButtons.OKCancel, MessageBoxIcon.Warning)
            != DialogResult.OK) return;

        // 내림차순으로 지워야 앞 인덱스가 밀리지 않는다.
        foreach (var index in targets) master.Rows.RemoveAt(index);

        currentMasterIndex = -1;
        master.Dirty = true;
        duplicateConflictCache = null;
        UpdateTitle();
        RefreshMasterGrid();
        MessageBox.Show($"{targets.Count}행을 삭제했습니다.\n저장해야 파일에 반영됩니다.");
    }

    private void InsertTranslationToken(string token)
    {
        var start = koBox.SelectionStart;
        koBox.SelectedText = token;
        koBox.SelectionStart = start + token.Length;
        koBox.SelectionLength = 0;
        koBox.Focus();
        UpdateMetrics();
    }
    // 그리드가 다중 선택을 허용하므로(masterGrid.MultiSelect), 선택된 행 전체에
    // 같은 검토값을 적용한다. 필터 소속이 바뀌는 행이 하나라도 있으면 전체를
    // 다시 그리고, 아니면 바뀐 셀만 갱신해 6,000행 재검증을 피한다.
    private void SetReview(string value)
    {
        if (masterGrid.SelectedRows.Count == 0) return;
        var index = master.Headers.FindIndex(h => string.IsNullOrEmpty(h));
        if (index < 0) { MessageBox.Show("MASTER에 검토용 빈 열이 없습니다."); return; }
        ApplyCurrent();

        var filter = rowFilter.SelectedItem?.ToString() ?? "전체";
        var changedIndices = new HashSet<int>();
        var membershipChanged = false;
        List<string>? primaryRow = null;

        foreach (DataGridViewRow gridRow in masterGrid.SelectedRows)
        {
            if (gridRow.Tag is not int sourceIndex) continue;
            var row = master.Rows[sourceIndex];
            primaryRow ??= row;
            while (row.Count <= index) row.Add("");
            var previous = row[index];
            if (previous == value) continue;
            row[index] = value;
            changedIndices.Add(sourceIndex);
            if (filter switch
                {
                    "검토 O" or "미검토" => previous.Equals("O", StringComparison.OrdinalIgnoreCase) != value.Equals("O", StringComparison.OrdinalIgnoreCase),
                    "예외처리" => (previous == "예외처리") != (value == "예외처리"),
                    _ => false,
                })
                membershipChanged = true;
        }

        if (changedIndices.Count == 0) return;
        master.Dirty = true;
        duplicateConflictCache = null;
        UpdateTitle();

        if (membershipChanged)
        {
            RefreshMasterGridKeeping(currentMasterIndex);
        }
        else
        {
            foreach (DataGridViewRow gridRow in masterGrid.Rows)
                if (gridRow.Tag is int sourceIndex && changedIndices.Contains(sourceIndex))
                    gridRow.Cells["review"].Value = value;
            var reviewed = master.Rows.Count(r => ReviewValue(r).Equals("O", StringComparison.OrdinalIgnoreCase));
            summaryLabel.Text = Regex.Replace(summaryLabel.Text, @"검토 O [0-9,]+", $"검토 O {reviewed:N0}");
        }
        if (primaryRow != null) PopulateDuplicateList(primaryRow);
    }
    private void ToggleExceptionReview()
    {
        if (currentMasterIndex < 0) return;
        SetReview(ReviewValue(master.Rows[currentMasterIndex]) == "예외처리" ? "" : "예외처리");
    }
    private string ReviewValue(List<string> row) { var index = master.Headers.FindIndex(h => string.IsNullOrEmpty(h)); return index >= 0 && index < row.Count ? row[index].Trim() : ""; }

    /// <summary>
    /// Mark every separable member of the selected root-source group AUTO.
    /// The first reviewed occurrence remains the legacy root.  A later
    /// translation is safe to split only when its captured pack/speaker tuple
    /// differs; identical tuples are deliberately left unresolved and visible.
    /// </summary>
    private void SetAutomaticRootContext()
    {
        if (currentMasterIndex < 0 || currentMasterIndex >= master.Rows.Count) return;
        ApplyCurrent();
        var source = master.Get(master.Rows[currentMasterIndex], "jp_text");
        var roots = ReviewedRootRows()
            .Where(item => master.Get(item.row, "jp_text") == source)
            .OrderBy(item => item.index)
            .ToList();
        if (roots.Count < 2) { MessageBox.Show("같은 일본어 머리 줄이 없습니다."); return; }

        var canonical = roots[0];
        var canonicalKo = master.Get(canonical.row, "ko_text");
        var canonicalContext = RootContext(canonical.row);
        var changed = 0;
        var blocked = 0;
        foreach (var item in roots.Skip(1))
        {
            if (master.Get(item.row, "ko_text") == canonicalKo) continue;
            var context = RootContext(item.row);
            var contextTranslations = roots
                .Where(other => RootContext(other.row) == context)
                .Select(other => master.Get(other.row, "ko_text"))
                .Distinct()
                .Count();
            if (context.Length == 0 || context == canonicalContext || contextTranslations > 1)
            {
                blocked++;
                continue;
            }
            if (master.Get(item.row, "root_mode").Equals("AUTO", StringComparison.OrdinalIgnoreCase)) continue;
            master.Set(item.row, "root_mode", "AUTO");
            changed++;
        }
        if (changed > 0)
        {
            master.Dirty = true;
            silentRootConflictCache = null;
            UpdateTitle();
            RefreshMasterGridKeeping(currentMasterIndex);
        }
        MessageBox.Show($"문맥 분리 {changed}건 설정 · 동일 문맥이라 자동 분리 불가 {blocked}건");
    }

    private string RootContext(List<string> row)
    {
        var pack = master.Get(row, "pack").Trim().ToUpperInvariant();
        if (pack.Length == 0) return "";
        return pack + "|" + master.Get(row, "speaker").Trim();
    }

    private List<(List<string> row, int index)> ReviewedRootRows()
    {
        var first = new Dictionary<string, (List<string> row, int index, int line)>();
        for (var index = 0; index < master.Rows.Count; index++)
        {
            var row = master.Rows[index];
            if (!ReviewValue(row).Equals("O", StringComparison.OrdinalIgnoreCase)) continue;
            if (!int.TryParse(master.Get(row, "line_no"), out var line)) continue;
            var key = master.Get(row, "text_key");
            if (!first.TryGetValue(key, out var old) || line < old.line)
                first[key] = (row, index, line);
        }
        return first.Values.Select(value => (value.row, value.index)).ToList();
    }

    /// <summary>Rows that the old builder would silently replace at state zero.</summary>
    private HashSet<int> SilentRootConflictIndices()
    {
        // Recompute on refresh.  Translation and review edits already have many
        // call sites; a cheap 15k-row pass is safer than a stale red warning.
        var result = new HashSet<int>();
        foreach (var group in ReviewedRootRows()
                     .Where(item => !master.Get(item.row, "root_mode").Equals("AUTO", StringComparison.OrdinalIgnoreCase))
                     .GroupBy(item => master.Get(item.row, "jp_text")))
        {
            var translations = group.Select(item => master.Get(item.row, "ko_text")).Distinct().ToList();
            if (translations.Count <= 1) continue;
            foreach (var item in group) result.Add(item.index);
        }
        silentRootConflictCache = result;
        return result;
    }

    private void UpdateMetrics()
    {
        if (currentMasterIndex < 0) return;
        var row = master.Rows[currentMasterIndex];
        var limit = ParseInt(master.Get(row, "max_cells"), 18);
        var lines = LayoutLines(koBox.Text);
        var widest = WidestLineCells(koBox.Text);
        var bytes = EncodedBytes(koBox.Text);
        var feMissing = HasOmittedFe(master.Get(row, "jp_text"), koBox.Text);

        // A record's FD only moves the cursor; the game's own line counter never
        // sees it.  If another record follows, it draws over the extra lines --
        // so splitting is safe only where nothing follows, i.e. after_control END.
        var multiline = lines.Length > 1;
        var unsafeSplit = multiline && master.Get(row, "after_control").Trim() != "END";

        var parts = new List<string>();
        parts.Add(multiline
            ? $"{lines.Length}줄 · 최대 {CellsText(widest)}/{limit}칸"
            : $"{CellsText(widest)}/{limit}칸");
        // 고유 한글 N/15 는 2026-08-18 에 없앴다.  BIOS 폰트 경로로 넘어가면서
        // 레코드가 자기 글리프를 싣지 않게 됐다 (atlas 0 glyphs, 0 B).  빌더의
        // `len(used) > GLYPH_SLOTS` 예외는 BIOS 모드에서 `used` 가 항상 비어 있어
        // 발생할 수 없다.  없는 제약을 빨갛게 칠하고 있었다.
        parts.Add($"{bytes}/{RecordByteCapacity}B");

        var problems = new List<string>();
        if (widest > limit) problems.Add($"칸 초과 +{CellsText(widest - limit)}");
        if (bytes > RecordByteCapacity) problems.Add($"용량 초과 +{bytes - RecordByteCapacity}");
        if (unsafeSplit) problems.Add($"줄바꿈 위험(after={master.Get(row, "after_control")})");
        if (feMissing) problems.Add("FE 누락");

        metricLabel.Text = "  " + string.Join(" · ", parts) + " · " + (problems.Count == 0 ? "OK" : string.Join(" · ", problems));
        metricLabel.ForeColor = problems.Count == 0 ? Theme.Good : Theme.Bad;
        // The metric line already turned red, but a one-line caption under the
        // box is easy to type past.  Colour the box itself for anything the
        // build refuses -- the 80-byte ceiling and the displayed cell width.
        var overLimit = widest > limit
            || bytes > RecordByteCapacity;
        koBox.BackColor = overLimit || feMissing || unsafeSplit ? Theme.RowOverLimit : Theme.RowDefault;
    }

    private HashSet<int> DuplicateConflictIndices()
    {
        if (duplicateConflictCache != null) return duplicateConflictCache;
        var result = new HashSet<int>();
        foreach (var group in master.Rows.Select((r, i) => (r, i)).Where(x => master.Get(x.r, "jp_text").Length > 0).GroupBy(x => master.Get(x.r, "jp_text")))
        {
            // O is the build authority.  Unreviewed drafts with the same
            // Japanese must not turn a reviewed row yellow, and identical O
            // translations are intentionally shared across their own routes.
            // An explicit exception is a route-specific choice, so it is not
            // treated as a generic duplicate warning here.
            var reviewed = group
                .Where(x => ReviewValue(x.r).Equals("O", StringComparison.OrdinalIgnoreCase))
                .ToList();
            var translations = reviewed
                .Select(x => master.Get(x.r, "ko_text").Trim())
                .Where(v => v.Length > 0 && v != "{EMPTY}")
                .Distinct()
                .ToList();
            if (translations.Count > 1)
                foreach (var item in reviewed) result.Add(item.i);
        }
        duplicateConflictCache = result;
        return result;
    }

    private void MoveRow(int delta)
    {
        if (filteredMaster.Count == 0) return;
        if (delta > 0 && currentMasterIndex >= 0 && HasOmittedFe(master.Get(master.Rows[currentMasterIndex], "jp_text"), koBox.Text))
        {
            var answer = MessageBox.Show(
                "원문에는 FE 색상 제어가 있지만 번역문에는 FE 토큰이 없습니다.\n그래도 다음 행으로 이동할까요?",
                "FE 제어 누락 확인",
                MessageBoxButtons.YesNo,
                MessageBoxIcon.Warning);
            if (answer != DialogResult.Yes) { koBox.Focus(); return; }
        }
        ApplyCurrent();
        var pos = filteredMaster.IndexOf(currentMasterIndex);
        pos = Math.Clamp((pos < 0 ? 0 : pos) + delta, 0, filteredMaster.Count - 1);
        // Stepping to the next line used to rebuild every grid row, which meant
        // re-running two regexes per row across the whole master plus three full
        // scans for the summary.  Nothing about the filter changed, so just move
        // the selection; ApplyCurrent already refreshed the row being left.
        SelectMasterIndexInGrid(filteredMaster[pos]);
    }

    /// <summary>Select an already-visible row without rebuilding the grid.</summary>
    private void SelectMasterIndexInGrid(int index)
    {
        var gridRow = FindGridRow(index);
        if (gridRow == null) { RefreshMasterGridKeeping(index); return; }
        currentMasterIndex = -1;
        masterGrid.ClearSelection();
        gridRow.Selected = true;
        masterGrid.CurrentCell = gridRow.Cells[0];
        var first = Math.Max(0, gridRow.Index - 3);
        if (gridRow.Index < masterGrid.FirstDisplayedScrollingRowIndex
            || gridRow.Index >= masterGrid.FirstDisplayedScrollingRowIndex + masterGrid.DisplayedRowCount(false))
            masterGrid.FirstDisplayedScrollingRowIndex = first;
        SelectMasterRow();
    }

    /// <summary>
    /// Grid row order matches <see cref="filteredMaster"/> exactly: every
    /// Rows.Add is followed by the matching filteredMaster.Add.  So the position
    /// in that list is the grid row index, and no linear Tag scan is needed.
    /// </summary>
    private DataGridViewRow? FindGridRow(int masterIndex)
    {
        var position = filteredMaster.IndexOf(masterIndex);
        if (position < 0 || position >= masterGrid.Rows.Count) return null;
        return masterGrid.Rows[position].Tag is int tag && tag == masterIndex
            ? masterGrid.Rows[position]
            : masterGrid.Rows.Cast<DataGridViewRow>().FirstOrDefault(r => r.Tag is int t && t == masterIndex);
    }

    /// <summary>
    /// Repaint one row from its master record.  Used after an edit so the grid
    /// stops showing stale Korean text until the next full refresh — the reason
    /// a change only appeared after pressing save.
    /// </summary>
    private void UpdateMasterGridRow(int masterIndex)
    {
        var gridRow = FindGridRow(masterIndex);
        if (gridRow == null) return;
        var row = master.Rows[masterIndex];
        var ko = master.Get(row, "ko_text");
        var cells = WidestLineCells(ko);
        gridRow.Cells["ko"].Value = ko;
        gridRow.Cells["control"].Value = master.Get(row, "after_control");
        gridRow.Cells["review"].Value = ReviewValue(row);

        // Only the states that an edit can actually flip are recomputed here.
        // Audit-derived tints (LOOKUP_FAIL / ROUTE_FAIL / MASTER_ONLY) and the
        // new-miss tint come from analysis passes, so leave those rows alone.
        var current = gridRow.DefaultCellStyle.BackColor;
        if (current == Theme.RowLookupFail || current == Theme.RowRouteFail
            || current == Theme.RowMasterOnly || current == Theme.RowNew) return;
        var limit = ParseInt(master.Get(row, "max_cells"), 18);
        gridRow.DefaultCellStyle.BackColor =
            cells > limit ? Theme.RowOverLimit
            : !FeControlsMatch(master.Get(row, "jp_text"), ko) ? Theme.RowNeedsReview
            : Theme.RowDefault;
    }

    private void RefreshMasterGridKeeping(int index)
    {
        currentMasterIndex = -1; RefreshMasterGrid(); foreach (DataGridViewRow row in masterGrid.Rows) if (row.Tag is int i && i == index) { row.Selected = true; masterGrid.FirstDisplayedScrollingRowIndex = Math.Max(0, row.Index - 3); SelectMasterRow(); break; }
    }

    private void AnalyzeAudit(bool quiet)
    {
        try
        {
            var auditDir = ResolveAuditDirectory();
            var raw = Path.Combine(auditDir, RuntimeAuditFileName); if (!File.Exists(raw)) { if (!quiet) MessageBox.Show($"먼저 Mesen에서 runtime_text_audit_0.2.0.lua를 실행해 플레이 로그를 만들어 주세요.\n\n감시 경로: {raw}"); return; }
            if (buildVersion.SelectedItem == null) return; var records = Path.Combine(ResolveHomeProjectRoot() ?? root, "build", "patch", buildVersion.SelectedItem.ToString()!, "direct_records.tsv");
            var currentItems = AuditEngine.Analyze(raw, records, master, speakers, ui);
            var catalogPath = ResolveAuditCatalogPath();
            Directory.CreateDirectory(Path.GetDirectoryName(catalogPath)!);
            var savedItems = AuditEngine.LoadCatalog(catalogPath);
            // One-time migration from builds that kept the durable catalog next
            // to the resettable Mesen session log in C:\snatcher\dump.
            var legacyCatalogPath = Path.Combine(auditDir, "runtime_text_catalog.tsv");
            if (savedItems.Count == 0 && !catalogPath.Equals(legacyCatalogPath, StringComparison.OrdinalIgnoreCase))
                savedItems = AuditEngine.LoadCatalog(legacyCatalogPath);
            // Preserve unresolved discoveries between sessions, but do not
            // keep showing old rows once they have been added to MASTER/UI/
            // speaker tables. Current-session rows always remain visible.
            savedItems = AuditEngine.DropEntriesAlreadyInTables(savedItems, master, speakers, ui);
            auditItems = AuditEngine.MergeCatalog(savedItems, currentItems);
            auditStatusCache = null;
            StampPacksFromAudit(currentItems);
            StampSpeakersFromAudit(currentItems);
            AuditEngine.Export(catalogPath, auditItems);
            RefreshAuditGrid();
            if (mainTabs.SelectedIndex == 0) RefreshMasterGridKeeping(currentMasterIndex);
            AuditEngine.Export(Path.Combine(auditDir, "runtime_text_audit_report.tsv"), auditItems);
        }
        catch (Exception ex) { if (!quiet) MessageBox.Show(ex.ToString(), "로그 분석 오류"); }
    }

    private void RefreshAuditGrid()
    {
        auditGrid.Rows.Clear(); var filter = auditCategory.SelectedItem?.ToString() ?? "전체"; IEnumerable<AuditItem> items = auditItems;
        if (filter == "전체") items = items.Where(x => x.Classification != "HIT");
        else if (filter == "기술 문제") items = items.Where(x => x.Classification is "LOOKUP_FAIL" or "ROUTE_FAIL");
        else if (filter == "번역 큐") items = items.Where(x => x.Classification is "MASTER_ONLY" or "NEAR" or "MISS");
        else if (filter != "전체") items = items.Where(x => x.Classification == filter);
        foreach (var item in items)
        {
            var row = auditGrid.Rows.Add(item.Classification, item.Target, item.Count, item.FirstSeq, item.Scene, item.Japanese, item.AfterControl, item.ExpectedKorean.Length > 0 ? item.ExpectedKorean : item.MasterKorean, item.State, item.References, item.Action);
            auditGrid.Rows[row].Tag = item; auditGrid.Rows[row].DefaultCellStyle.BackColor = item.Classification switch { "LOOKUP_FAIL" or "ROUTE_FAIL" => Theme.RowOverLimit, "MASTER_ONLY" or "NEAR" or "MISS" => Theme.RowConflict, _ => Theme.RowComplete };
        }
        var counts = auditItems.GroupBy(x => x.Classification).ToDictionary(g => g.Key, g => g.Sum(x => x.Count));
        auditSummary.Text = string.Join(" · ", new[] { "HIT", "LOOKUP_FAIL", "ROUTE_FAIL", "MASTER_ONLY", "NEAR", "MISS" }.Select(k => $"{k} {counts.GetValueOrDefault(k)}"));
    }

    private void IncludeSelectedAudit()
    {
        // "대사 포함" is deliberately a batch action.  Runtime collection is a
        // timeline, so which audit row happens to be selected must never decide
        // whether the other collected dialogue lines are imported.
        if (IncludeAllPendingDialogueAudit())
            ClearAuditSessionLog(confirm: false, showMessage: false);
    }

    private bool IncludeAllPendingDialogueAudit()
    {
        if (auditItems.Count == 0) AnalyzeAudit(false);

        var missing = auditItems
            // ROUTE_FAIL joins MISS/NEAR here.  It is not a fault: the Japanese
            // is already in the build, but only under other trie states, so this
            // occurrence has no version to use.  The engine routes by state, so
            // the fix is a per-state copy -- which means it does need importing,
            // just as a sibling of the existing row rather than as new text.
            .Where(item => item.Classification is "MISS" or "NEAR" or "ROUTE_FAIL"
                && item.Target == "대사"
                && !string.IsNullOrWhiteSpace(item.Japanese)
                && !string.IsNullOrWhiteSpace(item.SourceHex)
                // 화자 이름은 speaker 표가 따로 번역한다.  본문 행으로 들어오면
                // after_control=CONT 를 달고 사슬 한가운데에 앉아, 빌더가 상태
                // 번호를 하나 소비하면서 **뒤 줄들이 도달 못 하는 state 로 밀린다**
                // (2026-08-19: R01170:3 'ミカ' 때문에 :4/:5 가 ROUTE_FAIL).
                // Target 판정이 어떤 이유로 빗나가도 여기서 막는다.
                && !IsSpeakerName(item.Japanese))
            // Runtime order is semantic: two consecutive lines may form one
            // dialogue window.  Keep import order equal to the first time the
            // game displayed each line instead of alphabetical/source-hex
            // order, so translation review follows the actual scene.
            .OrderBy(item => item.FirstSeq)
            .ToList();

        if (missing.Count == 0)
        {
            MessageBox.Show("MASTER에 추가할 새 MISS가 없습니다.");
            return false;
        }

        ApplyCurrent();
        var added = 0;
        var legacyFilled = 0;
        var resolvedToStatic = 0;
        var alreadyAdded = 0;
        var firstAddedIndex = master.Rows.Count;
        var importedSources = RuntimeImportedSourceKeys();
        foreach (var item in missing)
        {
            // $3619/$3499 holds a completed renderer buffer, not the disc
            // address.  If static extraction already owns this exact source,
            // keep that static text_key as the one editable translation row.
            // A ROUTE_FAIL is the exception: the row exists but belongs to a
            // different state, and that is exactly what has to be duplicated.
            // ROUTE_FAIL 은 "같은 원문이 다른 trie state 에 또 필요하다" 는 뜻이라
            // 일부러 복제를 허용해 왔다.  state 는 지금도 살아 있다 (0.3.9 실측: 354종,
            // 비루트 355 레코드).
            //
            // 그런데 마스터가 레코드 기준으로 바뀐 뒤로 이것이 **같은 문단 안에서**
            // 복제를 만든다.  실측 사고: R00069 의 line 2 와 line 3 이 원문·번역 모두
            // `ている。` / `속속 들어오고 있군.` 으로 동일하게 들어갔다.
            //
            // 복제의 목적은 다른 루트가 **다른 번역**을 갖게 하는 것이다.  번역까지
            // 같으면 복제는 아무 것도 구분해 주지 않고 트라이만 부풀린다.  그래서
            // 원문과 번역이 둘 다 같은 행이 이미 있으면 ROUTE_FAIL 도 건너뛴다.
            var exact = FindStaticExactRows(item.Japanese);
            if (item.Classification != "ROUTE_FAIL" && exact.Count > 0)
            {
                resolvedToStatic++;
                continue;
            }
            if (item.Classification == "ROUTE_FAIL" && exact.Count > 0
                && exact.Any(index => master.Get(master.Rows[index], "ko_text")
                    .Equals(item.ExpectedKorean, StringComparison.Ordinal)))
            {
                resolvedToStatic++;
                continue;
            }
            if (!importedSources.Add(RuntimeSourceIdentity(item)))
            {
                alreadyAdded++;
                continue;
            }

            var row = Enumerable.Repeat("", master.Headers.Count).ToList();
            master.Set(row, "text_key", RuntimeMissTextKey(item));
            master.Set(row, "line_no", "1");
            master.Set(row, "jp_text", item.Japanese);
            master.Set(row, "ko_text", "");
            master.Set(row, "after_control", item.AfterControl);
            master.Set(row, "status", "todo");
            master.Set(row, "source_refs", $"runtime_audit:state={item.State}:seq={item.FirstSeq}:after={item.AfterControl}");
            master.Set(row, "max_cells", "18");
            master.Set(row, "ko_cells", "0");
            master.Set(row, "ko_line", "0");
            master.Set(row, "ko_bytes", "0");
            master.Set(row, "byte_check", "OK");
            master.Set(row, "speaker", item.Speaker);
            var nearNote = item.Classification == "NEAR"
                ? $"; nearest_jp={item.NearestJapanese}; similarity={item.Similarity:0.000}"
                : "";
            master.Set(row, "note", $"{RuntimeMissUneditedMarker} 런타임 {item.Classification} 자동 등록; after_control={item.AfterControl}; control_origin={item.ControlOrigin}; source_hex={item.SourceHex}; state={item.State}; first_seq={item.FirstSeq}{nearNote}");
            // 옛 정적 마스터에 같은 원문이 있으면 번역을 그대로 얹는다.
            // 없으면 빈칸 그대로다 -- 사람이 배치 도구를 따로 돌리지 않아도
            // 이미 번역된 대사가 미스로 등록되면서 빈칸이 되는 일이 없어진다.
            if (ApplyLegacyTranslation(row, item)) legacyFilled++;
            InsertCapturedRow(row, item);
            duplicateConflictCache = null;
            auditStatusCache = null;
            added++;
        }

        if (added > 0)
        {
            master.Dirty = true;
            SaveAll(false);
            searchBox.Clear();
            sceneFilter.SelectedItem = "전체";
            rowFilter.SelectedItem = "초록 · 신규 누락";
            RefreshMasterGridKeeping(firstAddedIndex);
            UpdateTitle();
        }

        MessageBox.Show($"MISS/NEAR {added}건을 대사 편집에 추가했습니다. 이미 추가된 항목: {alreadyAdded}건.\n번역 후 저장하면 초록 표시가 해제됩니다.");
        return added > 0 || resolvedToStatic > 0;
    }

    /// <summary>
    /// Place a captured row where it belongs instead of at the end of the file.
    ///
    /// A fragment carries the trie state it was seen in, and the build's record
    /// table names the parent: the record whose <c>next_state</c> equals it.
    /// Appending instead -- which is what happened until now -- leaves the
    /// fragment as its own text_key at line_no 1, so the build puts it at the
    /// root state where it matches anywhere and can never be told apart from
    /// the same fragment in another scene.  Every one of the 567 RUNTIME_ rows
    /// in MASTER ended up that way.
    ///
    /// Falls back to appending when no parent is known; a root-state line has
    /// no parent by definition and is correct at the end.
    /// </summary>
    private void InsertCapturedRow(List<string> row, AuditItem item)
    {
        var parent = FindParentRowIndex(item);
        // The trie chain only reaches back while the capture carries a non-root
        // state, so the first line of a window has nothing to hang from.  That
        // is fine when the whole window is new -- both halves import together
        // and stay adjacent.  It is not fine when the head is already in MASTER
        // from static extraction: only the tail imports, the state is root, and
        // the tail lands at the end of the file where nobody can read it.
        //   <원문 18자>   already in MASTER, x9
        //   <원문 5자>。                            imported alone, appended
        // So fall back to the line this capture was seen finishing.
        if (parent < 0) parent = FindContinuedRowIndex(item);
        if (parent < 0) { master.Rows.Add(row); return; }

        var parentRow = master.Rows[parent];
        var key = master.Get(parentRow, "text_key");

        // Sit directly under the last line of the parent's group, numbered next.
        var last = parent;
        var nextLine = ParseInt(master.Get(parentRow, "line_no"), 1) + 1;
        for (var i = parent + 1; i < master.Rows.Count; i++)
        {
            if (master.Get(master.Rows[i], "text_key") != key) break;
            last = i;
            nextLine = ParseInt(master.Get(master.Rows[i], "line_no"), 1) + 1;
        }

        // Engine invariant: one visible page has at most three body rows.
        // record_seq may continue across pages, but text_key is a page ID.
        // A fourth captured tail therefore starts a fresh page instead of
        // silently creating key:4 and asking the builder to guess the split.
        if (nextLine > 3)
        {
            master.Set(row, "line_no", "1");
            master.Rows.Add(row);
            return;
        }

        master.Set(row, "text_key", key);
        master.Set(row, "line_no", nextLine.ToString());
        master.Set(row, "source_refs", $"{master.Get(parentRow, "source_refs")};runtime_state={item.State}:seq={item.FirstSeq}");
        master.Rows.Insert(last + 1, row);
    }

    /// <summary>
    /// The MASTER row holding the line this capture was observed finishing.
    ///
    /// AuditEngine records the preceding capture only when that capture said
    /// CONT/BR, so this never links two unrelated sentences.  The head may sit
    /// in MASTER many times over (the same line recurs in several scenes); any
    /// of them puts the tail in readable company, so take the first, preferring
    /// one that is already translated since that is the most useful neighbour.
    /// </summary>
    private int FindContinuedRowIndex(AuditItem item)
    {
        var head = item.ContinuesFrom;
        if (string.IsNullOrWhiteSpace(head)) return -1;
        var wanted = AuditEngine.VisibleNormalize(head);
        var best = -1;
        for (var i = 0; i < master.Rows.Count; i++)
        {
            if (AuditEngine.VisibleNormalize(master.Get(master.Rows[i], "jp_text")) != wanted) continue;
            if (master.Get(master.Rows[i], "ko_text").Trim().Length > 0) return i;
            if (best < 0) best = i;
        }
        return best;
    }

    /// <summary>
    /// The MASTER row whose build record advances into this capture's state.
    /// </summary>
    private int FindParentRowIndex(AuditItem item)
    {
        var state = item.State.Trim();
        if (state.Length == 0 || state.TrimStart('0').Length == 0) return -1;   // root has no parent

        var records = BuildRecordsPath();
        if (records == null) return -1;

        string? parentRef = null;
        try
        {
            var doc = TsvDocument.Load(records);
            foreach (var record in doc.Rows)
            {
                if (!doc.Get(record, "next_state").Trim().Equals(state, StringComparison.OrdinalIgnoreCase)) continue;
                parentRef = doc.Get(record, "reference").Split(',').FirstOrDefault()?.Trim();
                break;
            }
        }
        catch (IOException) { return -1; }
        if (string.IsNullOrEmpty(parentRef)) return -1;

        // reference is text_key:line_no
        var cut = parentRef.LastIndexOf(':');
        if (cut <= 0) return -1;
        var key = parentRef[..cut];
        var line = parentRef[(cut + 1)..];
        return master.Rows.FindIndex(r =>
            master.Get(r, "text_key") == key && master.Get(r, "line_no") == line);
    }

    private string? BuildRecordsPath()
    {
        if (buildVersion.SelectedItem == null) return null;
        var path = Path.Combine(ResolveHomeProjectRoot() ?? root, "build", "patch",
            buildVersion.SelectedItem.ToString()!, "direct_records.tsv");
        return File.Exists(path) ? path : null;
    }

    private List<int> FindStaticExactRows(string japanese) => master.Rows
        .Select((row, index) => new { row, index })
        .Where(item => !master.Get(item.row, "text_key").StartsWith("RUNTIME_", StringComparison.Ordinal)
            && master.Get(item.row, "jp_text").Equals(japanese, StringComparison.Ordinal))
        .Select(item => item.index)
        .ToList();

    private HashSet<string> RuntimeImportedSourceKeys()
    {
        const string marker = "source_hex=";
        var result = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var row in master.Rows)
        {
            var note = master.Get(row, "note");
            var start = note.IndexOf(marker, StringComparison.OrdinalIgnoreCase);
            if (start < 0) continue;
            var value = note[(start + marker.Length)..];
            var end = value.IndexOf(';');
            var sourceHex = (end >= 0 ? value[..end] : value).Trim();
            if (sourceHex.Length == 0) continue;
            var state = Regex.Match(master.Get(row, "source_refs"), @"state=([0-9A-Fa-f]+)").Groups[1].Value;
            if (state.Length == 0) state = Regex.Match(master.Get(row, "text_key"), @"^RUNTIME_([0-9A-Fa-f]+)_").Groups[1].Value;
            if (state.Length == 0) state = "0000";
            var control = master.Get(row, "after_control").Trim().ToUpperInvariant();
            if (control is not ("BR" or "PAGE" or "CONT" or "END")) control = "END";
            result.Add($"{state.ToUpperInvariant()}|{control}|{sourceHex.ToUpperInvariant()}");
        }
        return result;
    }

    private void OpenOrImportStaticAudit(
        AuditItem item, TsvDocument doc, DataGridView grid, TabPage page,
        string japaneseColumn, string koreanColumn, string idColumn, string idPrefix)
    {
        var sourceIndex = doc.Rows.FindIndex(row =>
            doc.Get(row, japaneseColumn).Equals(item.Japanese, StringComparison.Ordinal));

        if (sourceIndex < 0)
        {
            var row = Enumerable.Repeat("", doc.Headers.Count).ToList();
            var nextNumber = doc.Rows
                .Select(value => Regex.Match(doc.Get(value, idColumn), @"(\d+)$"))
                .Where(match => match.Success)
                .Select(match => int.Parse(match.Groups[1].Value))
                .DefaultIfEmpty(0)
                .Max() + 1;
            doc.Set(row, idColumn, $"{idPrefix}{nextNumber:0000}");
            if (doc.Column("category") >= 0) doc.Set(row, "category", "runtime");
            doc.Set(row, japaneseColumn, item.Japanese);
            doc.Set(row, koreanColumn, "");
            doc.Set(row, "status", "todo");
            doc.Set(row, "note", $"[RUNTIME_UI_UNEDITED] {item.Classification} 자동 등록; source_hex={item.SourceHex}; state={item.State}; first_seq={item.FirstSeq}");
            doc.Rows.Add(row);
            doc.Dirty = true;
            sourceIndex = doc.Rows.Count - 1;
            PopulateStaticTables();
            UpdateTitle();
        }

        mainTabs.SelectedTab = page;
        var displayRow = grid.Rows.Cast<DataGridViewRow>()
            .FirstOrDefault(row => row.Tag is int index && index == sourceIndex);
        if (displayRow != null)
        {
            grid.ClearSelection();
            displayRow.Selected = true;
            grid.CurrentCell = displayRow.Cells[Math.Max(0, grid.Columns[koreanColumn].Index)];
            grid.FirstDisplayedScrollingRowIndex = displayRow.Index;
            grid.BeginEdit(true);
        }
    }

    private void ImportAuditAsNewRow(AuditItem item)
    {
        var existingSources = RuntimeImportedSourceKeys();
        var sourceDuplicate = existingSources.Contains(RuntimeSourceIdentity(item))
            ? master.Rows.FindIndex(row => master.Get(row, "note").Contains($"source_hex={item.SourceHex}", StringComparison.OrdinalIgnoreCase)
                && master.Get(row, "after_control").Equals(item.AfterControl, StringComparison.OrdinalIgnoreCase))
            : -1;
        if (sourceDuplicate >= 0)
        {
            OpenMasterRow(sourceDuplicate, "이미 같은 런타임 원문 바이트가 등록되어 있습니다.");
            return;
        }

        var row = Enumerable.Repeat("", master.Headers.Count).ToList();
        master.Set(row, "text_key", RuntimeMissTextKey(item));
        master.Set(row, "line_no", "1");
        master.Set(row, "jp_text", item.Japanese);
        master.Set(row, "ko_text", "");
        master.Set(row, "after_control", item.AfterControl);
        master.Set(row, "status", "todo");
        master.Set(row, "source_refs", $"runtime_audit:state={item.State}:seq={item.FirstSeq}:after={item.AfterControl}");
        master.Set(row, "max_cells", "18");
        master.Set(row, "ko_cells", "0");
        master.Set(row, "ko_line", "0");
        master.Set(row, "ko_bytes", "0");
        master.Set(row, "byte_check", "OK");
        var nearNote = item.Classification == "NEAR"
            ? $"; nearest_jp={item.NearestJapanese}; similarity={item.Similarity:0.000}"
            : "";
        master.Set(row, "note", $"{RuntimeMissUneditedMarker} 런타임 {item.Classification} 자동 등록; after_control={item.AfterControl}; control_origin={item.ControlOrigin}; source_hex={item.SourceHex}; state={item.State}; first_seq={item.FirstSeq}{nearNote}");
        ApplyLegacyTranslation(row, item);
        master.Rows.Add(row);
        duplicateConflictCache = null;
        auditStatusCache = null;
        master.Dirty = true;
        UpdateTitle();
        OpenMasterRow(master.Rows.Count - 1, $"{item.Classification}를 대사 편집에 등록했습니다. 번역을 수정하기 전까지 초록색으로 표시됩니다.");
    }

    private void OpenAuditMasterRows(AuditItem item, List<int> candidates)
    {
        mainTabs.SelectedIndex = 0;
        searchBox.Clear();
        sceneFilter.SelectedItem = "전체";
        rowFilter.SelectedItem = item.Classification switch
        {
            "LOOKUP_FAIL" => "주황 · LOOKUP_FAIL",
            "ROUTE_FAIL" => "보라 · ROUTE_FAIL",
            "MASTER_ONLY" => "청회 · MASTER_ONLY",
            _ => "전체",
        };
        RefreshMasterGridKeeping(candidates[0]);
        MessageBox.Show($"{item.Classification}와 연결된 기존 MASTER 행 {candidates.Count}개를 대사 편집에 표시했습니다.");
    }

    private void OpenMasterRow(int index, string message)
    {
        mainTabs.SelectedIndex = 0;
        searchBox.Clear();
        sceneFilter.SelectedItem = "전체";
        rowFilter.SelectedItem = IsUneditedRuntimeMiss(master.Rows[index]) ? "초록 · 신규 누락" : "전체";
        RefreshMasterGridKeeping(index);
        MessageBox.Show(message);
    }


    // ---------------------------------------------------------------------
    // 새로 잡힌 대사에 옛 번역을 얹는다
    //
    // 현역 마스터는 런타임 관측 골격으로 바뀌었고, 정적 추출 7,204행은
    // legacy_static_master.tsv 로 내려갔다.  실시간 수집이 새 대사를 등록할 때
    // 그쪽에 같은 원문이 있으면 번역·검토표시·레이아웃 값을 그대로 가져온다.
    //
    // 원문 기준 매칭이 안전하다는 것은 실측이다 -- 검토 O 2,445행 중 2회 이상
    // 나오는 원문 375종에서 번역이 갈리는 것은 4종(98.9% 일치).
    // ---------------------------------------------------------------------
    private sealed record LegacyEntry(string Korean, string Review, string Cells,
                                      string Line, string Bytes, string Check,
                                      string Status, string Speaker);

    private Dictionary<string, LegacyEntry>? legacyIndex;

    private Dictionary<string, LegacyEntry> LegacyIndex()
    {
        if (legacyIndex != null) return legacyIndex;
        legacyIndex = new Dictionary<string, LegacyEntry>();
        var path = Path.Combine(translationDir, LegacyMasterFileName);
        if (!File.Exists(path)) return legacyIndex;
        try
        {
            var doc = TsvDocument.Load(path);
            // 검토 열은 헤더에 이름이 없다.  빈 헤더의 첫 자리를 쓴다.
            var reviewColumn = doc.Headers.FindIndex(h => string.IsNullOrEmpty(h));
            foreach (var row in doc.Rows)
            {
                var jp = doc.Get(row, "jp_text");
                var ko = doc.Get(row, "ko_text");
                if (jp.Length == 0 || ko.Length == 0 || ko == "{EMPTY}") continue;
                var key = AuditEngine.VisibleNormalize(jp);
                if (key.Length == 0) continue;
                var review = reviewColumn >= 0 && reviewColumn < row.Count
                    ? row[reviewColumn].Trim() : "";
                var entry = new LegacyEntry(ko, review,
                    doc.Get(row, "ko_cells"), doc.Get(row, "ko_line"),
                    doc.Get(row, "ko_bytes"), doc.Get(row, "byte_check"),
                    doc.Get(row, "status"), doc.Get(row, "speaker"));
                // 검토된 것이 이긴다.  같은 등급이면 먼저 본 것을 둔다.
                if (!legacyIndex.TryGetValue(key, out var had) || (review == "O" && had.Review != "O"))
                    legacyIndex[key] = entry;
            }
        }
        catch (IOException) { }
        return legacyIndex;
    }

    /// <summary>Fills a freshly captured row from the legacy master, if it is there.</summary>
    private bool ApplyLegacyTranslation(List<string> row, AuditItem item)
    {
        var key = AuditEngine.VisibleNormalize(item.Japanese);
        if (key.Length == 0 || !LegacyIndex().TryGetValue(key, out var hit)) return false;
        master.Set(row, "ko_text", hit.Korean);
        master.Set(row, "ko_cells", hit.Cells);
        master.Set(row, "ko_line", hit.Line);
        master.Set(row, "ko_bytes", hit.Bytes);
        master.Set(row, "byte_check", hit.Check.Length > 0 ? hit.Check : "OK");
        master.Set(row, "status", hit.Status.Length > 0 ? hit.Status : "ai_draft");
        if (master.Get(row, "speaker").Length == 0 && hit.Speaker.Length > 0)
            master.Set(row, "speaker", hit.Speaker);

        // 검토 O 는 물려받지 않는다.
        //
        // 여기서 가져오는 것은 **옛 마스터에서 같은 원문을 찾은 번역**이지, 사람이
        // 이 레코드를 보고 승인한 것이 아니다.  그런데 O 까지 같이 베끼면 아무도
        // 본 적 없는 행이 검토 완료로 들어앉는다.  그렇게 들어온 O 가 쌓여서,
        // 2026-08-22 중복 정리 때 같은 디스크 주소에 번역이 서로 다른 두 행이
        // **둘 다 O** 인 상태로 발견됐다 (50 자리).  둘 중 하나는 반드시 틀렸는데
        // 양쪽 다 "검토됨" 이었다.
        //
        // 빌더 주석이 이미 같은 규율을 적어 두었다 -- "조각으로 검토한 것이 합친
        // 문장의 보증이 될 수 없다" (build_runtime_master.py).  편입도 그것을
        // 지켜야 한다.  번역은 얹되 판단은 사람에게 남긴다.
        //
        // status 는 위에서 옛 값을 그대로 쓰므로 여기서 review 로 낮춘다 -- 번역이
        // 채워진 채 검토 큐에 올라오는 것이 이 행의 정확한 상태다.
        master.Set(row, "status", "review");
        var reviewColumn = master.Headers.FindIndex(h => string.IsNullOrEmpty(h));
        if (reviewColumn >= 0 && reviewColumn < row.Count) row[reviewColumn] = "";
        return true;
    }

    private static string RuntimeMissTextKey(AuditItem item)
    {
        uint hash = 2166136261;
        foreach (var ch in $"{item.State}|{item.AfterControl}|{item.SourceHex}")
        {
            hash ^= ch;
            hash *= 16777619;
        }
        var state = Regex.Replace(item.State ?? "", "[^0-9A-Fa-f]", "").ToUpperInvariant();
        if (state.Length == 0) state = "0000";
        return $"RUNTIME_{state}_{hash:X8}";
    }

    private static string RuntimeSourceIdentity(AuditItem item) =>
        $"{item.State.Trim().ToUpperInvariant()}|{item.AfterControl.Trim().ToUpperInvariant()}|{item.SourceHex.Trim().ToUpperInvariant()}";

    private bool IsUneditedRuntimeMiss(List<string> row) =>
        master.Get(row, "note").Contains(RuntimeMissUneditedMarker, StringComparison.Ordinal);

    private void RemoveRuntimeMissMarker(List<string> row)
    {
        var note = master.Get(row, "note");
        master.Set(row, "note", note.Replace(RuntimeMissUneditedMarker, "", StringComparison.Ordinal).TrimStart());
    }

    private Dictionary<int, HashSet<string>> AuditStatusesByMasterIndex()
    {
        if (auditStatusCache != null) return auditStatusCache;
        var result = new Dictionary<int, HashSet<string>>();
        foreach (var item in auditItems.Where(value => value.Classification != "HIT"))
            foreach (var index in MasterIndicesForAudit(item))
            {
                if (!result.TryGetValue(index, out var statuses))
                {
                    statuses = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
                    result[index] = statuses;
                }
                statuses.Add(item.Classification);
            }
        auditStatusCache = result;
        return result;
    }

    private static HashSet<int> AuditIndices(Dictionary<int, HashSet<string>> statusesByIndex, string classification) =>
        statusesByIndex.Where(pair => pair.Value.Contains(classification)).Select(pair => pair.Key).ToHashSet();

    private static int AuditStatusOrder(string classification) => classification switch
    {
        "LOOKUP_FAIL" => 0,
        "ROUTE_FAIL" => 1,
        "MASTER_ONLY" => 2,
        "NEAR" => 3,
        "MISS" => 4,
        _ => 9,
    };

    // Write the captured MPR6 bank onto every MASTER row the capture matched.
    // Matching is on the Japanese source bytes, so simply replaying a scene
    // fills in rows that were collected before the Lua recorded a pack -- no
    // retranslation, no manual tagging.  Only rows that are still blank are
    // touched: an existing value came from an earlier observation of the same
    // line and there is no reason to trust this one more.
    private void StampPacksFromAudit(IReadOnlyList<AuditItem> items)
    {
        if (master.Column("pack") < 0) return;
        var stamped = 0;
        foreach (var item in items)
        {
            if (item.Pack.Length == 0 || item.Pack == "??") continue;
            foreach (var index in MasterIndicesForAudit(item))
            {
                var row = master.Rows[index];
                if (master.Get(row, "pack").Length > 0) continue;
                master.Set(row, "pack", item.Pack);
                stamped++;
            }
        }
        if (stamped == 0) return;
        master.Dirty = true;
        UpdateTitle();
        auditSummary.Text += $" · 팩 기록 {stamped:N0}";
    }

    // 화자를 같은 방식으로 마스터에 새긴다.  게임이 화자명을 대사와 같은
    // 스트림으로 흘리므로 AuditEngine 이 원시 로그 순서에서 귀속을 끝내 두었고,
    // 여기서는 그 결과를 원문 일치 행에 옮기기만 한다.  Lua 는 손대지 않았으니
    // 예전 로그를 다시 임포트해도 똑같이 채워진다 -- 재수집이 필요 없다.
    private void StampSpeakersFromAudit(IReadOnlyList<AuditItem> items)
    {
        if (master.Column("speaker") < 0) return;
        var stamped = 0;
        foreach (var item in items)
        {
            if (item.Speaker.Length == 0) continue;
            foreach (var index in MasterIndicesForAudit(item))
            {
                var row = master.Rows[index];
                if (master.Get(row, "speaker").Length > 0) continue;
                master.Set(row, "speaker", item.Speaker);
                stamped++;
            }
        }
        if (stamped == 0) return;
        master.Dirty = true;
        UpdateTitle();
        auditSummary.Text += $" · 화자 기록 {stamped:N0}";
    }

    private List<int> MasterIndicesForAudit(AuditItem item)
    {
        var references = item.References.Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
        var result = new List<int>();
        for (var i = 0; i < master.Rows.Count; i++)
        {
            var row = master.Rows[i];
            var rowId = $"{master.Get(row, "text_key")}:{master.Get(row, "line_no")}";
            var sourceRefs = master.Get(row, "source_refs");
            var exactJapanese = master.Get(row, "jp_text") == item.Japanese;
            var referenceMatch = references.Any(reference =>
                rowId.Equals(reference, StringComparison.OrdinalIgnoreCase) ||
                sourceRefs.Contains(reference, StringComparison.OrdinalIgnoreCase) ||
                reference.Contains(rowId, StringComparison.OrdinalIgnoreCase));
            if (exactJapanese || referenceMatch) result.Add(i);
        }
        return result;
    }

    private void StartAuditWatch()
    {
        if (shuttingDown) return;
        StopAuditWatch();
        var dir = ResolveAuditDirectory();
        var voiceLogPath = ResolveVoiceLogPath();
        var voiceDir = Path.GetDirectoryName(voiceLogPath)!;
        var uiLogPath = Path.Combine(dir, RuntimeUiFileName);
        Directory.CreateDirectory(dir);
        Directory.CreateDirectory(voiceDir);
        watcher = new FileSystemWatcher(dir, RuntimeAuditFileName) { NotifyFilter = NotifyFilters.LastWrite | NotifyFilters.Size | NotifyFilters.CreationTime, EnableRaisingEvents = true };
        watcher.Changed += OnAuditFileChanged;
        watcher.Created += OnAuditFileChanged;
        voiceWatcher = new FileSystemWatcher(voiceDir, Path.GetFileName(voiceLogPath)) { NotifyFilter = NotifyFilters.LastWrite | NotifyFilters.Size | NotifyFilters.CreationTime, EnableRaisingEvents = true };
        voiceWatcher.Changed += OnAuditFileChanged;
        voiceWatcher.Created += OnAuditFileChanged;
        uiWatcher = new FileSystemWatcher(dir, Path.GetFileName(uiLogPath)) { NotifyFilter = NotifyFilters.LastWrite | NotifyFilters.Size | NotifyFilters.CreationTime, EnableRaisingEvents = true };
        uiWatcher.Changed += OnAuditFileChanged;
        uiWatcher.Created += OnAuditFileChanged;
        auditSummary.Text = "통합 감시 중 · 대사 + 음성";
        AnalyzeAudit(true);
        ImportVoiceLog(false);
        ImportRuntimeUiCapture(false);
    }
    private void OnAuditFileChanged(object sender, FileSystemEventArgs e)
    {
        if (shuttingDown || IsDisposed || Disposing || !IsHandleCreated) return;
        try
        {
            BeginInvoke(new Action(() =>
            {
                if (shuttingDown || IsDisposed || Disposing) return;
                if (string.Equals(e.Name, "voice_events_raw.tsv", StringComparison.OrdinalIgnoreCase))
                {
                    voiceDebounce.Stop();
                    voiceDebounce.Start();
                }
                else if (string.Equals(e.Name, RuntimeUiFileName, StringComparison.OrdinalIgnoreCase))
                {
                    uiDebounce.Stop();
                    uiDebounce.Start();
                }
                else
                {
                    auditDebounce.Stop();
                    auditDebounce.Start();
                }
            }));
        }
        catch (InvalidOperationException) { }
    }
    private void StopAuditWatch()
    {
        var activeWatcher = watcher;
        var activeVoiceWatcher = voiceWatcher;
        var activeUiWatcher = uiWatcher;
        watcher = null;
        voiceWatcher = null;
        uiWatcher = null;
        if (activeWatcher != null)
        {
            activeWatcher.EnableRaisingEvents = false;
            activeWatcher.Changed -= OnAuditFileChanged;
            activeWatcher.Created -= OnAuditFileChanged;
            activeWatcher.Dispose();
        }
        if (activeVoiceWatcher != null)
        {
            activeVoiceWatcher.EnableRaisingEvents = false;
            activeVoiceWatcher.Changed -= OnAuditFileChanged;
            activeVoiceWatcher.Created -= OnAuditFileChanged;
            activeVoiceWatcher.Dispose();
        }
        if (activeUiWatcher != null)
        {
            activeUiWatcher.EnableRaisingEvents = false;
            activeUiWatcher.Changed -= OnAuditFileChanged;
            activeUiWatcher.Created -= OnAuditFileChanged;
            activeUiWatcher.Dispose();
        }
        auditDebounce.Stop();
        voiceDebounce.Stop();
        uiDebounce.Stop();
    }

    private void ClearAuditSessionLog(bool confirm = true, bool showMessage = true)
    {
        if (confirm)
        {
            var answer = MessageBox.Show(
                "이번 플레이 세션의 원시 감사 로그와 화면 목록을 비웁니다.\n\n" +
                "삭제가 아니라 보관입니다. 원시 로그와 목록을 logs\audit_archive로 옮깁니다.",
                "세션 로그 삭제",
                MessageBoxButtons.YesNo,
                MessageBoxIcon.Warning);
            if (answer != DialogResult.Yes) return;
        }

        StopAuditWatch();
        var auditDir = ResolveAuditDirectory();
        var paths = new[]
        {
            Path.Combine(auditDir, RuntimeAuditFileName),
            Path.Combine(auditDir, "runtime_text_audit_report.tsv"),
        };
        // The raw log is the only record of what the game actually rendered, and
        // "대사 포함" clears the session right after importing.  Discarding it
        // there leaves no way to check afterwards where a captured line ended up,
        // so archive it beside the catalog instead of deleting.
        var archiveRoot = Path.Combine(root, "logs", "audit_archive");
        Directory.CreateDirectory(archiveRoot);
        var stamp = DateTime.Now.ToString("yyyyMMdd_HHmmss");
        var deleted = 0;
        foreach (var path in paths)
        {
            try
            {
                if (!File.Exists(path)) continue;
                var name = Path.GetFileNameWithoutExtension(path);
                File.Move(path, Path.Combine(archiveRoot, $"{name}_{stamp}.tsv"), true);
                deleted++;
            }
            catch (IOException ex)
            {
                if (showMessage)
                    MessageBox.Show($"파일이 아직 사용 중이라 정리하지 못했습니다. Mesen Lua를 먼저 중지해 주세요.\n\n{path}\n{ex.Message}", "세션 로그 삭제");
                return;
            }
        }
        // The active catalog is what keeps old results in the visible list.
        // Archive it rather than discard it, then begin the new session with
        // an empty in-memory grid.
        var catalogPath = ResolveAuditCatalogPath();
        if (File.Exists(catalogPath))
        {
            var archiveDir = Path.Combine(root, "logs", "audit_archive");
            Directory.CreateDirectory(archiveDir);
            var archivePath = Path.Combine(archiveDir, $"runtime_text_catalog_{DateTime.Now:yyyyMMdd_HHmmss}.tsv");
            File.Move(catalogPath, archivePath, true);
            deleted++;
        }
        auditItems = new List<AuditItem>();
        auditStatusCache = null;
        RefreshAuditGrid();
        if (showMessage)
            MessageBox.Show($"세션을 정리했습니다 ({deleted}개). 다음 플레이에서 Lua가 새 로그를 만듭니다.\n원시 로그와 목록을 지우지 않고 logs\\audit_archive에 보관했습니다.", "세션 로그 삭제");
    }

    private void ShutdownBackgroundServices()
    {
        if (shuttingDown) return;
        shuttingDown = true;
        StopAuditWatch();
        auditDebounce.Dispose();
        voiceDebounce.Dispose();
        uiDebounce.Dispose();
        // 검색 디바운스는 폼 종료 전에 모두 정리한다.
        masterSearchDebounce.Stop(); masterSearchDebounce.Dispose();
        uiSearchDebounce.Stop(); uiSearchDebounce.Dispose();
        voiceSearchDebounce.Stop(); voiceSearchDebounce.Dispose();
        cddaSearchDebounce.Stop(); cddaSearchDebounce.Dispose();
        subtitlePlaybackTimer.Stop(); subtitlePlaybackTimer.Dispose();
        clipPlayer.Dispose();
    }
    private void ExportTranslationQueue()
    {
        if (auditItems.Count == 0) AnalyzeAudit(false); var queue = auditItems.Where(x => x.Classification is "MASTER_ONLY" or "NEAR" or "MISS").ToList();
        var path = Path.Combine(ResolveAuditDirectory(), $"runtime_translation_queue_{DateTime.Now:yyyyMMdd_HHmmss}.tsv"); AuditEngine.Export(path, queue); MessageBox.Show($"번역 큐 {queue.Count}건 저장\n{path}");
    }

    private string ResolveAuditDirectory()
    {
        var projectRoot = ResolveHomeProjectRoot();
        return Path.Combine(projectRoot ?? root, "dump");
    }

    private string ResolveAuditCatalogPath()
    {
        return Path.Combine(root, "logs", "runtime_text_catalog.tsv");
    }

    private string ResolveVoiceLogPath()
    {
        var portable = Path.Combine(root, "logs", "voice_events_raw.tsv");
        if (File.Exists(portable) || Directory.Exists(Path.GetDirectoryName(portable))) return portable;

        var projectRoot = ResolveHomeProjectRoot();
        if (projectRoot != null)
            return Path.Combine(projectRoot, "snatcher_tool", "logs", "voice_events_raw.tsv");
        return portable;
    }

    private string ResolveAuditLuaDirectory()
    {
        var portable = Path.Combine(root, "mesen");
        if (File.Exists(Path.Combine(portable, "runtime_text_audit.lua"))) return portable;

        var projectRoot = ResolveHomeProjectRoot();
        if (projectRoot != null)
        {
            var projectPortable = Path.Combine(projectRoot, "snatcher_tool", "mesen");
            if (File.Exists(Path.Combine(projectPortable, "runtime_text_audit.lua"))) return projectPortable;
        }
        return portable;
    }

    private string? ResolveHomeProjectRoot()
    {
        var candidates = new[] { Directory.GetParent(root)?.FullName, root, @"C:\snatcher" }
            .Where(path => !string.IsNullOrWhiteSpace(path)).Distinct(StringComparer.OrdinalIgnoreCase);
        return candidates.FirstOrDefault(path =>
            File.Exists(Path.Combine(path!, "extraction", "patch", "static", "build_direct_overlay_patch.py")) &&
            Directory.Exists(Path.Combine(path!, "build", "patch")));
    }

    private void SaveAll(bool showMessage = true)
    {
        ApplyCurrent(); ApplyUiCurrent(); ApplyVoiceSubtitleCurrent(); var saved = new List<string>();
        foreach (var doc in new[] { master, speakers, ui, voiceEvents, voiceSubtitles, cddaSubs }) if (doc.Dirty) { doc.Save(backupDir); saved.Add(Path.GetFileName(doc.Path)); }
        Text = "Snatcher 한국어 패치 스튜디오";
        if (showMessage) MessageBox.Show(saved.Count == 0 ? "변경 사항이 없습니다." : "저장 및 백업 완료\n" + string.Join("\n", saved));
    }
    private void OnClosing(object? sender, FormClosingEventArgs e)
    {
        ApplyCurrent(); ApplyUiCurrent(); ApplyVoiceSubtitleCurrent();
        if (master.Dirty || speakers.Dirty || ui.Dirty || voiceEvents.Dirty || voiceSubtitles.Dirty || cddaSubs.Dirty)
        {
            var answer = MessageBox.Show("변경 내용을 저장할까요?", "종료", MessageBoxButtons.YesNoCancel);
            if (answer == DialogResult.Cancel) { e.Cancel = true; return; }
            if (answer == DialogResult.Yes) SaveAll();
        }
        ShutdownBackgroundServices();
    }
    private void UpdateTitle() { if (master.Dirty || speakers.Dirty || ui.Dirty || voiceEvents.Dirty || voiceSubtitles.Dirty) Text = "Snatcher 한국어 패치 스튜디오 *"; }


    /// <summary>소리 파일 이름으로 일본어 원문을 붙인다.</summary>
    /// <remarks>
    /// logs/voice_transcript.tsv 는 클립 하나당 한 줄이고 clip_file 이 열쇠다.
    /// clip_file 은 내용 지문이라 세션이 달라도 같은 소리면 같은 값이다.
    /// event_id 나 sequence 로 이으면 안 된다 -- 순번은 세션마다 다시 1 부터
    /// 매겨지므로 다른 세션끼리는 전혀 다른 소리에 붙는다.
    /// </remarks>
    private void LoadVoiceTranscript()
    {
        // 먼저 소리 파일 이름을 확보한다.  voice_events.tsv 의 clip_file 이 비어
        // 있어도, 원시 로그가 그 event_id 에 대해 적어 두었으면 그것을 쓴다.
        // event_id 는 세션 안에서 유일하므로 이 연결은 추측이 아니다.
        // (sequence 로 잇는 것과 다르다 -- 순번은 세션마다 다시 1 부터 매겨진다.)
        var rawPath = ResolveVoiceLogPath();
        if (File.Exists(rawPath))
        {
            var raw = TsvDocument.Load(rawPath);
            if (raw.Column("event_id") >= 0 && raw.Column("clip_file") >= 0)
            {
                var clipById = new Dictionary<string, string>(StringComparer.Ordinal);
                foreach (var row in raw.Rows)
                {
                    var id = raw.Get(row, "event_id");
                    var clip = raw.Get(row, "clip_file");
                    if (id.Length > 0 && clip.Length > 0) clipById[id] = clip;
                }
                foreach (var row in voiceEvents.Rows)
                {
                    if (voiceEvents.Get(row, "clip_file").Length > 0) continue;
                    if (clipById.TryGetValue(voiceEvents.Get(row, "event_id"), out var clip))
                        voiceEvents.Set(row, "clip_file", clip);
                }
            }
        }

        var path = Path.Combine(root, "logs", "voice_transcript.tsv");
        if (!File.Exists(path)) return;
        var transcript = TsvDocument.Load(path);
        if (transcript.Column("clip_file") < 0 || transcript.Column("jp_whisper") < 0) return;
        var japanese = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (var row in transcript.Rows)
        {
            var clip = transcript.Get(row, "clip_file");
            var text = transcript.Get(row, "jp_whisper");
            if (clip.Length > 0 && text.Length > 0) japanese[clip] = text;
        }
        foreach (var row in voiceEvents.Rows)
        {
            var clip = voiceEvents.Get(row, "clip_file");
            if (clip.Length > 0 && japanese.TryGetValue(clip, out var text))
                voiceEvents.Set(row, "jp_whisper", text);
        }
    }

    /// <summary>선택한 행의 소리를 재생한다.</summary>
    /// <remarks>
    /// clip_file 은 "v&lt;지문&gt;.bin" 이고 같은 이름의 .wav 가
    /// logs/voice_clips_wav/ 에 있다.  ADPCM 클립만 파일이 있다 --
    /// CD-DA 는 디스크 트랙이라 logs/cdda/ 에 트랙 통째로 들어 있다.
    /// </remarks>
    private void PlaySelectedVoiceClip()
    {
        voiceSubtitleGrid.EndEdit();
        if (voiceEventGrid.SelectedRows.Count == 0) { voiceSummary.Text = "먼저 행을 고르세요"; return; }
        if (voiceEventGrid.SelectedRows[0].Tag is not List<string> row) return;
        var clip = voiceEvents.Get(row, "clip_file");
        if (clip.Length == 0)
        {
            voiceSummary.Text = "이 행에는 소리 파일이 없다 (0.2.2 이전 세션)";
            return;
        }
        var wav = Path.Combine(root, "logs", "voice_clips_wav",
                               Path.GetFileNameWithoutExtension(clip) + ".wav");
        if (!File.Exists(wav)) { voiceSummary.Text = "소리 파일이 없다: " + Path.GetFileName(wav); return; }
        try
        {
            RefreshVoiceTimeline();
            voiceSummary.Text = StartClip(wav, voiceTimeline, SelectedVoiceDuration());
        }
        catch (Exception error) { voiceSummary.Text = "재생 실패: " + error.Message; }
    }

    /// <summary>F5와 ▶/⏸ 단추가 부르는 것.</summary>
    /// <remarks>
    /// 아무것도 안 물려 있으면 아무 일도 안 한다 -- 무엇을 틀지는 목록에서
    /// 고르는 것이지 스페이스바가 정할 일이 아니다.
    /// </remarks>
    private void TogglePlayback()
    {
        if (clipPlayer.Path == null) return;
        clipPlayer.Toggle();
        if (clipPlayer.IsPlaying) subtitlePlaybackTimer.Start();
        else subtitlePlaybackTimer.Stop();
        activeSubtitleTimeline?.Invalidate();
    }

    private void StopVoiceClip()
    {
        try { clipPlayer.Stop(); }
        catch { /* 이미 끝났으면 무시한다 */ }
        subtitlePlaybackTimer.Stop();
        subtitlePlaybackClock.Reset();
        if (activeSubtitleTimeline != null) { activeSubtitleTimeline.PositionSeconds = 0; activeSubtitleTimeline.Invalidate(); }
        activeSubtitleTimeline = null;
    }

    /// <summary>공용 재생기에 파일을 물리고 타임라인을 실제 재생 위치와 묶는다.</summary>
    private string StartClip(string wav, SubtitleTimeline timeline, double duration)
    {
        StopVoiceClip();
        if (!clipPlayer.Open(wav, out var error))
            throw new InvalidOperationException(error.Length > 0 ? error : "소리 파일을 열 수 없다");
        clipPlayer.HintLength(duration);
        clipPlayer.Play();
        StartSubtitleTimeline(timeline, duration);
        return $"▶ {Path.GetFileName(wav)}"
               + (clipPlayer.Degraded ? " · 자리 이동 제한(SoundPlayer)" : "");
    }

    private void StartSubtitleTimeline(SubtitleTimeline timeline, double duration)
    {
        timeline.DurationSeconds = Math.Max(0.01, duration);
        timeline.PositionSeconds = 0;
        timeline.Invalidate();
        activeSubtitleTimeline = timeline;
        subtitlePlaybackClock.Restart();
        subtitlePlaybackTimer.Start();
    }

    private void TickSubtitleTimeline()
    {
        if (activeSubtitleTimeline == null) return;
        // 스톱워치 추측이 아니라 재생 장치가 보고한 실제 위치를 쓴다.
        activeSubtitleTimeline.PositionSeconds = clipPlayer.PositionSeconds;
        if (activeSubtitleTimeline.PositionSeconds >= activeSubtitleTimeline.DurationSeconds)
        {
            activeSubtitleTimeline.PositionSeconds = activeSubtitleTimeline.DurationSeconds;
            subtitlePlaybackTimer.Stop();
            subtitlePlaybackClock.Stop();
        }
        // ★ 확대 모드가 아니라 **따라가기 스위치**로 건다 (2026-09-07).  확대는
        //   "크게 본다" 는 뜻이지 "화면이 저 혼자 움직인다" 는 뜻이 아니었다.
        if (ReferenceEquals(activeSubtitleTimeline, cddaTimeline) && cddaFollowPlayback.Checked)
            FollowCddaPlayback();
        activeSubtitleTimeline.Invalidate();
    }

    private void RefreshVoiceTimeline()
    {
        var eventId = SelectedVoiceEventId();
        voiceTimeline.DurationSeconds = Math.Max(0.01, SelectedVoiceDuration());
        voiceTimeline.Spans = voiceSubtitles.Rows
            .Where(r => voiceSubtitles.Get(r, "event_id") == eventId)
            .Select(r => new SubtitleTimeline.Span(ParseDouble(voiceSubtitles.Get(r, "start_sec")),
                ParseDouble(voiceSubtitles.Get(r, "duration_sec")),
                BlockLabel(voiceSubtitles.Get(r, "part"), voiceSubtitles.Get(r, "ko_text")), r)).ToList();
        voiceTimeline.SelectByTag(currentVoiceSubtitleRow);
        voiceTimeline.Invalidate();
    }

    // ===================== 타임라인에서 끌어 싱크 맞추기 =====================
    //
    // 숫자 입력은 그대로 둔다.  이것은 대체가 아니라 추가다 -- 0.2 초를 당기고
    // 싶을 때 숫자를 얼마로 고쳐야 하는지는 귀로 알 수 없지만, 블록을 보고 끌면
    // 바로 맞출 수 있다.  정밀하게 박을 때는 여전히 숫자 칸이 빠르다.
    //
    // 끄는 중에 그리드 칸을 고치면 CellValueChanged -> RefreshVoiceTimeline 이
    // 돌아 Spans 가 다시 만들어진다.  잡고 있던 블록이 그 순간 사라지므로,
    // 컨트롤이 끄는 동안 Spans 대입을 무시한다 (SubtitleTimeline.IsDragging).
    // 여기서는 그 위에 한 겹 더 둔다 -- 끄는 동안에는 무거운 전체 갱신을 아예
    // 부르지 않는다.
    private bool draggingSubtitleBlock;

    private static string BlockLabel(string part, string koText)
    {
        var text = (koText ?? "").Replace("\n", " ").Trim();
        if (text.Length > 24) text = text[..24] + "…";
        return text.Length == 0 ? part : part + "  " + text;
    }

    /// <summary>끄는 중 · 놓았을 때 공통.  행과 그리드 칸에 값을 같이 쓴다.</summary>
    private void WriteSpanTimes(TsvDocument document, DataGridView grid, object? tag,
                                double start, double duration)
    {
        if (tag is not List<string> row) return;
        document.Set(row, "start_sec", start.ToString("0.000"));
        document.Set(row, "duration_sec", duration.ToString("0.000"));
        document.Dirty = true;
        // 그리드 칸도 같이 갱신한다 -- 숫자로도 볼 수 있어야 한다는 것이 요구다.
        // CellValueChanged 가 도로 타임라인을 갱신하지 않도록 깃발을 든 채로 쓴다.
        foreach (DataGridViewRow gridRow in grid.Rows)
        {
            if (!ReferenceEquals(gridRow.Tag, row)) continue;
            gridRow.Cells["start_sec"].Value = start.ToString("0.000");
            gridRow.Cells["duration_sec"].Value = duration.ToString("0.000");
            break;
        }
    }

    private void WireSubtitleTimelines()
    {
        // 노란 재생 머리를 끌면 소리도 같은 자리로 보낸다.
        void WireSeeking(SubtitleTimeline timeline)
        {
            timeline.Seeking += seconds =>
            {
                clipPlayer.Seek(seconds);
                timeline.PositionSeconds = seconds;
                timeline.Invalidate();
            };
            timeline.Seeked += seconds => clipPlayer.Seek(seconds);
        }
        WireSeeking(voiceTimeline);
        WireSeeking(cddaTimeline);

        // 끌면 이웃도 같이 바뀐다 (겹치지 않게 밀어낸다).  그래서 목록으로 온다.
        voiceTimeline.SpanDragging += edits =>
        {
            draggingSubtitleBlock = true;
            foreach (var edit in edits)
                WriteSpanTimes(voiceSubtitles, voiceSubtitleGrid, edit.Tag, edit.Start, edit.Duration);
        };
        voiceTimeline.SpanDragged += edits =>
        {
            draggingSubtitleBlock = false;
            foreach (var edit in edits)
                WriteSpanTimes(voiceSubtitles, voiceSubtitleGrid, edit.Tag, edit.Start, edit.Duration);
            ValidateVoiceSubtitleTimeline();
            RefreshVoiceTimeline();
            UpdateTitle();
        };
        voiceTimeline.SelectionChanged += tag => SelectGridRowByTag(voiceSubtitleGrid, tag);

        cddaTimeline.SpanDragging += edits =>
        {
            draggingSubtitleBlock = true;
            foreach (var edit in edits)
                WriteSpanTimes(cddaSubs, cddaPartGrid, edit.Tag, edit.Start, edit.Duration);
        };
        cddaTimeline.SpanDragged += edits =>
        {
            draggingSubtitleBlock = false;
            foreach (var edit in edits)
                WriteSpanTimes(cddaSubs, cddaPartGrid, edit.Tag, edit.Start, edit.Duration);
            RefreshCddaTimeline();
            UpdateTitle();
        };
        // 블록을 눌러 고른 경우에는 확대 창을 다시 맞추지 않는다.  이 이벤트는
        // MouseDown 도중에 뜨고, 여기서 창을 옮기면 곧바로 시작될 드래그가
        // **바뀐 좌표계 위에서** 돌아 블록이 커서 밑에서 튄다.
        cddaTimeline.SelectionChanged += tag =>
        {
            selectingCddaFromTimeline = true;
            try { SelectGridRowByTag(cddaPartGrid, tag); }
            finally { selectingCddaFromTimeline = false; }
        };

        // 막대·휠로 사람이 창을 옮겼다.  "더 확대 / 더 넓게" 가 다음에 쓸 폭을
        // 여기서 맞춰 둔다 -- 안 그러면 버튼이 옛 배율에서 다시 시작한다.
        cddaTimeline.ViewChanged += (_, duration) =>
            cddaFocusWindowSeconds = Math.Clamp(duration, 4.0, 60.0);
    }

    /// <summary>타임라인에서 고른 블록에 맞춰 오른쪽 목록의 행을 고른다.</summary>
    private static void SelectGridRowByTag(DataGridView grid, object? tag)
    {
        if (tag == null) return;
        foreach (DataGridViewRow gridRow in grid.Rows)
        {
            if (!ReferenceEquals(gridRow.Tag, tag)) continue;
            if (gridRow.Selected) return;
            grid.ClearSelection();
            gridRow.Selected = true;
            // 목록이 길면 고른 행이 화면 밖일 수 있다 -- 보이는 데까지 끌어온다.
            grid.FirstDisplayedScrollingRowIndex = gridRow.Index;
            grid.CurrentCell = gridRow.Cells[0];
            return;
        }
    }


    // ================= CD-DA 자막 =================
    // 트랙을 듣고 한국어를 쳐 넣으면 그대로 저장된다.
    //
    // 위  세그먼트 407 개 (클립 · 트랙 · 길이 · 구분 · 일본어 원문)
    // 아래 그 세그먼트의 **시간 조각**.  한 줄에 안 들어가면 나눠 넣는다
    //     part · 시작(초) · 지속(초) · 한국어 자막
    //
    // 왜 음성 탭과 따로인가
    //   CD-DA 이벤트는 **트랙 시작**에만 잡힌다 (실측: 전부 0.00 초 지점).
    //   트랙 10 안에만 대사가 80 개고, 트랙 17 의 오프닝 내레이션은 36.46 초부터
    //   시작한다.  이벤트 하나로는 못 가르므로 자막 단위가 전사 세그먼트다.
    //
    // 원본  build/cutscene_subs/cdda_segments.tsv          읽기 전용 (트랙·LBA·구간·일본어)
    // 편집  snatcher_tool/translation/cdda_subtitles.tsv   clip + part 를 열쇠로 한국어를 쓴다
    // 소리  snatcher_tool/logs/cdda_clips/<clip>

    private void LoadCddaTables()
    {
        var segPath = Path.GetFullPath(Path.Combine(root, "..", "build", "cutscene_subs", "cdda_segments.tsv"));
        var header = new[] { "clip", "track", "lba_from", "lba_to", "start_sec", "end_sec", "seconds", "kind", "jp_whisper" };
        cddaSegments = TsvDocument.Load(segPath, header);
        cddaSegments.EnsureColumn("vram_observed");

        var subPath = Path.Combine(translationDir, "cdda_subtitles.tsv");
        EnsureTsv(subPath, "track	part	start_sec	duration_sec	ko_text	jp_text	pos	status	note	kind	clip");
        cddaSubs = TsvDocument.Load(subPath);
        // jp_text -- 조각별 일본어 원문.  전사는 구간 단위라 통짜로만 있어서,
        // 한국어를 조각으로 나눠 놓아도 어느 일본어가 어느 조각인지 안 보였다.
        // review -- 검토 표시 (2026-09-01).  대사·UI 탭과 같은 규약: "O" 만 출하한다
        foreach (var column in new[] { "track", "part", "start_sec", "duration_sec", "ko_text", "jp_text", "pos", "status", "note", "kind", "clip", "review" })
            cddaSubs.EnsureColumn(column);

        // ★★ 목록의 단위는 clip 이 아니라 **트랙**이다 (2026-08-31).
        //
        //   "1개 트랙은 1개 음성이랑 동일한거임 거기 안에 자막들이 종속되는 형식.
        //    지금 마스터는 왼쪽에 자막들이 다 나와있어서 이게 한개 음성인지
        //    싱크를 전체를 기준으로 맞출 수가 없음"   -- 소유자
        //
        // clip 408 개를 그대로 늘어놓으면 어디까지가 한 음성인지 보이지 않고,
        // 시간도 clip 안에서만 재게 되어 트랙 통짜(logs/cdda/trackNN.wav)를 들으며
        // 싱크를 맞출 수가 없다.  그래서 세그먼트 표를 읽은 뒤 **트랙 단위로 접는다.**
        //
        // 접은 행의 `clip` 칸에는 트랙 번호를 넣는다.  이 탭의 나머지 코드가
        // `Get(seg, "clip")` 로 열쇠를 잡고 있어서, 그렇게 두면 아래가 그대로 돈다.
        cddaClipRows = cddaSegments.Rows.ToList();
        var folded = new List<List<string>>();
        foreach (var group in cddaClipRows
                     .Where(r => cddaSegments.Get(r, "track").Length > 0)
                     .GroupBy(r => cddaSegments.Get(r, "track"))
                     .OrderBy(g => g.Key, StringComparer.Ordinal))
        {
            var clips = group.OrderBy(r => ParseDouble(cddaSegments.Get(r, "start_sec"))).ToList();
            var row = Enumerable.Repeat("", cddaSegments.Headers.Count).ToList();
            cddaSegments.Set(row, "clip", group.Key);          // 열쇠 = 트랙 번호
            cddaSegments.Set(row, "track", group.Key);
            cddaSegments.Set(row, "lba_from", cddaSegments.Get(clips[0], "lba_from"));
            cddaSegments.Set(row, "lba_to", cddaSegments.Get(clips[^1], "lba_to"));
            cddaSegments.Set(row, "start_sec", "0.00");
            var end = clips.Max(r => ParseDouble(cddaSegments.Get(r, "end_sec")));
            cddaSegments.Set(row, "end_sec", end.ToString("0.00"));
            cddaSegments.Set(row, "seconds", end.ToString("0.00"));
            cddaSegments.Set(row, "kind", clips
                .Select(r => cddaSegments.Get(r, "kind")).Where(k => k.Length > 0)
                .GroupBy(k => k).OrderByDescending(g => g.Count())
                .Select(g => g.Key).FirstOrDefault() ?? "");
            cddaSegments.Set(row, "jp_whisper", string.Join(" ", clips
                .Select(r => cddaSegments.Get(r, "jp_whisper").Trim())
                .Where(t => t.Length > 0)));
            // 트랙 하나라도 관측됐으면 관측으로 친다
            cddaSegments.Set(row, "vram_observed", clips
                .Any(r => cddaSegments.Get(r, "vram_observed").Length > 0) ? "O" : "");
            folded.Add(row);
        }
        cddaSegments.Rows.Clear();
        cddaSegments.Rows.AddRange(folded);
        // 접은 표는 화면용이다.  파일로 돌아가면 안 된다.
        cddaSegments.Dirty = false;
    }

    /// <summary>세그먼트 표의 원래 clip 행들.  트랙으로 접기 전 모습.</summary>
    private List<List<string>> cddaClipRows = new();

    private List<List<string>> CddaPartsOf(string track) =>
        cddaSubs.Rows.Where(r => cddaSubs.Get(r, "track") == track)
                     .OrderBy(r => ParseDouble(cddaSubs.Get(r, "start_sec"))).ToList();

    private List<string>? SelectedCddaSegment()
    {
        var grid = cddaGrid.SelectedRows.Count > 0 ? cddaGrid.SelectedRows[0] : cddaGrid.CurrentRow;
        return grid?.Tag as List<string>;
    }

    private string SelectedCddaClip()
    {
        var seg = SelectedCddaSegment();
        return seg == null ? "" : cddaSegments.Get(seg, "clip");
    }

    private void BuildCddaTab(TabPage page)
    {
        var toolbar = new FlowLayoutPanel { Dock = DockStyle.Top, Height = 45, Padding = new Padding(7), WrapContents = false };
        toolbar.Controls.AddRange(new Control[] {
            Button("▶ 듣기", (_, _) => PlaySelectedCddaClip()),
            Button("■ 정지", (_, _) => StopVoiceClip()),
            Button("대사", (_, _) => SetSelectedCddaKind("대사")),
            Button("효과음", (_, _) => SetSelectedCddaKind("효과음")),
            Button("기타", (_, _) => SetSelectedCddaKind("기타")),
            Button("위", (_, _) => SetSelectedCddaPos("위")),
            Button("중간", (_, _) => SetSelectedCddaPos("중간")),
            Button("아래", (_, _) => SetSelectedCddaPos("아래")),
            Button("위치 기본", (_, _) => SetSelectedCddaPos("")),
            Button("+ 자막 조각", (_, _) => AddCddaPart()),
            Button("자막 나눔", (_, _) => SplitCddaPart()),
            Button("조각 삭제", (_, _) => DeleteCddaPart()),
            Button("일본어 나누기", (_, _) => SplitCddaJapanese()),
            Button("시간 균등 배분", (_, _) => SpreadCddaParts()),
            // 검토 표시 -- 음성 탭과 같다 (2026-09-01)
            Button("검토 O", (_, _) => SetCddaPartReview("O")),
            Button("검토 해제", (_, _) => SetCddaPartReview("")),
            Button("저장 Ctrl+S", (_, _) => SaveAll()),
            Button("클립 폴더 열기", (_, _) => OpenPath(Path.Combine(root, "logs", "cdda_clips"))),
            cddaSpeechOnly, cddaSummary
        });
        cddaSpeechOnly.CheckedChanged += (_, _) => RefreshCddaGrid();
        cddaSearchDebounce.Tick += (_, _) => { cddaSearchDebounce.Stop(); RefreshCddaGrid(); };
        cddaSearchBox.TextChanged += (_, _) => { cddaSearchDebounce.Stop(); cddaSearchDebounce.Start(); };
        cddaSearchBox.KeyDown += (_, e) =>
        {
            if (e.KeyCode != Keys.Escape) return;
            cddaSearchBox.Clear();
            e.SuppressKeyPress = true;
        };

        foreach (var (name, title, width, readOnly) in new[] {
            ("clip", "클립", 90, true), ("track", "트랙", 45, true), ("seconds", "길이", 55, true),
            ("kind", "구분", 62, false),
            ("parts", "조각", 45, true),
            // VRAM 수집 현황.  tools/mark_vram_observed.py 가 cdda_segments.tsv 에
            // 찍는다.  "이 클립 자리 찾기 했나" 를 탭에서 바로 보려는 것이다.
            ("vram_observed", "관측", 45, true),
            ("jp_whisper", "일본어 원문", 420, true) })
        {
            var i = cddaGrid.Columns.Add(name, title);
            cddaGrid.Columns[i].Width = width;
            cddaGrid.Columns[i].ReadOnly = readOnly;
        }
        cddaGrid.CellDoubleClick += (_, _) => PlaySelectedCddaClip();
        cddaGrid.CellValueChanged += (_, e) => UpdateCddaRow(e.RowIndex, e.ColumnIndex);
        // CD-DA 표는 행 선택 방식이라 기본 Ctrl+C가 클립·트랙·길이·원문을
        // 헤더까지 한꺼번에 복사한다.  번역할 문장을 집어 가는 동작에서는
        // 현재 칸의 내용만 필요하므로 이 탭에서만 셀 단위 복사로 바꾼다.
        cddaGrid.ClipboardCopyMode = DataGridViewClipboardCopyMode.Disable;
        cddaGrid.KeyDown += (_, e) => CopyCurrentCddaCell(cddaGrid, e);
        // 자동 분류가 대사의 40% 를 음악으로 보냈다.  묶어서 한 번에 고칠 수 있어야 한다
        cddaGrid.MultiSelect = true;
        cddaGrid.SelectionChanged += (_, _) => { RefreshCddaParts(); ShowCddaJapanese(); };
        cddaGrid.Dock = DockStyle.Fill;

        foreach (var (name, title, width, readOnly) in new[] {
            ("part", "조각", 45, true), ("start_sec", "시작(초)", 75, false),
            ("duration_sec", "지속(초)", 75, false),
            ("ko_text", "한국어 자막", 330, false),
            ("px", "폭", 50, true),
            ("pos", "위치", 60, false),
            // ★ 2026-09-06.  `pos` 는 764 줄 중 741 줄이 **빈칸**이다.  빈칸은
            //   "자리 없음" 이 아니라 **기본값(CD-DA = 아래)** 으로 나간다
            //   (build_subtitle_pack.py: POSITIONS / DEFAULT_POS).  그래서 표만
            //   봐서는 자막이 상단·중앙·하단 중 어디로 뜨는지 알 수가 없었다.
            //   이 열이 빈칸을 풀어 **실제로 나가는 자리**를 보여준다.
            ("pos_eff", "실제", 55, true),
            ("jp_text", "일본어 원문", 300, false),
            ("review", "검토", 50, true),
            ("status", "상태", 70, false), ("note", "메모", 130, false) })
        {
            var i = cddaPartGrid.Columns.Add(name, title);
            cddaPartGrid.Columns[i].Width = width;
            cddaPartGrid.Columns[i].ReadOnly = readOnly;
        }
        cddaPartGrid.CellValueChanged += (_, e) => UpdateCddaPart(e.RowIndex, e.ColumnIndex);
        cddaPartGrid.SelectionChanged += (_, _) => SelectCddaPartRow();
        cddaPartGrid.ClipboardCopyMode = DataGridViewClipboardCopyMode.Disable;
        cddaPartGrid.KeyDown += (_, e) => CopyCurrentCddaCell(cddaPartGrid, e);
        cddaPartGrid.EditingControlShowing += (_, e) =>
        {
            if (e.Control is not TextBoxBase editor) return;
            // DataGridView는 열이 달라도 같은 편집 TextBox를 재사용한다. 일본어
            // 원문을 고친 뒤 한국어 열로 오면 IME의 전각 공백·마침표가 들어올
            // 수 있으므로 한국어 자막 열에서만 반각 문자로 되돌린다.
            editor.TextChanged -= NormalizeCddaKoreanEditor;
            if (cddaPartGrid.CurrentCell?.OwningColumn.Name == "ko_text")
                editor.TextChanged += NormalizeCddaKoreanEditor;
        };
        // 검토를 여러 조각에 한 번에 매기려면 다중 선택이 필요하다
        cddaPartGrid.MultiSelect = true;
        cddaPartGrid.Dock = DockStyle.Fill;

        var split = new SplitContainer { Dock = DockStyle.Fill, Orientation = Orientation.Horizontal, SplitterDistance = 300, SplitterWidth = 6 };
        var partHeader = new Panel { Dock = DockStyle.Top, Height = 30, BackColor = Theme.Surface };
        partHeader.Controls.Add(cddaPartSummary);
        var partArea = new Panel { Dock = DockStyle.Fill };
        partArea.Controls.Add(cddaPartGrid);
        partArea.Controls.Add(partHeader);
        // 위쪽을 좌우로 나눈다: 왼쪽 세그먼트 목록 · 오른쪽 일본어 원문 큰 창
        var topSplit = new SplitContainer {
            Dock = DockStyle.Fill, Orientation = Orientation.Vertical, SplitterWidth = 6
        };
        var japanesePanel = new Panel { Dock = DockStyle.Fill, Padding = new Padding(6, 0, 0, 0) };
        japanesePanel.Controls.Add(cddaJapanese);
        japanesePanel.Controls.Add(cddaJapaneseHead);
        // 오른쪽 세로줄: 원문 위 · **자막 조각 목록 아래** (2026-09-01 재배치)
        //
        // 예전에는 여기 아래가 한국어 입력칸이었고 조각 목록은 화면 맨 아래
        // 가로줄이었다.  CD-DA 는 트랙이 길어서 타임라인이 좁으면 싱크를 맞출
        // 수가 없다 -- 그래서 맨 아래 가로줄 전체를 타임라인에 준다.
        // 한국어는 조각 목록의 `한국어 자막` 칸에서 바로 고친다 (입력칸 삭제).
        var rightColumn = new SplitContainer {
            Dock = DockStyle.Fill, Orientation = Orientation.Horizontal, SplitterWidth = 6
        };
        rightColumn.Panel1MinSize = 0;
        rightColumn.Panel2MinSize = 0;
        rightColumn.Panel1.Controls.Add(japanesePanel);
        rightColumn.Panel2.Controls.Add(partArea);
        rightColumn.HandleCreated += (_, _) => rightColumn.BeginInvoke(new Action(() => {
            var height = rightColumn.ClientSize.Height;
            if (height > rightColumn.SplitterWidth + 2)
                rightColumn.SplitterDistance = Math.Clamp((int)(height * 0.42), 1,
                                                          height - rightColumn.SplitterWidth - 1);
        }));
        var cddaListPanel = new Panel { Dock = DockStyle.Fill };
        cddaListPanel.Controls.Add(cddaGrid);
        cddaListPanel.Controls.Add(cddaSearchBox);
        topSplit.Panel1.Controls.Add(cddaListPanel);
        topSplit.Panel2.Controls.Add(rightColumn);
        topSplit.Panel1MinSize = 0;
        topSplit.Panel2MinSize = 0;
        topSplit.HandleCreated += (_, _) => topSplit.BeginInvoke(new Action(() => {
            var width = topSplit.ClientSize.Width;
            if (width > topSplit.SplitterWidth + 2)
                topSplit.SplitterDistance = Math.Clamp((int)(width * 0.62), 1,
                                                       width - topSplit.SplitterWidth - 1);
        }));
        split.Panel1.Controls.Add(topSplit);
        split.Panel2.Controls.Add(BuildCddaTimelinePanel());
        split.Panel1MinSize = 0;
        split.Panel2MinSize = 0;
        // 타임라인에 아래 32% 를 준다.  트랙이 길어서 좁으면 조각을 못 끈다.
        split.HandleCreated += (_, _) => split.BeginInvoke(new Action(() => {
            var height = split.ClientSize.Height;
            if (height > split.SplitterWidth + 2)
                split.SplitterDistance = Math.Clamp((int)(height * 0.68), 1,
                                                    height - split.SplitterWidth - 1);
        }));

        page.Controls.Add(split);
        page.Controls.Add(toolbar);
        RefreshCddaGrid();
    }

    private void RefreshCddaGrid()
    {
        var previous = SelectedCddaClip();
        loadingStatic = true;
        cddaGrid.Rows.Clear();
        var shown = 0; var translated = 0; var speech = 0; var observed = 0;
        foreach (var seg in cddaSegments.Rows)
        {
            var clip = cddaSegments.Get(seg, "clip");
            var japanese = cddaSegments.Get(seg, "jp_whisper");
            if (LooksLikeSpeech(japanese)) speech++;
            if (cddaSegments.Get(seg, "vram_observed").Length > 0) observed++;
            var parts = CddaPartsOf(clip);
            var done = parts.Count(r => cddaSubs.Get(r, "ko_text").Length > 0);
            if (done > 0) translated++;
            if (cddaSpeechOnly.Checked && !LooksLikeSpeech(japanese)) continue;
            if (!SearchTermsMatch(cddaSearchBox.Text,
                    seg.Concat(parts.SelectMany(part => part)))) continue;

            // 구분은 사용자가 고친 값이 우선한다.  자동 분류가 대사의 40% 를
            // 음악으로 보냈다 (실측: 분류기 222 vs 말이 있는 것 345).
            var kind = parts.Count > 0 ? cddaSubs.Get(parts[0], "kind") : "";
            if (kind.Length == 0) kind = cddaSegments.Get(seg, "kind");

            var index = cddaGrid.Rows.Add();
            var cells = cddaGrid.Rows[index].Cells;
            cells[0].Value = clip;
            cells[1].Value = cddaSegments.Get(seg, "track");
            cells[2].Value = cddaSegments.Get(seg, "seconds");
            cells[3].Value = kind;
            cells[4].Value = parts.Count == 0 ? "" : $"{done}/{parts.Count}";
            cells[5].Value = cddaSegments.Get(seg, "vram_observed");
            cells[6].Value = japanese;
            cddaGrid.Rows[index].Tag = seg;
            if (done > 0 && done == parts.Count)
                cddaGrid.Rows[index].DefaultCellStyle.BackColor = Theme.RowComplete;
            if (clip == previous) cddaGrid.Rows[index].Selected = true;
            shown++;
        }
        loadingStatic = false;
        cddaSummary.Text = $"트랙 {cddaSegments.Rows.Count}개 · 말 있는 것 {speech} · 번역 시작됨 {translated} · 관측 {observed} · 보이는 것 {shown}";
        RefreshCddaParts();
        ShowCddaJapanese();
    }

    /// <summary>
    /// 빈칸을 풀어 **실제로 나가는 자막 자리**를 돌려준다.
    ///
    /// 값과 기본값은 <c>tools/build_subtitle_pack.py</c> 와 같아야 한다:
    /// <code>
    /// POSITIONS   = {"위": 32, "중간": 122, "아래": 192}
    /// DEFAULT_POS = {"adpcm": "중간", "cdda": "아래"}
    /// </code>
    /// 표에 없는 값(오타 포함)도 빌더는 조용히 기본값으로 넘긴다.  여기서도
    /// 같게 처리하되 <c>?</c> 를 붙여 **오타라는 것이 보이게** 한다.
    /// </summary>
    private static string EffectivePos(string raw, bool cdda)
    {
        var key = (raw ?? string.Empty).Trim();
        var fallback = cdda ? "아래" : "중간";
        if (key.Length == 0) return fallback + " (기본)";
        if (key == "위" || key == "중간" || key == "아래") return key;
        return fallback + " (기본) ?";     // 빌더가 모르는 값 -- 오타로 의심된다
    }

    private void RefreshCddaParts()
    {
        if (loadingStatic) return;
        var clip = SelectedCddaClip();
        loadingStatic = true;
        cddaPartGrid.Rows.Clear();
        foreach (var row in CddaPartsOf(clip))
        {
            var index = cddaPartGrid.Rows.Add();
            var cells = cddaPartGrid.Rows[index].Cells;
            // 자리 번호 대신 열 이름으로 넣는다 -- 열이 하나 늘 때마다 아래가
            // 통째로 어긋나던 것을 막는다 (jp_text 를 끼우며 실제로 겪었다)
            var korean = cddaSubs.Get(row, "ko_text");
            var cellCount = korean.Trim().Length;
            var width = SubtitleWidthPx(korean);
            cells["part"].Value = cddaSubs.Get(row, "part");
            cells["start_sec"].Value = cddaSubs.Get(row, "start_sec");
            cells["duration_sec"].Value = cddaSubs.Get(row, "duration_sec");
            cells["ko_text"].Value = korean;
            cells["px"].Value = korean.Length == 0 ? "" : width.ToString();
            cells["pos"].Value = cddaSubs.Get(row, "pos");
            cells["pos_eff"].Value = EffectivePos(cddaSubs.Get(row, "pos"), cdda: true);
            cells["jp_text"].Value = cddaSubs.Get(row, "jp_text");
            cells["review"].Value = cddaSubs.Get(row, "review");
            cells["status"].Value = cddaSubs.Get(row, "status");
            cells["note"].Value = cddaSubs.Get(row, "note");
            cddaPartGrid.Rows[index].Tag = row;
            cddaPartGrid.Rows[index].DefaultCellStyle.BackColor =
                cellCount > SubtitleLimitCells || width > SubtitleLimitPx ? Theme.RowOverLimit
                : korean.Length > 0 ? Theme.RowComplete : Theme.RowDefault;
        }
        loadingStatic = false;
        RefreshCddaTimeline();
        SelectCddaPartRow();
        var seg = SelectedCddaSegment();
        var length = seg == null ? 0 : ParseDouble(cddaSegments.Get(seg, "seconds"));
        cddaPartSummary.Text = clip.Length == 0
            ? "위에서 트랙을 고르세요"
            : $"{clip} · 길이 {length:0.00}초 · 조각 {cddaPartGrid.Rows.Count}개   —   공백 포함 {SubtitleLimitCells}칸 / {SubtitleLimitPx}px · 넘치면 빨간색";
    }

    /// <summary>맨 아래 가로줄 -- 싱크 맞추는 타임라인 (2026-09-01 재배치).</summary>
    ///
    /// 예전에는 오른쪽 아래 구석에 82 px 높이로 끼어 있었다.  CD-DA 는 트랙이
    /// 길어서 그 폭으로는 조각을 끌어 맞출 수가 없다 -- 화면 아래 전체를 준다.
    ///
    /// 한국어 입력칸(`cddaKoBox`)은 화면에서 뺐다.  조각 목록의 `한국어 자막`
    /// 칸에서 바로 고친다.  ★ 필드는 남겨 둔다 -- `ApplyCddaCurrent` ·
    /// `MoveCddaPart` · `SelectCddaPartRow` 가 아직 그것을 통해 값을 옮기므로,
    /// 지우면 그 경로가 전부 깨진다.  대신 `UpdateCddaPart` 가 그리드 편집을
    /// 그때그때 이 칸에 되비춰 "적용" 이 낡은 값으로 덮어쓰지 않게 한다.
    private Control BuildCddaTimelinePanel()
    {
        var actions = new FlowLayoutPanel { Dock = DockStyle.Bottom, Height = 42, Padding = new Padding(0, 4, 0, 0) };
        actions.Controls.AddRange(new Control[] {
            // CD-DA 는 트랙 통짜라 3 분이 넘는다.  되감을 손잡이가 없으면
            // 한 번 틀 때마다 처음부터 다시 들어야 한다.
            Button("▶ / ⏸  (F5)", (_, _) => TogglePlayback()),
            Button("■ 정지", (_, _) => StopVoiceClip()),
            Button("적용", (_, _) => ApplyCddaCurrent()),
            Button("◀ 이전 조각", (_, _) => MoveCddaPart(-1)),
            Button("적용 후 다음 조각 ▶", (_, _) => MoveCddaPart(1)),
            cddaFocusMode,
            cddaFollowPlayback,
            Button("더 확대", (_, _) => ChangeCddaFocusWindow(0.5)),
            Button("더 넓게", (_, _) => ChangeCddaFocusWindow(2.0)),
            Button("F6 시작 찍기", (_, _) => SetCddaBoundaryFromPlayhead(setStart: true)),
            Button("F7 끝 찍기", (_, _) => SetCddaBoundaryFromPlayhead(setStart: false))
        });
        cddaFocusMode.CheckedChanged += (_, _) => ToggleCddaFocusMode();

        var focusRows = new TableLayoutPanel {
            Dock = DockStyle.Fill, ColumnCount = 1, RowCount = 3, Margin = Padding.Empty, Padding = Padding.Empty
        };
        focusRows.RowStyles.Add(new RowStyle(SizeType.Percent, 27));
        focusRows.RowStyles.Add(new RowStyle(SizeType.Percent, 46));
        focusRows.RowStyles.Add(new RowStyle(SizeType.Percent, 27));
        focusRows.Controls.Add(cddaFocusPrevious, 0, 0);
        focusRows.Controls.Add(cddaFocusCurrent, 0, 1);
        focusRows.Controls.Add(cddaFocusNext, 0, 2);
        cddaFocusPanel.Controls.Add(focusRows);
        // 타임라인은 이 칸을 꽉 채운다 (예전 Bottom·82px 고정에서 바뀌었다)
        cddaTimeline.Dock = DockStyle.Fill;
        var panel = new Panel { Dock = DockStyle.Fill, Padding = new Padding(8, 2, 8, 4) };
        panel.Controls.Add(cddaTimeline);
        panel.Controls.Add(actions);
        panel.Controls.Add(cddaFocusPanel);
        panel.Controls.Add(cddaIdentityLabel);
        cddaKoBox.TextChanged += (_, _) => ShowWidth(cddaWidthLabel, cddaKoBox.Text);
        ShowWidth(cddaWidthLabel, "");
        return panel;
    }

    private void ToggleCddaFocusMode()
    {
        cddaFocusPanel.Visible = cddaFocusMode.Checked;
        // 방금 켰으면 창을 한 번은 맞춰 줘야 한다 (그 전에는 전체 보기였다).
        if (cddaFocusMode.Checked) UpdateCddaFocusView(recenter: true);
        else cddaTimeline.ClearView();
    }

    private void ChangeCddaFocusWindow(double factor)
    {
        cddaFocusWindowSeconds = Math.Clamp(cddaFocusWindowSeconds * factor, 4.0, 60.0);
        if (!cddaFocusMode.Checked) cddaFocusMode.Checked = true;
        else UpdateCddaFocusView(recenter: true);   // 배율을 바꾼 것은 사람이다
    }

    private static string CddaFocusLine(TsvDocument doc, List<string>? row, string mark)
    {
        if (row == null) return "";
        var start = ParseDouble(doc.Get(row, "start_sec"));
        var end = start + ParseDouble(doc.Get(row, "duration_sec"));
        var text = doc.Get(row, "ko_text").Trim();
        if (text.Length == 0) text = doc.Get(row, "jp_text").Trim();
        return $"{mark} {doc.Get(row, "part")}  {start:0.000}–{end:0.000}초   {text}";
    }

    /// <summary>현재 줄 주변만 크게 보이고, 위아래에는 직전·다음 줄을 보여준다.</summary>
    /// <remarks>
    /// ★ 2026-09-07: 글(이전/▶/다음)은 언제나 새로 쓰지만, **창을 다시 맞추는
    ///   것은 아낀다.**  전에는 부를 때마다 `SetView` 를 해서, 편집 한 번마다
    ///   (`RefreshCddaTimeline` → 여기) 창이 고른 조각 한가운데로 되돌아갔다.
    ///   손으로 밀어 둔 자리도, 확대해 둔 배율 안의 위치도 매번 잃는다.
    ///
    ///   이제 창은 셋 중 하나일 때만 움직인다.
    ///
    ///       recenter        부르는 쪽이 "지금 맞춰라" 라고 시켰다
    ///       고른 조각이 바뀜  목록에서 다른 조각으로 갔다
    ///       (그 외)          안 움직인다
    ///
    ///   타임라인의 블록을 눌러서 고른 경우는 예외다 -- 이미 눈앞에 있으므로
    ///   옮길 이유가 없고, 옮기면 드래그가 시작되기 전에 좌표계가 바뀐다.
    /// </remarks>
    private void UpdateCddaFocusView(bool recenter = false)
    {
        if (!cddaFocusMode.Checked) return;
        var parts = CddaPartsOf(SelectedCddaClip());
        var index = currentCddaPartRow == null ? -1 : parts.FindIndex(r => ReferenceEquals(r, currentCddaPartRow));
        if (index < 0)
        {
            cddaFocusPrevious.Text = "";
            cddaFocusCurrent.Text = "자막 조각을 고르면 이 주변만 확대됩니다";
            cddaFocusNext.Text = "";
            cddaFocusAnchorRow = null;
            cddaTimeline.ClearView();
            return;
        }

        var current = parts[index];
        cddaFocusPrevious.Text = CddaFocusLine(cddaSubs, index > 0 ? parts[index - 1] : null, "이전");
        cddaFocusCurrent.Text = CddaFocusLine(cddaSubs, current, "▶");
        cddaFocusNext.Text = CddaFocusLine(cddaSubs, index + 1 < parts.Count ? parts[index + 1] : null, "다음");

        var moved = !ReferenceEquals(cddaFocusAnchorRow, current);
        cddaFocusAnchorRow = current;
        if (!recenter && (!moved || selectingCddaFromTimeline)) return;

        var start = ParseDouble(cddaSubs.Get(current, "start_sec"));
        var duration = Math.Max(0.05, ParseDouble(cddaSubs.Get(current, "duration_sec")));
        var window = Math.Max(cddaFocusWindowSeconds, duration + 2.0);
        cddaTimeline.SetView(start + duration / 2.0 - window / 2.0, window);
    }

    /// <summary>확대 재생 중 실제로 말하고 있는 자막을 큰 줄과 타임라인 중앙에 붙인다.</summary>
    private void FollowCddaPlayback()
    {
        if (draggingSubtitleBlock || cddaPartGrid.IsCurrentCellInEditMode) return;
        var position = cddaTimeline.PositionSeconds;
        var active = CddaPartsOf(SelectedCddaClip()).FirstOrDefault(row => {
            var start = ParseDouble(cddaSubs.Get(row, "start_sec"));
            return position >= start && position < start + ParseDouble(cddaSubs.Get(row, "duration_sec"));
        });
        if (active == null || ReferenceEquals(active, currentCddaPartRow)) return;
        SelectGridRowByTag(cddaPartGrid, active);
    }

    /// <summary>귀로 잡은 현재 재생 위치를 선택 자막의 시작/끝 경계로 기록한다.</summary>
    private void SetCddaBoundaryFromPlayhead(bool setStart)
    {
        if (currentCddaPartRow == null || !ReferenceEquals(activeSubtitleTimeline, cddaTimeline))
        {
            cddaSummary.Text = "CD-DA를 재생하고 자막 조각을 고른 뒤 찍으세요";
            return;
        }
        var start = ParseDouble(cddaSubs.Get(currentCddaPartRow, "start_sec"));
        var duration = Math.Max(0.05, ParseDouble(cddaSubs.Get(currentCddaPartRow, "duration_sec")));
        var end = start + duration;
        var at = Math.Clamp(cddaTimeline.PositionSeconds, 0, SelectedCddaDuration());
        if (setStart)
        {
            if (at >= end - 0.05) { cddaSummary.Text = "시작은 현재 끝보다 앞에서 찍어야 합니다"; return; }
            start = at;
            duration = end - start;
        }
        else
        {
            if (at <= start + 0.05) { cddaSummary.Text = "끝은 현재 시작보다 뒤에서 찍어야 합니다"; return; }
            duration = at - start;
        }
        WriteSpanTimes(cddaSubs, cddaPartGrid, currentCddaPartRow, start, duration);
        RefreshCddaTimeline();
        UpdateCddaFocusView();
        UpdateTitle();
        cddaSummary.Text = $"{(setStart ? "시작" : "끝")} {at:0.000}초로 기록";
    }

    /// <summary>고른 자막 조각들에 검토 표시를 매긴다 (음성·CD-DA 공통 규약: "O" 만 출하).</summary>
    private static int SetReviewOnGrid(DataGridView grid, TsvDocument doc, string value)
    {
        var targets = grid.SelectedRows.Cast<DataGridViewRow>()
            .Where(row => row.Tag is List<string>).ToList();
        if (targets.Count == 0 && grid.CurrentRow?.Tag is List<string>)
            targets.Add(grid.CurrentRow);

        var changed = 0;
        foreach (var gridRow in targets)
        {
            if (gridRow.Tag is not List<string> row) continue;
            if (doc.Get(row, "review") == value) continue;
            doc.Set(row, "review", value);
            if (grid.Columns.Contains("review")) gridRow.Cells["review"].Value = value;
            changed++;
        }
        return changed;
    }

    /// <summary>미리 붙잡아 둔 자료 줄에 검토 표시를 매긴다.</summary>
    /// <remarks>
    /// `SetReviewOnGrid` 와 하는 일은 같지만 **대상을 그리드에서 읽지 않는다.**
    /// 표시를 매기기 전에 그리드가 다시 만들어지는 경로(CD-DA 탭)가 있어서,
    /// 그때는 선택이 이미 무너져 있다.  자료 줄은 그리드를 다시 만들어도 같은
    /// 객체가 Tag 로 다시 붙으므로, 참조로 찾아 화면만 맞춰준다.
    /// </remarks>
    private static int SetReviewOnRows(DataGridView grid, TsvDocument doc,
                                       IReadOnlyList<List<string>> rows, string value)
    {
        var changed = 0;
        foreach (var row in rows)
        {
            if (doc.Get(row, "review") == value) continue;
            doc.Set(row, "review", value);
            changed++;
        }
        if (changed > 0 && grid.Columns.Contains("review"))
        {
            foreach (DataGridViewRow gridRow in grid.Rows)
                if (gridRow.Tag is List<string> data && rows.Contains(data))
                    gridRow.Cells["review"].Value = doc.Get(data, "review");
        }
        return changed;
    }

    private void SetCddaPartReview(string value)
    {
        if (cddaSubs == null) return;
        // ★ 고른 줄을 **먼저** 붙잡는다 (2026-09-01 소유자 보고: "2 행부터는 검토가 안 됨").
        //
        //   아래 ApplyCddaCurrent() 는 끝에서 RefreshCddaParts() 를 부르고, 그것은
        //   그리드를 Rows.Clear() 후 다시 만든다.  그 순간 다중 선택이 현재 줄
        //   하나로 무너지므로, 그 뒤에 SelectedRows 를 읽으면 첫 줄밖에 안 남는다.
        //   자료 줄(List<string>)은 다시 만들어도 같은 객체라 미리 잡아두면 산다.
        var targets = cddaPartGrid.SelectedRows.Cast<DataGridViewRow>()
            .Select(row => row.Tag as List<string>)
            .Where(row => row != null).Cast<List<string>>().ToList();
        if (targets.Count == 0 && cddaPartGrid.CurrentRow?.Tag is List<string> current)
            targets.Add(current);

        // 숨은 입력칸 내용을 먼저 반영한다 (CD-DA 탭 재배치 뒤에도 이 경로가 산다)
        ApplyCddaCurrent();
        if (SetReviewOnRows(cddaPartGrid, cddaSubs, targets, value) == 0) return;
        UpdateTitle();
        RefreshCddaPartSummary();
    }

    private void RefreshCddaPartSummary()
    {
        if (cddaSubs == null) return;
        var total = cddaSubs.Rows.Count;
        var reviewed = cddaSubs.Rows.Count(
            row => cddaSubs.Get(row, "review").Equals("O", StringComparison.OrdinalIgnoreCase));
        var translated = cddaSubs.Rows.Count(row => cddaSubs.Get(row, "ko_text").Length > 0);
        cddaPartSummary.Text = $"조각 {total}개 · 번역 {translated} · 검토 O {reviewed}";
    }

    private void SetVoiceSubtitleReview(string value)
    {
        if (voiceSubtitles == null) return;
        // 입력칸 내용을 먼저 반영한다 -- 안 그러면 편집 중이던 줄이 날아간다
        ApplyVoiceSubtitleCurrent();
        if (SetReviewOnGrid(voiceSubtitleGrid, voiceSubtitles, value) == 0) return;
        UpdateTitle();
        RefreshVoiceSubtitleSummary();
    }

    private void RefreshVoiceSubtitleSummary()
    {
        if (voiceSubtitles == null) return;
        var total = voiceSubtitles.Rows.Count;
        var reviewed = voiceSubtitles.Rows.Count(
            row => voiceSubtitles.Get(row, "review").Equals("O", StringComparison.OrdinalIgnoreCase));
        var translated = voiceSubtitles.Rows.Count(
            row => voiceSubtitles.Get(row, "ko_text").Length > 0);
        voiceSummary.Text = $"자막 {total}개 · 번역 {translated} · 검토 O {reviewed}";
    }

    /// <summary>아래 조각 목록에서 고른 줄을 오른쪽 입력칸으로 가져온다.</summary>
    private void SelectCddaPartRow()
    {
        if (loadingStatic) return;
        var grid = cddaPartGrid.CurrentRow;
        if (grid?.Tag is not List<string> row)
        {
            currentCddaPartRow = null;
            cddaIdentityLabel.Text = "아래에서 자막 조각을 고르세요";
            cddaKoBox.Text = "";
            return;
        }
        currentCddaPartRow = row;
        cddaTimeline.SelectByTag(row);   // 목록에서 고르면 타임라인에도 표시된다
        cddaIdentityLabel.Text = $"{cddaSubs.Get(row, "clip")} · {cddaSubs.Get(row, "part")}번째 조각"
            + $" · 시작 {cddaSubs.Get(row, "start_sec")}초 · 지속 {cddaSubs.Get(row, "duration_sec")}초";
        cddaKoBox.Text = cddaSubs.Get(row, "ko_text");
        ShowCddaJapanese();     // ▶ 가 지금 고른 조각을 따라오게
        UpdateCddaFocusView();
    }

    /// <summary>입력칸의 내용을 지금 고른 조각에 쓴다.</summary>
    private void ApplyCddaCurrent()
    {
        if (currentCddaPartRow == null) { cddaSummary.Text = "먼저 조각을 고르세요"; return; }
        // 여러 줄로 붙여넣어도 한 줄 자막으로 만든다.
        // 역슬래시 이스케이프 대신 문자 코드로 쓴다.
        var breaks = new[] { (char)13, (char)10 };
        var value = string.Join(" ", cddaKoBox.Text
            .Split(breaks, StringSplitOptions.RemoveEmptyEntries)
            .Select(part => part.Trim())).Trim();
        cddaSubs.Set(currentCddaPartRow, "ko_text", value);
        if (value.Length > 0 && cddaSubs.Get(currentCddaPartRow, "status") == "todo")
            cddaSubs.Set(currentCddaPartRow, "status", "draft");
        cddaSubs.Dirty = true;
        Text = "Snatcher 한국어 패치 스튜디오 *";
        RefreshCddaParts();
        UpdateCddaCounts();
    }

    private void MoveCddaPart(int step)
    {
        if (step > 0) ApplyCddaCurrent();
        var index = cddaPartGrid.CurrentRow?.Index ?? -1;
        var next = index + step;
        if (next < 0 || next >= cddaPartGrid.Rows.Count) return;
        cddaPartGrid.CurrentCell = cddaPartGrid.Rows[next].Cells["ko_text"];
        SelectCddaPartRow();
        cddaKoBox.Focus();
    }

    /// <summary>선택된 세그먼트들.  선택이 없으면 커서가 있는 행 하나.</summary>
    private List<List<string>> SelectedCddaSegments()
    {
        var picked = new List<List<string>>();
        foreach (DataGridViewRow gridRow in cddaGrid.SelectedRows)
            if (gridRow.Tag is List<string> seg) picked.Add(seg);
        if (picked.Count == 0 && cddaGrid.CurrentRow?.Tag is List<string> current)
            picked.Add(current);
        return picked;
    }

    /// <summary>선택한 세그먼트 전부의 구분을 바꾼다.</summary>
    /// <remarks>
    /// 자동 분류가 대사 345 개 중 152 개를 음악으로 보냈다 (배경음 위에 얹힌
    /// 내레이션).  한 줄씩 고치면 152 번이므로 묶어서 매긴다.
    /// 구분은 조각 행에 저장한다 -- 원본 전사는 안 건드린다.
    /// </remarks>
    /// <summary>고른 자막 조각들의 세로 자리를 정한다.</summary>
    /// <remarks>
    /// 자리는 빌드 때 레코드에 박힌다 (6280 에 곱셈기가 없어 런타임은 계산을 안 한다).
    /// 빈칸이면 팩 빌더의 기본값을 쓴다 -- ADPCM 중간 · CD-DA 아래.
    /// 그래서 [위치 기본] 은 값을 지우는 단추다.
    /// </remarks>
    private void SetSelectedCddaPos(string pos)
    {
        var rows = cddaPartGrid.SelectedRows.Cast<DataGridViewRow>()
            .Select(r => r.Tag).OfType<List<string>>().ToList();
        if (rows.Count == 0 && cddaPartGrid.CurrentRow?.Tag is List<string> one) rows.Add(one);
        if (rows.Count == 0) { cddaSummary.Text = "아래에서 자막 조각을 고르세요"; return; }
        foreach (var row in rows) cddaSubs.Set(row, "pos", pos);
        cddaSubs.Dirty = true;
        Text = "Snatcher 한국어 패치 스튜디오 *";
        RefreshCddaParts();
        cddaSummary.Text = $"조각 {rows.Count}개를 '{(pos.Length == 0 ? "기본" : pos)}' 자리로";
    }

    private void SetSelectedCddaKind(string kind)
    {
        var targets = SelectedCddaSegments();
        if (targets.Count == 0) { cddaSummary.Text = "먼저 세그먼트를 고르세요"; return; }
        foreach (var seg in targets)
        {
            var clip = cddaSegments.Get(seg, "clip");
            foreach (var row in CddaPartsOf(clip)) cddaSubs.Set(row, "kind", kind);
        }
        cddaSubs.Dirty = true;
        Text = "Snatcher 한국어 패치 스튜디오 *";
        RefreshCddaGrid();
        cddaSummary.Text = $"{targets.Count}개를 '{kind}' 로";
    }

    /// <summary>구간의 일본어 원문을 조각들에 시간 비례로 나눈다.</summary>
    /// <remarks>
    /// 전사에는 **낱말 시각이 없다.**  한 구간에 문장이 통째로 들어 있을 뿐이라
    /// 어느 글자가 몇 초에 나오는지 알 수 없다.  다시 전사하지 않기로 한 이상
    /// (품질이 갈리고 시간이 많이 든다) 남은 것은 어림뿐이다.
    ///
    /// 조각의 지속 시간 비율로 글자 수를 자르고, 그 자리에서 가장 가까운 문장
    /// 경계로 당긴다.  말은 대체로 고르게 흐르므로 크게 어긋나지 않고, 어긋나면
    /// 표에서 고치면 된다 -- 그러라고 열에 넣어 두는 것이다.
    /// </remarks>
    /// <summary>목표 자리에서 가장 가까운, 조건을 만족하는 자를 자리. 없으면 -1.</summary>
    private static int FindCut(string text, int target, int window, Func<int, bool> ok)
    {
        for (var away = 0; away <= window; away++)
            foreach (var at in new[] { target - away, target + away })
                if (at > 0 && at < text.Length && ok(at)) return at;
        return -1;
    }

    /// <summary>글자 갈래 — 히라가나 · 가타카나 · 한자 · 그 밖. 낱말 경계를 어림하는 데 쓴다.</summary>
    private static int CharClass(char c) =>
        c >= 0x3040 && c <= 0x309F ? 1
        : c >= 0x30A0 && c <= 0x30FF ? 2
        : (c >= 0x4E00 && c <= 0x9FFF) || (c >= 0x3400 && c <= 0x4DBF) ? 3
        : 0;

    private static List<string> SplitJapanese(string japanese, List<double> durations)
    {
        var text = (japanese ?? "").Trim();
        var result = new List<string>();
        if (durations.Count == 0) return result;
        if (text.Length == 0)
        {
            for (var i = 0; i < durations.Count; i++) result.Add("");
            return result;
        }
        if (durations.Count == 1) { result.Add(text); return result; }

        var total = durations.Sum();
        if (total <= 0) total = durations.Count;

        const string breaks = "。、！？!?,.　 ";
        var window = Math.Max(2, text.Length / (durations.Count * 2));
        var cuts = new List<int>();
        var running = 0.0;
        for (var i = 0; i < durations.Count - 1; i++)
        {
            running += durations[i] > 0 ? durations[i] : 1;
            var target = (int)Math.Round(text.Length * running / total);

            // 1 순위는 구두점.  위스퍼가 구두점을 안 찍은 구간이 많은데, 그럴 때
            // 2 순위로 **히라가나 -> 한자·가타카나** 자리를 쓴다.  거기가 대개
            // 낱말 머리다.  이것이 없으면 "<원문 5자> / ますから" 처럼 낱말
            // 한가운데가 잘린다.
            //
            // 방향이 중요하다.  반대쪽(한자 -> 히라가나)은 어간과 오쿠리가나
            // 사이라 오히려 더 나쁘게 잘린다 -- "黙 / <원문 6자>" 를 실제로 봤다.
            var best = FindCut(text, target, window, at => breaks.IndexOf(text[at - 1]) >= 0);
            if (best < 0)
                best = FindCut(text, target, window,
                               at => CharClass(text[at - 1]) == 1 && CharClass(text[at]) >= 2);
            cuts.Add(Math.Clamp(best >= 0 ? best : target, 0, text.Length));
        }
        // 경계로 당기다 보면 앞 조각의 끝이 뒤 조각을 넘어설 수 있다
        for (var i = 1; i < cuts.Count; i++) cuts[i] = Math.Max(cuts[i], cuts[i - 1]);

        var start = 0;
        foreach (var cut in cuts)
        {
            result.Add(text.Substring(start, cut - start).Trim());
            start = cut;
        }
        result.Add(text.Substring(start).Trim());
        return result;
    }

    /// <summary>선택한 구간들의 일본어를 조각별로 나눠 넣는다.</summary>
    /// <remarks>이미 손으로 넣은 일본어는 **덮지 않는다.**</remarks>
    private void SplitCddaJapanese()
    {
        var picked = SelectedCddaSegments();
        if (picked.Count == 0) { cddaSummary.Text = "먼저 구간을 고르세요"; return; }

        int filled = 0, kept = 0, skipped = 0;
        foreach (var seg in picked)
        {
            var parts = CddaPartsOf(cddaSegments.Get(seg, "clip"));
            if (parts.Count == 0) { skipped++; continue; }
            var durations = parts.Select(p => ParseDouble(cddaSubs.Get(p, "duration_sec"))).ToList();
            var pieces = SplitJapanese(cddaSegments.Get(seg, "jp_whisper"), durations);
            for (var i = 0; i < parts.Count && i < pieces.Count; i++)
            {
                if (cddaSubs.Get(parts[i], "jp_text").Trim().Length > 0) { kept++; continue; }
                cddaSubs.Set(parts[i], "jp_text", pieces[i]);
                filled++;
            }
        }

        RefreshCddaParts();
        ShowCddaJapanese();
        UpdateTitle();
        var extra = kept > 0 ? $" · 손댄 {kept}조각은 그대로" : "";
        if (skipped > 0) extra += $" · 조각 없는 구간 {skipped}개";
        cddaSummary.Text = $"일본어 {filled}조각 채움{extra}";
    }

    /// <summary>오른쪽 큰 창에 일본어 원문을 보여준다 — 조각으로 나뉘어 있으면 그 단위로.</summary>
    private void ShowCddaJapanese()
    {
        var picked = SelectedCddaSegments();
        if (picked.Count == 0) { cddaJapaneseHead.Text = "일본어 원문"; cddaJapanese.Text = ""; return; }
        if (picked.Count > 1)
        {
            cddaJapaneseHead.Text = $"일본어 원문 — {picked.Count}개 선택됨";
            cddaJapanese.Text = string.Join(Environment.NewLine, picked.Select(seg =>
                $"{cddaSegments.Get(seg, "clip")}  {cddaSegments.Get(seg, "jp_whisper")}"));
            return;
        }

        var only = picked[0];
        var clip = cddaSegments.Get(only, "clip");
        var whole = cddaSegments.Get(only, "jp_whisper");
        var parts = CddaPartsOf(clip);
        var split = parts.Any(p => cddaSubs.Get(p, "jp_text").Trim().Length > 0);

        cddaJapaneseHead.Text = $"일본어 원문 — 트랙 {cddaSegments.Get(only, "track")}"
            + $" · {cddaSegments.Get(only, "seconds")}초 · {clip}"
            + (split ? $" · 조각 {parts.Count}" : " · 통짜 [일본어 나누기]");

        if (!split) { cddaJapanese.Text = whole; return; }

        // 지금 고른 조각에 ▶ 를 붙인다 -- 어느 일본어가 지금 쓰는 줄인지 보이게
        var lines = new List<string>();
        foreach (var part in parts)
        {
            var mark = ReferenceEquals(part, currentCddaPartRow) ? "▶" : "  ";
            var no = cddaSubs.Get(part, "part");
            var at = ParseDouble(cddaSubs.Get(part, "start_sec"));
            var span = ParseDouble(cddaSubs.Get(part, "duration_sec"));
            var japanese = cddaSubs.Get(part, "jp_text");
            lines.Add($"{mark} {no}. [{at:0.0}~{at + span:0.0}초]  {japanese}");
            var korean = cddaSubs.Get(part, "ko_text");
            if (korean.Trim().Length > 0) lines.Add($"      → {korean}");
            lines.Add("");
        }
        lines.Add("― 나누기 전 통짜 ―");
        lines.Add(whole);
        cddaJapanese.Text = string.Join(Environment.NewLine, lines);
    }

    /// <summary>선택한 세그먼트에 자막 조각을 하나 덧붙인다.</summary>
    private void AddCddaPart()
    {
        var seg = SelectedCddaSegment();
        if (seg == null) { cddaSummary.Text = "먼저 위에서 세그먼트를 고르세요"; return; }
        var clip = cddaSegments.Get(seg, "clip");
        var length = ParseDouble(cddaSegments.Get(seg, "seconds"));
        var parts = CddaPartsOf(clip);
        var start = 0.0;
        if (parts.Count > 0)
        {
            var last = parts[^1];
            start = ParseDouble(cddaSubs.Get(last, "start_sec")) + ParseDouble(cddaSubs.Get(last, "duration_sec"));
        }
        var remaining = Math.Max(0.1, length - start);
        var row = Enumerable.Repeat("", cddaSubs.Headers.Count).ToList();
        cddaSubs.Set(row, "track", clip);
        cddaSubs.Set(row, "part", (parts.Count + 1).ToString());
        cddaSubs.Set(row, "start_sec", start.ToString("0.000"));
        cddaSubs.Set(row, "duration_sec", remaining.ToString("0.000"));
        cddaSubs.Set(row, "status", "todo");
        cddaSubs.Rows.Add(row);
        cddaSubs.Dirty = true;
        RefreshCddaParts();
        UpdateCddaCounts();
        if (cddaPartGrid.Rows.Count > 0)
        {
            cddaPartGrid.CurrentCell = cddaPartGrid.Rows[cddaPartGrid.Rows.Count - 1].Cells["ko_text"];
            cddaPartGrid.BeginEdit(true);
        }
    }

    private void DeleteCddaPart()
    {
        if (cddaPartGrid.CurrentRow?.Tag is not List<string> row) { cddaSummary.Text = "지울 조각을 고르세요"; return; }
        cddaSubs.Rows.Remove(row);
        // 번호를 다시 매긴다 -- 중간이 비면 런타임이 순서를 못 잡는다
        var clip = cddaSubs.Get(row, "track");
        var index = 1;
        foreach (var rest in CddaPartsOf(clip)) cddaSubs.Set(rest, "part", (index++).ToString());
        cddaSubs.Dirty = true;
        RefreshCddaParts();
        UpdateCddaCounts();
    }

    /// <summary>선택한 CD-DA 자막의 시간을 반으로 나누고 빈 자막 두 개로 만든다.</summary>
    /// <remarks>
    /// 홀수 ms 길이는 앞 조각이 1 ms 짧게 나눈다. 두 지속시간의 합과
    /// 두 번째 조각의 끝 시간은 원래 자막과 정확히 같다.
    /// </remarks>
    private void SplitCddaPart()
    {
        if (cddaPartGrid.CurrentRow?.Tag is not List<string> row)
        {
            cddaSummary.Text = "나눌 자막 조각을 고르세요";
            return;
        }

        var startMs = (long)Math.Round(ParseDouble(cddaSubs.Get(row, "start_sec")) * 1000.0,
            MidpointRounding.AwayFromZero);
        var totalMs = (long)Math.Round(ParseDouble(cddaSubs.Get(row, "duration_sec")) * 1000.0,
            MidpointRounding.AwayFromZero);
        if (totalMs < 2)
        {
            cddaSummary.Text = "2 ms 보다 짧은 자막은 두 조각으로 나눌 수 없습니다";
            return;
        }

        var firstMs = totalMs / 2;
        var secondMs = totalMs - firstMs;
        var second = new List<string>(row);
        var insertAt = cddaSubs.Rows.IndexOf(row) + 1;

        cddaSubs.Set(row, "duration_sec", (firstMs / 1000.0).ToString("0.000", System.Globalization.CultureInfo.InvariantCulture));
        cddaSubs.Set(second, "start_sec", ((startMs + firstMs) / 1000.0).ToString("0.000", System.Globalization.CultureInfo.InvariantCulture));
        cddaSubs.Set(second, "duration_sec", (secondMs / 1000.0).ToString("0.000", System.Globalization.CultureInfo.InvariantCulture));

        foreach (var part in new[] { row, second })
        {
            cddaSubs.Set(part, "ko_text", "");
            cddaSubs.Set(part, "jp_text", "");
            cddaSubs.Set(part, "review", "");
            cddaSubs.Set(part, "status", "todo");
        }
        cddaSubs.Rows.Insert(insertAt, second);

        var track = cddaSubs.Get(row, "track");
        var partNumber = 1;
        foreach (var part in CddaPartsOf(track))
            cddaSubs.Set(part, "part", (partNumber++).ToString());

        cddaSubs.Dirty = true;
        Text = "Snatcher 한국어 패치 스튜디오 *";
        RefreshCddaParts();
        SelectGridRowByTag(cddaPartGrid, row);
        if (cddaPartGrid.CurrentRow?.Tag is List<string> selected && ReferenceEquals(selected, row))
        {
            cddaPartGrid.CurrentCell = cddaPartGrid.CurrentRow.Cells["ko_text"];
            cddaPartGrid.BeginEdit(true);
        }
        UpdateCddaCounts();
        cddaSummary.Text = $"자막을 {firstMs / 1000.0:0.000}초 + {secondMs / 1000.0:0.000}초로 나눸습니다";
    }

    /// <summary>조각들의 시작·지속을 세그먼트 길이에 맞춰 고르게 나눈다.</summary>
    /// <remarks>조각을 필요한 개수만큼 만든 뒤 이것을 누르면 시간이 저절로 잡힌다.</remarks>
    private void SpreadCddaParts()
    {
        var seg = SelectedCddaSegment();
        if (seg == null) { cddaSummary.Text = "먼저 위에서 세그먼트를 고르세요"; return; }
        var parts = CddaPartsOf(cddaSegments.Get(seg, "clip"));
        if (parts.Count == 0) { cddaSummary.Text = "나눌 조각이 없습니다"; return; }
        var length = ParseDouble(cddaSegments.Get(seg, "seconds"));
        var each = length / parts.Count;
        for (var i = 0; i < parts.Count; i++)
        {
            cddaSubs.Set(parts[i], "part", (i + 1).ToString());
            cddaSubs.Set(parts[i], "start_sec", (each * i).ToString("0.000"));
            cddaSubs.Set(parts[i], "duration_sec", each.ToString("0.000"));
        }
        cddaSubs.Dirty = true;
        RefreshCddaParts();
        cddaSummary.Text = $"{parts.Count}조각으로 균등 배분 (조각당 {each:0.00}초)";
    }

    private void UpdateCddaRow(int rowIndex, int columnIndex)
    {
        if (loadingStatic || rowIndex < 0 || columnIndex < 0) return;
        if (cddaGrid.Columns[columnIndex].Name != "kind") return;
        if (cddaGrid.Rows[rowIndex].Tag is not List<string> seg) return;
        var clip = cddaSegments.Get(seg, "clip");
        var value = cddaGrid.Rows[rowIndex].Cells[columnIndex].Value?.ToString() ?? "";
        var parts = CddaPartsOf(clip);
        if (parts.Count == 0) { AddCddaPart(); parts = CddaPartsOf(clip); }
        foreach (var row in parts) cddaSubs.Set(row, "kind", value);
        cddaSubs.Dirty = true;
        Text = "Snatcher 한국어 패치 스튜디오 *";
    }

    private void UpdateCddaPart(int rowIndex, int columnIndex)
    {
        // 타임라인에서 끄는 중이면 값은 이미 WriteSpanTimes 가 넣었다.
        if (draggingSubtitleBlock) return;
        if (loadingStatic || rowIndex < 0 || columnIndex < 0) return;
        if (cddaPartGrid.Rows[rowIndex].Tag is not List<string> row) return;
        var name = cddaPartGrid.Columns[columnIndex].Name;
        if (name == "part") return;
        var value = cddaPartGrid.Rows[rowIndex].Cells[columnIndex].Value?.ToString() ?? "";
        if (name == "ko_text")
        {
            value = NormalizeCddaKoreanText(value);
            if ((cddaPartGrid.Rows[rowIndex].Cells[columnIndex].Value?.ToString() ?? "") != value)
                cddaPartGrid.Rows[rowIndex].Cells[columnIndex].Value = value;
        }
        cddaSubs.Set(row, name, value);
        // `실제` 는 파생 열이라 원본이 바뀌면 같이 갱신한다.  안 하면 편집 뒤
        // 다시 고를 때까지 낡은 값이 남아 오해를 만든다.
        if (name == "pos")
            cddaPartGrid.Rows[rowIndex].Cells["pos_eff"].Value = EffectivePos(value, cdda: true);
        if (name == "ko_text")
        {
            // ★ 입력칸이 화면에서 빠졌으므로(2026-09-01) 그리드 편집을 그 칸에
            //   되비춰 둔다.  안 그러면 "적용"·"다음 조각" 이 낡은 값으로
            //   방금 고친 것을 덮어쓴다.
            if (ReferenceEquals(row, currentCddaPartRow) && cddaKoBox.Text != value)
                cddaKoBox.Text = value;
            if (value.Length > 0 && cddaSubs.Get(row, "status") == "todo") cddaSubs.Set(row, "status", "draft");
            cddaPartGrid.Rows[rowIndex].Cells["status"].Value = cddaSubs.Get(row, "status");
            var width = SubtitleWidthPx(value);
            var cellCount = value.Trim().Length;
            cddaPartGrid.Rows[rowIndex].Cells["px"].Value = value.Length == 0 ? "" : width.ToString();
            // 한 줄이 그림 폭을 넘으면 빨갛게.  넘으면 조각을 더 나눠야 한다.
            cddaPartGrid.Rows[rowIndex].DefaultCellStyle.BackColor =
                cellCount > SubtitleLimitCells || width > SubtitleLimitPx ? Theme.RowOverLimit
                : value.Length > 0 ? Theme.RowComplete : Theme.RowDefault;
        }
        cddaSubs.Dirty = true;
        Text = "Snatcher 한국어 패치 스튜디오 *";
        RefreshCddaTimeline();
        UpdateCddaCounts();
    }

    private static void NormalizeCddaKoreanEditor(object? sender, EventArgs e)
    {
        if (sender is not TextBoxBase editor) return;
        var normalized = NormalizeCddaKoreanText(editor.Text);
        if (normalized == editor.Text) return;

        // 바뀌는 문자는 모두 한 글자 대 한 글자이므로 선택 위치를 그대로
        // 복원하면 입력 도중 커서가 문장 끝으로 튀지 않는다.
        var selectionStart = editor.SelectionStart;
        var selectionLength = editor.SelectionLength;
        editor.Text = normalized;
        editor.SelectionStart = Math.Min(selectionStart, editor.TextLength);
        editor.SelectionLength = Math.Min(selectionLength, editor.TextLength - editor.SelectionStart);
    }

    private static string NormalizeCddaKoreanText(string text)
    {
        var chars = (text ?? string.Empty).ToCharArray();
        for (var index = 0; index < chars.Length; index++)
        {
            if (chars[index] == '\u3000') chars[index] = ' ';
            else if (chars[index] == '\u3001') chars[index] = ',';
            else if (chars[index] == '\u3002') chars[index] = '.';
            else if (chars[index] is >= '\uFF01' and <= '\uFF5E')
                chars[index] = (char)(chars[index] - 0xFEE0);
        }
        return NormalizeEllipsis(new string(chars));
    }

    private static void NormalizeSubtitleEllipsisEditor(object? sender, EventArgs e)
    {
        if (sender is not TextBoxBase editor) return;
        var normalized = NormalizeEllipsis(editor.Text);
        if (normalized == editor.Text) return;

        // 세 점이 한 글자로 줄어드는 만큼 선택 위치도 같은 규칙으로 환산한다.
        var start = NormalizeEllipsis(editor.Text[..editor.SelectionStart]).Length;
        var end = NormalizeEllipsis(editor.Text[..(editor.SelectionStart + editor.SelectionLength)]).Length;
        editor.Text = normalized;
        editor.SelectionStart = Math.Min(start, editor.TextLength);
        editor.SelectionLength = Math.Min(Math.Max(0, end - start), editor.TextLength - editor.SelectionStart);
    }

    private static void CopyCurrentCddaCell(DataGridView grid, KeyEventArgs e)
    {
        if (!e.Control || e.Alt || e.KeyCode != Keys.C) return;

        // 셀을 편집 중이면 TextBox의 일반 복사(선택한 부분만)를 살린다.
        if (grid.IsCurrentCellInEditMode && grid.EditingControl is TextBoxBase) return;

        var value = grid.CurrentCell?.Value?.ToString() ?? string.Empty;
        if (value.Length > 0) Clipboard.SetText(value);
        e.SuppressKeyPress = true;
        e.Handled = true;
    }

    /// <summary>위 그리드의 "조각" 칸과 요약만 다시 그린다 (전체 갱신은 무겁다).</summary>
    private void UpdateCddaCounts()
    {
        var clip = SelectedCddaClip();
        if (clip.Length == 0) return;
        var parts = CddaPartsOf(clip);
        var done = parts.Count(r => cddaSubs.Get(r, "ko_text").Length > 0);
        foreach (DataGridViewRow gridRow in cddaGrid.Rows)
        {
            if (gridRow.Tag is not List<string> seg || cddaSegments.Get(seg, "clip") != clip) continue;
            gridRow.Cells["parts"].Value = parts.Count == 0 ? "" : $"{done}/{parts.Count}";
            gridRow.DefaultCellStyle.BackColor =
                (done > 0 && done == parts.Count) ? Theme.RowComplete : Theme.RowDefault;
            break;
        }
        var translated = cddaSubs.Rows.Select(r => cddaSubs.Get(r, "clip"))
            .Where(c => c.Length > 0).Distinct()
            .Count(c => CddaPartsOf(c).Any(r => cddaSubs.Get(r, "ko_text").Length > 0));
        cddaSummary.Text = $"세그먼트 {cddaSegments.Rows.Count}개 · 번역 시작됨 {translated}";
    }

    /// <summary>자막 한 줄의 실제 픽셀 폭.</summary>
    /// <remarks>
    /// Galmuri9 는 **비례폭**이다 -- 한글 10 px, 영문·숫자는 6~8 px.
    /// 그래서 글자 수로는 못 잰다.  글꼴을 구울 때 뽑아둔 글자별 폭을 쓴다
    /// (build/cutscene_subs/subfont_Galmuri9.tsv).  화면에 그리는 것과 같은 값이다.
    /// </remarks>
    private int SubtitleWidthPx(string text)
    {
        if (subtitleAdvance == null)
        {
            subtitleAdvance = new Dictionary<char, int>();
            var path = Path.GetFullPath(Path.Combine(root, "..", "build", "cutscene_subs", "subfont_Galmuri9.tsv"));
            if (File.Exists(path))
            {
                var font = TsvDocument.Load(path);
                foreach (var row in font.Rows)
                {
                    var ch = font.Get(row, "char");
                    if (ch.Length == 1 && int.TryParse(font.Get(row, "advance"), out var advance))
                        subtitleAdvance[ch[0]] = advance;
                }
            }
        }
        var width = 0;
        foreach (var ch in text) width += subtitleAdvance.TryGetValue(ch, out var a) ? a : 10;
        return width;
    }

    /// <summary>일본어 전사에 실제로 말이 들어 있는가.</summary>
    /// <remarks>
    /// 자동 분류(kind)를 믿으면 대사의 40% 를 놓친다 -- 배경음 위에 얹힌
    /// 내레이션을 음악으로 본다.  트랙 17 의 오프닝 내레이션 15 개가 통째로
    /// 그렇게 숨어 있었다.  그래서 화면 필터는 분류가 아니라 **글자**로 판단한다.
    /// </remarks>
    private static bool LooksLikeSpeech(string japanese)
    {
        var text = japanese.Trim();
        if (text.Length < 6) return false;
        foreach (var noise in Hallucinations) if (text.Contains(noise)) return false;
        return true;
    }

    // Whisper 가 무음·음악 구간에서 흔히 뱉는 문구.  내용이 아니다.
    private static readonly string[] Hallucinations = {
        "ご視聴ありがとう", "ご清聴ありがとう", "チャンネル登録", "最後まで視聴",
        "サウンドゥ", "Sound Hodori", "おだいじに",
    };

    /// <summary>선택한 CD-DA 트랙을 통째로 듣는다.</summary>
    /// <remarks>
    /// 자막 시간이 **트랙 기준 절대시각**이므로 트랙 통짜를 틀어야 싱크가 맞는다.
    /// clip 조각(logs/cdda_clips/)은 clip 안에서만 0 초로 시작해서 쓸 수 없다.
    /// </remarks>
    private void PlaySelectedCddaClip()
    {
        cddaPartGrid.EndEdit();
        var track = SelectedCddaClip();          // 접힌 표에서 이 값은 트랙 번호다
        if (track.Length == 0) { cddaSummary.Text = "먼저 트랙을 고르세요"; return; }
        var wav = Path.Combine(root, "logs", "cdda", $"track{track}.wav");
        if (!File.Exists(wav)) { cddaSummary.Text = "트랙 소리 파일이 없다: " + Path.GetFileName(wav); return; }
        try
        {
            RefreshCddaTimeline();
            // 아직 받아적지 않은 꼬리가 얼마나 남았는지 바로 보이게 한다.
            var seg = SelectedCddaSegment();
            var written = seg == null ? 0 : ParseDouble(cddaSegments.Get(seg, "seconds"));
            var whole = SelectedCddaDuration();
            var tail = whole - written;
            cddaSummary.Text = StartClip(wav, cddaTimeline, whole)
                               + $" · 트랙 {track} (통짜 {whole:0.0}초)"
                               + (tail > 0.5 ? $" · ★미기록 꼬리 {tail:0.0}초" : "");
        }
        catch (Exception error) { cddaSummary.Text = "재생 실패: " + error.Message; }
    }

    private double SelectedCddaDuration()
    {
        var seg = SelectedCddaSegment();
        if (seg == null) return 0;
        // ★ 2026-09-05.  접힌 행의 `seconds` 는 **마지막 클립이 끝나는 시각**이지
        //   트랙 길이가 아니다.  그것만 쓰면 아직 받아적지 않은 꼬리가 타임라인
        //   오른쪽 밖으로 밀려나 (실측 전 트랙 합계 143.7 초) 소리는 나는데
        //   자막을 걸 자리가 없다 -- 트랙 09 는 22.92 초에서 눈금이 끝나는데
        //   말은 27.5 초까지 있었다.  그래서 **실제 WAV 길이와 큰 쪽**을 쓴다.
        var track = cddaSegments.Get(seg, "track");
        return Math.Max(ParseDouble(cddaSegments.Get(seg, "seconds")),
                        WavLengthSeconds(Path.Combine(root, "logs", "cdda", $"track{track}.wav")));
    }

    private void RefreshCddaTimeline()
    {
        var clip = SelectedCddaClip();
        cddaTimeline.DurationSeconds = Math.Max(0.01, SelectedCddaDuration());
        cddaTimeline.Spans = CddaPartsOf(clip)
            .Select(r => new SubtitleTimeline.Span(ParseDouble(cddaSubs.Get(r, "start_sec")),
                ParseDouble(cddaSubs.Get(r, "duration_sec")),
                BlockLabel(cddaSubs.Get(r, "part"), cddaSubs.Get(r, "ko_text")), r)).ToList();
        cddaTimeline.SelectByTag(cddaPartGrid.CurrentRow?.Tag);
        UpdateCddaFocusView();
        cddaTimeline.Invalidate();
    }

    private static Button Button(string text, EventHandler action) { var button = new Button { Text = text, AutoSize = true, Height = 28 }; button.Click += action; return button; }
    private static DataGridView NewGrid() => new() { Dock = DockStyle.Fill, ReadOnly = true, AllowUserToAddRows = false, AllowUserToDeleteRows = false, SelectionMode = DataGridViewSelectionMode.FullRowSelect, MultiSelect = false, AutoSizeRowsMode = DataGridViewAutoSizeRowsMode.None, RowHeadersVisible = false, BackgroundColor = Theme.Input, ClipboardCopyMode = DataGridViewClipboardCopyMode.EnableAlwaysIncludeHeaderText };
    private static DataGridView NewEditableGrid() => new() { Dock = DockStyle.Fill, ReadOnly = false, AllowUserToAddRows = false, AllowUserToDeleteRows = false, SelectionMode = DataGridViewSelectionMode.FullRowSelect, MultiSelect = false, AutoSizeRowsMode = DataGridViewAutoSizeRowsMode.None, RowHeadersVisible = false, BackgroundColor = Theme.Input, ClipboardCopyMode = DataGridViewClipboardCopyMode.EnableAlwaysIncludeHeaderText };
    private static string SceneOf(string value) => string.Join(",", Regex.Matches(value ?? "", @"(?<![0-9A-F])([0-9A-F]{6}):", RegexOptions.IgnoreCase).Select(m => m.Groups[1].Value.ToUpperInvariant()).Distinct());
    // 원문에 실제로 쓰이는 FE 값은 1·2·3·6 (실측 2026-08-19).  [0-4] 로 두면
    // {FE:6} 이 토큰으로 안 잡혀 DisplayCells 가 6 칸으로 세고, 빌더 쪽 코덱은
    // 아예 ｛ＦＥ：６｝ 라는 글자로 인코딩한다.  DecodeSource 가 `:X` 로 뽑으므로
    // 16 진수 한 자리를 받는다.
    private static readonly Regex FeTokenRegex = new(@"\{FE:([0-9A-Fa-f])\}", RegexOptions.IgnoreCase | RegexOptions.Compiled);
    private static string FeControlSequence(string text) => string.Join(",", FeTokenRegex.Matches(text ?? "").Select(m => m.Groups[1].Value));
    private static bool FeControlsMatch(string jpText, string koText) => FeControlSequence(jpText) == FeControlSequence(koText);
    private static bool HasOmittedFe(string jpText, string koText)
    {
        var translation = (koText ?? "").Trim();
        return translation.Length > 0 && translation != "{EMPTY}" && FeTokenRegex.IsMatch(jpText ?? "") && !FeTokenRegex.IsMatch(translation);
    }
    /// <summary>화자 표에 있는 이름인가.  본문 사슬에 끼면 안 되는 줄이다.</summary>
    private bool IsSpeakerName(string japanese)
    {
        var wanted = AuditEngine.VisibleNormalize(japanese ?? "").Trim();
        if (wanted.Length == 0) return false;
        var column = speakers.Column("jp_name");
        if (column < 0) return false;
        foreach (var row in speakers.Rows)
        {
            var name = AuditEngine.VisibleNormalize(speakers.Get(row, "jp_name")).Trim();
            if (name.Length > 0 && name == wanted) return true;
        }
        return false;
    }

    private static string NormalizeEllipsis(string text) => (text ?? "").Replace("...", "…").Replace("⋯", "…");

    private static double DisplayCells(string text)
    {
        if (text.Trim() == "{EMPTY}") return 0;
        return NormalizeEllipsis(FeTokenRegex.Replace(text, "")).Sum(ch => ch is '\r' or '\n' ? 0 : 1);
    }

    // A line break -- typed as Enter or written as {BR} -- compiles to the FD
    // command, so the renderer starts a new line.  The 18-cell limit applies to
    // each displayed line, not to the record, which is why the total is the
    // wrong number to check once a record holds more than one line.
    private static readonly Regex BrTokenRegex = new(@"\{BR\}", RegexOptions.IgnoreCase | RegexOptions.Compiled);

    // Every line after a break carries one leading cell.  The renderer's FD
    // leaves the cursor one cell left of where the first line started, so the
    // builder always emits a full-width space after FD -- see
    // extraction\translation\layout_markup.py, iter_layout_units.  The count
    // has to include it or an 18-cell continuation compiles to 19 while this
    // form still reports 18/18 OK.  Idempotent, matching the builder: a space
    // the translator typed is used as-is rather than doubled.
    private static string[] LayoutLines(string text)
    {
        var lines = BrTokenRegex.Replace(text ?? "", "\n")
            .Replace("\r\n", "\n").Replace('\r', '\n').Split('\n');
        for (var index = 1; index < lines.Length; index++)
            if (!lines[index].StartsWith(" ", StringComparison.Ordinal)
                && !lines[index].StartsWith("　", StringComparison.Ordinal))
                lines[index] = "　" + lines[index];
        return lines;
    }

    /// <summary>
    /// Does this row break a limit that stops the build?
    ///
    /// Two hard ceilings, both raised by stage 3 rather than truncated:
    /// 18 cells per displayed line and 80 encoded bytes (TEXT_SPAN 0x60 =
    /// 16 bytes of metadata + 80 of text).
    ///
    /// The third one -- 15 distinct Hangul per record -- was retired on
    /// 2026-08-18 with the BIOS font path.  The record no longer carries its
    /// own glyphs (atlas 0 glyphs, 0 B); the system card draws them from the
    /// slot map, so a record can name as many different syllables as it likes.
    /// The budget that replaced it is project-wide, not per row: the slot map
    /// has a finite number of free kanji cells (187 as of that date), and
    /// tools/check_master.py reports it under [slots].
    /// </summary>
    private bool ExceedsRecordLimits(List<string> row, string ko, double cells, int limit) =>
        cells > limit
        || EncodedBytes(ko) > RecordByteCapacity;

    /// <summary>Cells of the widest displayed line.</summary>
    private static double WidestLineCells(string text)
    {
        if (text.Trim() == "{EMPTY}") return 0;
        return LayoutLines(text).Select(DisplayCells).DefaultIfEmpty(0).Max();
    }


    /// <summary>
    /// Bytes the encoder will emit.  Mirrors game_text_codec: every Hangul,
    /// space, ellipsis, period and FE token costs two, a line break one, plus
    /// the terminator.  The record can hold 80.
    /// </summary>
    private static int EncodedBytes(string text)
    {
        if (text.Trim() == "{EMPTY}") return 1;
        var total = 1;
        foreach (var line in LayoutLines(text))
        {
            total += NormalizeEllipsis(FeTokenRegex.Replace(line, "")).Sum(_ => 2)
                   + FeTokenRegex.Matches(line).Count * 2;
        }
        return total + Math.Max(0, LayoutLines(text).Length - 1);
    }

    private const int RecordByteCapacity = 80;   // TEXT_SPAN 0x60 - 16 B metadata
    private static int ApproxBytes(string text)
    {
        if (text.Trim() == "{EMPTY}") return 1;
        var controls = FeTokenRegex.Matches(text).Count;
        var visible = NormalizeEllipsis(FeTokenRegex.Replace(text, "")).Sum(ch => ch is '\r' or '\n' ? 0 : 1);
        var lineBreaks = text.Count(ch => ch == '\n');
        return controls * 2 + visible * 2 + lineBreaks + 1;
    }
    private static string CellsText(double value) => value % 1 == 0 ? ((int)value).ToString() : value.ToString("0.0");
    private static int ParseInt(string value, int fallback) => int.TryParse(value, out var result) ? result : fallback;
    private static double ParseDouble(string value) => double.TryParse(value, System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out var result) ? result : 0;
    private static long VersionKey(string path) { var p = Path.GetFileName(path).Split('.').Select(x => int.TryParse(x, out var n) ? n : 0).ToArray(); return p.Aggregate(0L, (a, n) => a * 1000 + n); }
    private static void OpenPath(string path) { Process.Start(new ProcessStartInfo("explorer.exe", $"\"{path}\"") { UseShellExecute = true }); }
}
