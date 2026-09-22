using System.Text;

namespace SnatcherTranslationStudio;

internal sealed class TsvDocument
{
    public string Path { get; }
    public Encoding Encoding { get; }
    public List<string> Headers { get; }
    public List<List<string>> Rows { get; }
    public bool Dirty { get; set; }

    private TsvDocument(string path, Encoding encoding, List<string> headers, List<List<string>> rows)
    {
        Path = path;
        Encoding = encoding;
        Headers = headers;
        Rows = rows;
    }

    public static TsvDocument Load(string path, IReadOnlyList<string>? headerFallback = null)
    {
        var bytes = ReadAllBytesShared(path);
        Encoding encoding;
        string text;
        if (bytes.Length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE)
        {
            encoding = new UnicodeEncoding(false, true);
            text = encoding.GetString(bytes, 2, bytes.Length - 2);
        }
        else if (bytes.Length >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF)
        {
            encoding = new UTF8Encoding(true);
            text = encoding.GetString(bytes, 3, bytes.Length - 3);
        }
        else
        {
            // Without a BOM there is nothing in the file that names its encoding.
            // Assuming UTF-8 is only safe if the bytes actually ARE valid UTF-8:
            // a CP949 (Korean ANSI) file decoded as UTF-8 turns every Korean and
            // Japanese character into U+FFFD, and the next Save then writes those
            // replacement characters back -- destroying the text permanently.
            // Pipeline scripts that call Python's open() without encoding= on a
            // Korean Windows produce exactly such CP949 files, so decode strictly
            // and fall back rather than trusting the guess.
            try
            {
                text = new UTF8Encoding(false, throwOnInvalidBytes: true).GetString(bytes);
                encoding = new UTF8Encoding(false);
            }
            catch (DecoderFallbackException)
            {
                text = Encoding.GetEncoding(949).GetString(bytes);
                // Save the recovered text as UTF-8 *with* a BOM so the file
                // becomes self-describing and this guess is never needed again.
                encoding = new UTF8Encoding(true);
            }
        }
        var parsed = Parse(text);
        if (parsed.Count == 0) throw new InvalidDataException($"Empty TSV: {path}");
        // Mesen can continue appending after the Studio deletes an active log.
        // In that case the append recreates the file without its header.  Audit
        // TSVs have a fixed schema, so recover those rows instead of treating
        // the first capture as a header and silently dropping the whole log.
        var hasExpectedHeader = headerFallback == null
            || parsed[0].Count > 0 && string.Equals(parsed[0][0], headerFallback[0], StringComparison.OrdinalIgnoreCase);
        var headers = hasExpectedHeader ? parsed[0] : headerFallback!.ToList();
        var width = headers.Count;
        var rows = (hasExpectedHeader ? parsed.Skip(1) : parsed).Where(r => r.Any(v => v.Length > 0)).ToList();
        foreach (var row in rows) while (row.Count < width) row.Add("");
        return new TsvDocument(path, encoding, headers, rows);
    }

    private static byte[] ReadAllBytesShared(string path)
    {
        IOException? lastError = null;
        for (var attempt = 0; attempt < 8; attempt++)
        {
            try
            {
                using var stream = new FileStream(path, FileMode.Open, FileAccess.Read,
                    FileShare.ReadWrite | FileShare.Delete);
                using var buffer = new MemoryStream();
                stream.CopyTo(buffer);
                return buffer.ToArray();
            }
            catch (IOException ex)
            {
                lastError = ex;
                Thread.Sleep(75);
            }
        }
        throw lastError ?? new IOException($"Cannot read TSV: {path}");
    }

    public int Column(string name) => Headers.FindIndex(h => h == name);
    public void EnsureColumn(string name)
    {
        if (Column(name) >= 0) return;
        Headers.Add(name);
        foreach (var row in Rows) row.Add("");
        Dirty = true;
    }
    public string Get(List<string> row, string name)
    {
        var index = Column(name);
        return index >= 0 && index < row.Count ? row[index] : "";
    }
    public void Set(List<string> row, string name, string value)
    {
        var index = Column(name);
        if (index < 0) return;
        while (row.Count <= index) row.Add("");
        if (row[index] == value) return;
        row[index] = value;
        Dirty = true;
    }

