using System.Text;
using System.Text.RegularExpressions;

namespace SnatcherTranslationStudio;

internal sealed record AuditItem(
    string Classification, int Count, int FirstSeq, int FirstFrame, string State, string AfterControl, string ControlOrigin,
    string Japanese, string SourceHex, string ExpectedKorean, string References,
    string Scene, string MasterStatus, string MasterKorean, string NearestJapanese,
    double Similarity, string Action, string Target, string Pack, string Speaker,
    // The line captured immediately before this one, when that line said it
    // continues (CONT/BR).  A sentence too long for the 18-cell box arrives as
    // two captures, and if the first half is already in MASTER only the second
    // half is imported -- landing at the end of the file, far from its head and
    // untranslatable on its own.  This is what lets the import put it back
    // underneath the line it finishes.  Empty when the previous capture closed
    // its own sentence, so unrelated lines are never glued together.
    string ContinuesFrom);

internal static class AuditEngine
{
    private sealed record BuildRecord(int State, string SourceHex, string Korean, string Reference, string Target);
    private static readonly string[] RuntimeAuditHeaders =
    {
        "seq", "frame", "ptr", "after_ptr", "state_before", "state_after", "read_status",
        "changed", "source_hex", "after_hex", "channel", "after_control", "control_origin", "control_hex", "source_cells",
        "static_refs", "static_scene", "pack", "sector"
    };

    public static TsvDocument LoadRuntimeAudit(string path) => TsvDocument.Load(path, RuntimeAuditHeaders);