    public void Save(string backupDirectory)
    {
        Directory.CreateDirectory(backupDirectory);
        var stamp = DateTime.Now.ToString("yyyyMMdd_HHmmss_fff");
        File.Copy(Path, System.IO.Path.Combine(backupDirectory, $"{stamp}_{System.IO.Path.GetFileName(Path)}"), true);
        var content = Serialize(new[] { Headers }.Concat(Rows));
        var temp = Path + ".tmp";
        File.WriteAllText(temp, content, SafeEncodingFor(content));
        File.Move(temp, Path, true);
        Dirty = false;
    }

    /// <summary>
    /// 저장에 쓸 인코딩.  **손실이 나는 인코딩으로는 절대 쓰지 않는다.**
    ///
    /// 2026-08-22 사고: `ui_text.tsv` 와 `speaker_name_standard.tsv` 가 CP949 로
    /// 써져 있었고, CP949 에 없는 글자가 전부 `?` 로 박혀 있었다 (受付嬢 -> "….?").
    /// 화자표가 그래서 이름을 못 찾았고, 대사 첫 줄 화자명이 화면에 일본어로 남았다.
    ///
    /// Load 쪽에는 이미 방어가 있다 -- CP949 로 읽으면 저장 인코딩을 UTF-8 BOM 으로
    /// 올려 둔다.  그런데도 깨진 파일이 나왔다.  즉 `Encoding` 이 어떤 경로로든
    /// 손실 인코딩이 될 수 있다는 뜻이고, 그러면 **읽는 쪽이 아니라 쓰는 쪽에서**
    /// 막아야 한다.
    ///
    /// 방법은 왕복 검사다.  쓰려는 인코딩으로 인코딩했다가 다시 디코딩해서 원문과
    /// 다르면 그 인코딩은 이 내용을 담지 못하는 것이므로 UTF-8 BOM 으로 바꾼다.
    /// UTF-16 은 그대로 둔다 -- 옛 한국어 엑셀 호환 때문에 일부러 쓰는 형식이다
    /// (tsv_io.py 의 같은 규율).
    /// </summary>
    private Encoding SafeEncodingFor(string content)
    {
        if (Encoding is UnicodeEncoding) return Encoding;
        try
        {
            var bytes = Encoding.GetBytes(content);
            if (Encoding.GetString(bytes) == content) return Encoding;
        }
        catch (EncoderFallbackException)
        {
            // 아래로 떨어진다
        }
        return new UTF8Encoding(true);
    }

    public static List<List<string>> Parse(string text)
    {
        var rows = new List<List<string>>();
        var row = new List<string>();
        var field = new StringBuilder();
        var quoted = false;
        for (var i = 0; i < text.Length; i++)
        {
            var ch = text[i];
            if (quoted)
            {
                if (ch == '"' && i + 1 < text.Length && text[i + 1] == '"') { field.Append('"'); i++; }
                else if (ch == '"') quoted = false;
                else field.Append(ch);
            }
            else if (ch == '"') quoted = true;
            else if (ch == '\t') { row.Add(field.ToString()); field.Clear(); }
            else if (ch == '\r') { }
            else if (ch == '\n')
            {
                row.Add(field.ToString()); field.Clear(); rows.Add(row); row = new List<string>();
            }
            else field.Append(ch);
        }
        if (field.Length > 0 || row.Count > 0) { row.Add(field.ToString()); rows.Add(row); }
        return rows;
    }

    public static string Serialize(IEnumerable<IEnumerable<string>> rows)
    {
        return string.Join("\r\n", rows.Select(row => string.Join("\t", row.Select(Escape)))) + "\r\n";
    }
    private static string Escape(string value)
    {
        if (!value.Contains('"') && !value.Contains('\t') && !value.Contains('\r') && !value.Contains('\n')) return value;
        return '"' + value.Replace("\"", "\"\"") + '"';
    }
}