    public static List<AuditItem> Analyze(
        string rawPath, string recordsPath, TsvDocument master,
        TsvDocument speakers, TsvDocument ui)
    {
        var raw = LoadRuntimeAudit(rawPath);
        var records = TsvDocument.Load(recordsPath);
        var known = records.Rows.Select(r => new BuildRecord(
            ParseHexInt(records.Get(r, "state")), CompactHex(records.Get(r, "source_hex")),
            records.Get(r, "ko_text"), records.Get(r, "reference"),
            TargetFromReference(records.Get(r, "reference")))).ToList();
        var bySource = known.GroupBy(r => r.SourceHex).ToDictionary(g => g.Key, g => g.ToList());
        var masterVisible = master.Rows
            .Where(r => !string.IsNullOrWhiteSpace(master.Get(r, "jp_text")))
            .GroupBy(r => VisibleNormalize(master.Get(r, "jp_text")))
            .ToDictionary(g => g.Key, g => g.ToList());
        var speakerVisible = speakers.Rows
            .Where(r => !string.IsNullOrWhiteSpace(speakers.Get(r, "jp_name")))
            .GroupBy(r => VisibleNormalize(speakers.Get(r, "jp_name")))
            .ToDictionary(g => g.Key, g => g.ToList());
        var uiVisible = ui.Rows
            .Where(r => !string.IsNullOrWhiteSpace(ui.Get(r, "jp_text")))
            .GroupBy(r => VisibleNormalize(ui.Get(r, "jp_text")))
            .ToDictionary(g => g.Key, g => g.ToList());
        var aggregate = new Dictionary<string, AuditItem>();
        // 게임은 화자명을 대사와 같은 스트림으로 흘린다.  실측(2026-08-14):
        //   seq 149  ギリアン      <- 화자명 캡처
        //   seq 150  대사
        //   seq 151  대사
        //   seq 153  ギリアン      <- 다음 묶음
        // 그래서 원시 로그를 순서대로 훑으며 화자명이 나오면 기억해 두었다가
        // 뒤따르는 대사에 붙이면 된다.  Lua 는 손댈 필요가 없다 -- source_hex 는
        // 처음부터 모든 로그에 있던 값이라 기존 로그에도 그대로 소급된다.
        // 샘플에서 대사의 96% 에 화자가 붙었다.
        var currentSpeaker = "";
        // The previous capture in timeline order, and whether it said it runs
        // on.  Only a CONT/BR predecessor is a real head; an END one closed its
        // own sentence and has nothing to do with what follows.
        var previousJapanese = "";
        var previousContinues = false;

        foreach (var row in raw.Rows)
        {
            var sourceHex = CompactHex(raw.Get(row, "source_hex"));
            if (sourceHex.Length == 0) continue;
            var stateText = raw.Get(row, "state_before");
            var afterControl = raw.Get(row, "after_control").Trim().ToUpperInvariant();
            if (afterControl is not ("BR" or "PAGE" or "CONT" or "END")) afterControl = "END";
            var controlOrigin = raw.Get(row, "control_origin").Trim();
            if (controlOrigin.Length == 0) controlOrigin = "LEGACY_DEFAULT";
            var state = ParseHexInt(stateText);
            var changed = raw.Get(row, "changed").Equals("yes", StringComparison.OrdinalIgnoreCase);
            var japanese = DecodeSource(sourceHex);
            // 화자명 자체도 하나의 캡처로 들어온다.  이름표를 만나면 그 뒤의
            // 대사들이 그 인물 것이므로 여기서 갱신한다.  이름표 행 자신도
            // 같은 값을 달고 나가지만 target 이 "화자명"이라 구분된다.
            if (speakerVisible.TryGetValue(VisibleNormalize(japanese), out var speakerHere)
                && speakerHere.Count > 0)
            {
                var name = speakers.Get(speakerHere[0], "ko_name").Trim();
                if (name.Length > 0) currentSpeaker = name;
            }
            var exact = bySource.TryGetValue(sourceHex, out var found) ? found : new List<BuildRecord>();
            var applicable = exact.Where(r => r.State == 0 || r.State == state).ToList();
            var visibleKey = VisibleNormalize(japanese);
            var masters = masterVisible.TryGetValue(visibleKey, out var foundMaster) ? foundMaster : new List<List<string>>();
            var speakerMatches = speakerVisible.TryGetValue(visibleKey, out var foundSpeaker) ? foundSpeaker : new List<List<string>>();
            var uiMatches = uiVisible.TryGetValue(visibleKey, out var foundUi) ? foundUi : new List<List<string>>();
            var pointer = raw.Get(row, "ptr").ToUpperInvariant();
            var channel = raw.Get(row, "channel").ToUpperInvariant();
            // Legacy UI collectors started at $349A, dropping the first
            // Shift-JIS lead byte and producing transient fake MISS rows.
            if (channel.Contains("UI") && pointer == "349A") continue;
            var target = exact.Select(r => r.Target).FirstOrDefault(t => t != "대사")
                ?? (channel.Contains("UI") || pointer is "3499" or "349A" ? "UI"
                    : uiMatches.Count > 0 ? "UI"
                    : speakerMatches.Count > 0 ? "화자명"
                    : "대사");
            BuildRecord? nearest = null;
            var score = 0.0;
            string classification, action;
            if (changed) { classification = "HIT"; action = "정상 치환"; }
            else if (channel == "UI_BUFFER" && applicable.Count > 0)
            {
                classification = "HIT";
                action = "UI 원문 수집 완료 (치환 판정은 preloader 로그 사용)";
            }
            else if (applicable.Count > 0) { classification = "LOOKUP_FAIL"; action = "빌드 레코드는 있으나 치환 실패: 검색/후킹 타이밍 확인"; }
            else if (exact.Count > 0)
            {
                // ROUTE_FAIL is not a fault.  The Japanese IS in the build; it is
                // just registered under other trie states, so this occurrence has
                // no version to use.  The fix is a per-state copy of the row --
                // the engine already routes by state -- so name the states and
                // the rows that hold them instead of saying "check routing".
                classification = "ROUTE_FAIL";
                var registered = string.Join(", ", exact
                    .Select(r => $"{r.State:X4}" + (r.Reference.Length > 0 ? $"({r.Reference.Split(',')[0]})" : ""))
                    .Distinct());
                action = $"이 문맥용 행 없음: 필요 state={stateText}, 등록된 state={registered} → 해당 state 사본 필요";
            }
            else if (masters.Count > 0 || speakerMatches.Count > 0 || uiMatches.Count > 0)
            {
                classification = "MASTER_ONLY";
                action = target == "대사"
                    ? "MASTER에는 있으나 현재 빌드에서 제외됨: O/상태/예외처리 확인"
                    : $"{target} 번역표에는 있으나 현재 빌드에서 치환되지 않음";
            }
            else
            {
                foreach (var candidate in known)
                {
                    var candidateJp = DecodeSource(candidate.SourceHex);
                    var candidateScore = Similarity(Normalize(japanese), Normalize(candidateJp));
                    if (candidateScore > score) { score = candidateScore; nearest = candidate; }
                }
                if (nearest != null && score >= 0.78) { classification = "NEAR"; action = "조합된 원문이 미세하게 다름: 런타임 완성 문자열을 신규 등록"; }
                else { classification = "MISS"; action = "MASTER에 없는 원문: 번역 큐에 추가"; }
            }

            var refs = applicable.Count > 0 ? applicable : exact;
            var refText = string.Join(",", refs.Select(r => r.Reference).Distinct());
            var masterRefs = target switch
            {
                "UI" => string.Join(",", uiMatches.Select(r => $"ui:{ui.Get(r, "ui_id")}")),
                "화자명" => string.Join(",", speakerMatches.Select(r => $"speaker:{speakers.Get(r, "speaker_id")}")),
                _ => string.Join(",", masters.Select(r => $"{master.Get(r, "text_key")}:{master.Get(r, "line_no")}")),
            };
            if (refText.Length == 0) refText = masterRefs;
            // New Lua captures carry the exact static key/scene produced by
            // the host-side index.  Prefer it over visible-text matching;
            // repeated Japanese fragments must not lose their real record.
            var loggedRefs = raw.Get(row, "static_refs").Trim();
            var loggedScene = raw.Get(row, "static_scene").Trim();
            if (loggedRefs.Length > 0) refText = loggedRefs;
            var scene = loggedScene.Length > 0
                ? loggedScene
                : SceneFromReferences(refText.Length > 0 ? refText : string.Join(",", masters.Select(r => master.Get(r, "source_refs"))));
            // A visually identical buffer may legally end in a different
            // structural control. Keep those as separate timeline entries so
            // importing one cannot silently turn a CONT/BR into END.
            var key = $"{target}|{classification}|{stateText}|{afterControl}|{sourceHex}";
            var item = new AuditItem(classification, 1, ParseInt(raw.Get(row, "seq")), ParseInt(raw.Get(row, "frame")),
                stateText, afterControl, controlOrigin, japanese, sourceHex,
                string.Join(" | ", refs.Select(r => r.Korean).Where(v => v.Length > 0).Distinct()), refText, scene,
                string.Join(" | ", masters.Select(r => master.Get(r, "status")).Distinct()),
                string.Join(" | ", masters.Select(r => master.Get(r, "ko_text")).Where(v => v.Length > 0).Distinct()),
                nearest == null ? "" : DecodeSource(nearest.SourceHex), score, action, target,
                raw.Get(row, "pack").Trim(), currentSpeaker,
                previousContinues ? previousJapanese : "");
            previousJapanese = japanese;
            previousContinues = afterControl is "CONT" or "BR";
            // 같은 문장이 여러 번 잡히면 먼저 붙은 화자를 지킨다.  나중 캡처가
            // 이름표 없이 시작하면 화자가 비어 덮어써질 수 있기 때문이다.
            if (aggregate.TryGetValue(key, out var old)) item = item with { Count = old.Count + 1, FirstSeq = Math.Min(old.FirstSeq, item.FirstSeq), FirstFrame = Math.Min(old.FirstFrame, item.FirstFrame), Speaker = old.Speaker.Length > 0 ? old.Speaker : item.Speaker,
                // Same rule as the speaker: a later capture that began mid-block
                // has no predecessor, and that blank must not erase the head we
                // already saw.
                ContinuesFrom = old.ContinuesFrom.Length > 0 ? old.ContinuesFrom : item.ContinuesFrom };
            aggregate[key] = item;
        }
        var order = new Dictionary<string, int> { ["LOOKUP_FAIL"] = 0, ["ROUTE_FAIL"] = 1, ["MASTER_ONLY"] = 2, ["NEAR"] = 3, ["MISS"] = 4, ["HIT"] = 5 };
        // The audit is a playthrough timeline.  Never regroup it by result
        // type here: adjacent records can be two lines of one dialogue.
        return aggregate.Values.OrderBy(v => v.FirstSeq).ToList();
    }

    public static List<AuditItem> LoadCatalog(string path)
    {
        if (!File.Exists(path)) return new List<AuditItem>();
        var doc = TsvDocument.Load(path);
        return doc.Rows.Select(row => new AuditItem(
            doc.Get(row, "classification"), ParseInt(doc.Get(row, "count")),
            ParseInt(doc.Get(row, "first_seq")), ParseInt(doc.Get(row, "first_frame")),
            doc.Get(row, "state"), doc.Get(row, "after_control") is "BR" or "PAGE" or "CONT" or "END" ? doc.Get(row, "after_control") : "END",
            string.IsNullOrWhiteSpace(doc.Get(row, "control_origin")) ? "LEGACY_CATALOG" : doc.Get(row, "control_origin"), doc.Get(row, "jp_text"), CompactHex(doc.Get(row, "source_hex")),
            doc.Get(row, "expected_ko"), doc.Get(row, "references"), doc.Get(row, "scene"),
            doc.Get(row, "master_status"), doc.Get(row, "master_ko"), doc.Get(row, "nearest_jp"),
            double.TryParse(doc.Get(row, "similarity"), out var similarity) ? similarity : 0,
            doc.Get(row, "action"), doc.Get(row, "target"), doc.Get(row, "pack"), doc.Get(row, "speaker"),
            // Catalogs written before this column existed simply have none.
            doc.Get(row, "continues_from"))).ToList();
    }

    public static List<AuditItem> MergeCatalog(IEnumerable<AuditItem> saved, IEnumerable<AuditItem> current)
    {
        static string Key(AuditItem item) => $"{item.Target}|{item.State}|{item.AfterControl}|{CompactHex(item.SourceHex)}";
        var merged = saved.ToDictionary(Key, item => item, StringComparer.OrdinalIgnoreCase);
        foreach (var item in current)
        {
            var key = Key(item);
            if (!merged.TryGetValue(key, out var old)) { merged[key] = item; continue; }
            merged[key] = item with
            {
                Count = Math.Max(old.Count, item.Count),
                FirstSeq = Math.Min(old.FirstSeq, item.FirstSeq),
                FirstFrame = Math.Min(old.FirstFrame, item.FirstFrame),
                ExpectedKorean = item.ExpectedKorean.Length > 0 ? item.ExpectedKorean : old.ExpectedKorean,
                References = MergeCsv(old.References, item.References),
                MasterStatus = item.MasterStatus.Length > 0 ? item.MasterStatus : old.MasterStatus,
                MasterKorean = item.MasterKorean.Length > 0 ? item.MasterKorean : old.MasterKorean,
                // A log written before the Lua recorded the bank has none; never
                // let that blank overwrite a pack already observed.
                Pack = item.Pack.Length > 0 ? item.Pack : old.Pack,
                // 같은 이유로 화자도 지킨다.  이름표 없이 시작한 세션의 빈 값이
                // 이미 귀속된 화자를 지우면 안 된다.
                Speaker = item.Speaker.Length > 0 ? item.Speaker : old.Speaker,
                ContinuesFrom = item.ContinuesFrom.Length > 0 ? item.ContinuesFrom : old.ContinuesFrom,
            };
        }
        var order = new Dictionary<string, int> { ["LOOKUP_FAIL"] = 0, ["ROUTE_FAIL"] = 1, ["MASTER_ONLY"] = 2, ["NEAR"] = 3, ["MISS"] = 4, ["HIT"] = 5 };
        // Keep the durable catalog in exactly the first-observed runtime
        // order too.  Classification is displayed as a column, not a sort
        // key, so MISS/NEAR/route diagnostics do not split a conversation.
        return merged.Values.OrderBy(value => value.FirstSeq).ToList();
    }

    // A catalog entry is only useful while it has not been incorporated into
    // one of the editable translation tables. The raw Mesen log is reset for
    // every play session, but the catalog is durable; without this cleanup an
    // old MISS stays visible forever even after the user added it to MASTER.
    public static List<AuditItem> DropEntriesAlreadyInTables(
        IEnumerable<AuditItem> items, TsvDocument master, TsvDocument speakers, TsvDocument ui)
    {
        var known = new HashSet<string>(StringComparer.Ordinal);
        void Add(TsvDocument document, string column)
        {
            foreach (var row in document.Rows)
            {
                var value = document.Get(row, column);
                if (!string.IsNullOrWhiteSpace(value)) known.Add(VisibleNormalize(value));
            }
        }
        Add(master, "jp_text");
        Add(speakers, "jp_name");
        Add(ui, "jp_text");

        return items.Where(item =>
            item.Classification == "HIT" || !known.Contains(VisibleNormalize(item.Japanese))).ToList();
    }

    private static string MergeCsv(string left, string right) => string.Join(",",
        left.Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
            .Concat(right.Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
            .Distinct(StringComparer.OrdinalIgnoreCase));

    public static void Export(string path, IEnumerable<AuditItem> items)
    {
        var headers = new[] { "classification", "target", "count", "first_seq", "first_frame", "state", "after_control", "control_origin", "scene", "jp_text", "source_hex", "expected_ko", "references", "master_status", "master_ko", "nearest_jp", "similarity", "action", "pack", "speaker", "continues_from" };
        var rows = items.Select(x => new[] { x.Classification, x.Target, x.Count.ToString(), x.FirstSeq.ToString(), x.FirstFrame.ToString(), x.State, x.AfterControl, x.ControlOrigin, x.Scene, x.Japanese, x.SourceHex, x.ExpectedKorean, x.References, x.MasterStatus, x.MasterKorean, x.NearestJapanese, x.Similarity == 0 ? "" : x.Similarity.ToString("0.000"), x.Action, x.Pack, x.Speaker, x.ContinuesFrom });
        File.WriteAllText(path, TsvDocument.Serialize(new[] { headers }.Concat(rows)), new UnicodeEncoding(false, true));
    }

    public static string DecodeSource(string value)
    {
        byte[] data;
        try { data = Convert.FromHexString(value.Replace(" ", "")); } catch { return "<HEX ERROR>"; }
        var cp932 = Encoding.GetEncoding(932);
        var output = new StringBuilder();
        for (var i = 0; i < data.Length;)
        {
            if (data[i] == 0xFE && i + 1 < data.Length) { output.Append($"{{FE:{data[i + 1] & 0x0F:X}}}"); i += 2; continue; }
            var length = (((data[i] >= 0x81 && data[i] <= 0x9F) || (data[i] >= 0xE0 && data[i] <= 0xEF)) && i + 1 < data.Length) ? 2 : 1;
            try { output.Append(cp932.GetString(data, i, length)); } catch { output.Append($"<{data[i]:X2}>"); }
            i += length;
        }
        return output.ToString();
    }
    private static string CompactHex(string value) => string.Join(" ", value.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries)).ToUpperInvariant();
    private static string TargetFromReference(string value) =>
        value.StartsWith("ui:", StringComparison.OrdinalIgnoreCase) ? "UI" :
        value.StartsWith("speaker:", StringComparison.OrdinalIgnoreCase) ? "화자명" : "대사";
    private static string Normalize(string value) => Regex.Replace(value.Normalize(NormalizationForm.FormKC).Replace("…", "...").Replace("・", "·"), @"\s+", "");
    // Public so row placement in MainForm compares text by exactly the rule the
    // audit matched with.  Two copies of this would drift apart silently.
    public static string VisibleNormalize(string value) => Normalize(Regex.Replace(Regex.Replace(value, @"\{FE:[0-9A-Fa-f]+\}", ""), @"<[^>]+>", ""));
    private static int ParseHexInt(string value) => int.TryParse(value, System.Globalization.NumberStyles.HexNumber, null, out var result) ? result : 0;
    private static int ParseInt(string value) => int.TryParse(value, out var result) ? result : 0;
    private static string SceneFromReferences(string value)
    {
        var scenes = Regex.Matches(value ?? "", @"(?<![0-9A-F])([0-9A-F]{6}):", RegexOptions.IgnoreCase).Select(m => m.Groups[1].Value.ToUpperInvariant()).Distinct();
        return string.Join(",", scenes);
    }
    private static double Similarity(string a, string b)
    {
        if (a == b) return 1;
        if (a.Length == 0 || b.Length == 0) return 0;
        var previous = Enumerable.Range(0, b.Length + 1).ToArray();
        for (var i = 1; i <= a.Length; i++)
        {
            var current = new int[b.Length + 1]; current[0] = i;
            for (var j = 1; j <= b.Length; j++) current[j] = Math.Min(Math.Min(current[j - 1] + 1, previous[j] + 1), previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1));
            previous = current;
        }
        return 1.0 - (double)previous[b.Length] / Math.Max(a.Length, b.Length);
    }
}
