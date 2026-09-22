using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;

namespace SnatcherTranslationStudio;

/// <summary>WAV 한 개를 틀고 · 세우고 · 원하는 지점으로 건너뛰는 재생기.</summary>
/// <remarks>
/// 왜 SoundPlayer 를 버렸나
/// ------------------------
/// `System.Media.SoundPlayer` 는 `Play()` 와 `Stop()` 밖에 없다.  일시정지도,
/// "지금 몇 초인가" 도, "3.4 초부터 틀어라" 도 **원리적으로 없다**.  그래서
/// 타임라인의 노란 선을 스톱워치로 따로 굴렸고, 그 선은 소리와 아무 관계가 없는
/// 그냥 시계였다.  선을 끌어 소리를 그 자리로 보내려면 재생기 자체가 자리를
/// 알고 있어야 한다.
///
/// 대신 쓰는 것
/// ------------
/// `winmm.dll` 의 MCI 다.  윈도우에 원래 있어서 NuGet 을 안 붙여도 되고,
/// waveaudio 장치가 `play from` · `pause` · `resume` · `status position` 을
/// 전부 준다.  자막 싱크에 필요한 것이 딱 그것들이다.
///
/// 열리지 않으면
/// -------------
/// 어떤 WAV 는 MCI 가 못 연다 (드문 코덱 · 장치 점유).  그때는 조용히 죽지 말고
/// SoundPlayer 로 되돌아간다 -- 처음부터 듣는 것은 여전히 되어야 하니까.
/// 그 상태는 <see cref="Degraded"/> 로 알린다.  이때 자리 이동과 일시정지는
/// 흉내만 낸다 (되감아 다시 튼다).
/// </remarks>
internal sealed class ClipPlayer : IDisposable
{
    [DllImport("winmm.dll", CharSet = CharSet.Unicode)]
    private static extern int mciSendString(string command, StringBuilder? buffer,
                                            int bufferSize, IntPtr callback);

    [DllImport("winmm.dll", CharSet = CharSet.Unicode)]
    private static extern bool mciGetErrorString(int error, StringBuilder buffer, int bufferSize);

    // 별명은 프로세스 안에서 유일해야 한다.  스튜디오는 한 번에 한 소리만 튼다.
    private const string Alias = "snatcherstudioclip";

    private bool open;                      // MCI 로 열려 있나
    private System.Media.SoundPlayer? fallback;
    private readonly Stopwatch clock = new();   // 되돌아갔을 때 자리를 흉내내는 시계
    private double clockBase;                   // 그 시계의 0 이 가리키는 초
    private bool paused;

    /// <summary>지금 물린 파일.</summary>
    public string? Path { get; private set; }

    /// <summary>MCI 가 아니라 SoundPlayer 로 떨어졌나 (자리 이동이 부정확하다).</summary>
    public bool Degraded { get; private set; }

    /// <summary>자리를 정확히 옮길 수 있나.</summary>
    public bool CanSeek => open;

    /// <summary>파일 길이(초).  모르면 0.</summary>
    public double LengthSeconds { get; private set; }

    public bool IsPaused => paused;

    /// <summary>소리가 실제로 나고 있나.</summary>
    public bool IsPlaying
    {
        get
        {
            if (open) return Query("mode") == "playing";
            return fallback != null && !paused && clock.IsRunning
                   && clockBase + clock.Elapsed.TotalSeconds < LengthSeconds;
        }
    }

    /// <summary>지금 재생 위치(초).</summary>
    public double PositionSeconds
    {
        get
        {
            if (open && double.TryParse(Query("position"), out var ms)) return ms / 1000.0;
            var seconds = clockBase + (paused ? 0 : clock.Elapsed.TotalSeconds);
            return LengthSeconds > 0 ? Math.Clamp(seconds, 0, LengthSeconds) : Math.Max(0, seconds);
        }
    }

    // ------------------------------------------------------------------ 열기

    /// <summary>파일을 물린다.  이미 같은 파일이면 다시 안 연다.</summary>
    public bool Open(string path, out string error)
    {
        error = "";
        if (open && string.Equals(Path, path, StringComparison.OrdinalIgnoreCase)) return true;
        Close();
        Path = path;

        var code = Send($"open \"{path}\" type waveaudio alias {Alias}");
        if (code == 0)
        {
            open = true;
            Degraded = false;
            Send($"set {Alias} time format milliseconds");
            LengthSeconds = double.TryParse(Query("length"), out var ms) ? ms / 1000.0 : 0;
            return true;
        }

        // MCI 가 거절했다.  들리기라도 해야 하므로 SoundPlayer 로 내려간다.
        error = ErrorText(code);
        try
        {
            fallback = new System.Media.SoundPlayer(path);
            fallback.Load();
            Degraded = true;
            LengthSeconds = 0;      // SoundPlayer 는 길이를 안 알려준다 -- 바깥이 채운다
            return true;
        }
        catch (Exception problem)
        {
            fallback = null;
            error = problem.Message;
            Path = null;
            return false;
        }
    }

    /// <summary>SoundPlayer 로 떨어졌을 때 바깥이 아는 길이를 넣어 준다.</summary>
    public void HintLength(double seconds)
    {
        if (LengthSeconds <= 0 && seconds > 0) LengthSeconds = seconds;
    }

    // ---------------------------------------------------------------- 조작

    public void Play(double fromSeconds = 0)
    {
        paused = false;
        clockBase = Math.Max(0, fromSeconds);
        if (open)
        {
            Send($"play {Alias} from {(int)Math.Round(clockBase * 1000)}");
            clock.Reset();
            return;
        }
        // 되돌아간 경우: 중간부터는 못 튼다.  처음부터 틀고 시계만 맞춰 둔다.
        fallback?.Stop();
        fallback?.Play();
        clockBase = 0;
        clock.Restart();
    }

    public void Pause()
    {
        if (paused) return;
        if (open) { Send($"pause {Alias}"); paused = true; return; }
        clockBase += clock.Elapsed.TotalSeconds;
        clock.Reset();
        fallback?.Stop();
        paused = true;
    }

    public void Resume()
    {
        if (!paused) return;
        paused = false;
        if (open)
        {
            // `resume` 이 안 먹는 장치가 있어서 실패하면 자리부터 다시 튼다.
            if (Send($"resume {Alias}") != 0) Play(PositionSeconds);
            return;
        }
        Play(clockBase);        // 되돌아간 경우엔 처음부터다 -- 어쩔 수 없다
    }

    /// <summary>스페이스바가 부르는 것.  안 틀려 있으면 처음부터 튼다.</summary>
    public void Toggle()
    {
        if (Path == null) return;
        if (IsPlaying) Pause();
        else if (paused) Resume();
        else Play(PositionSeconds >= LengthSeconds - 0.01 ? 0 : PositionSeconds);
    }

    /// <summary>그 자리로 간다.  틀고 있었으면 거기서 이어 튼다.</summary>
    public void Seek(double seconds)
    {
        var target = LengthSeconds > 0 ? Math.Clamp(seconds, 0, LengthSeconds) : Math.Max(0, seconds);
        var wasPlaying = IsPlaying;
        if (open)
        {
            Send($"seek {Alias} to {(int)Math.Round(target * 1000)}");
            clockBase = target;
            paused = !wasPlaying;
            if (wasPlaying) Send($"play {Alias}");
            return;
        }
        clockBase = target;
        clock.Reset();
        paused = !wasPlaying;
        if (wasPlaying) clock.Restart();     // 소리는 못 옮긴다.  선만 맞춘다
    }

    public void Stop()
    {
        paused = false;
        clockBase = 0;
        clock.Reset();
        if (open) Send($"stop {Alias}");
        else fallback?.Stop();
    }

    public void Close()
    {
        if (open) { Send($"close {Alias}"); open = false; }
        try { fallback?.Stop(); fallback?.Dispose(); } catch { /* 이미 끝났으면 그만 */ }
        fallback = null;
        Degraded = false;
        paused = false;
        clock.Reset();
        clockBase = 0;
        LengthSeconds = 0;
        Path = null;
    }

    public void Dispose() => Close();

    // ------------------------------------------------------------------ MCI

    private static int Send(string command) => mciSendString(command, null, 0, IntPtr.Zero);

    private static string Query(string what)
    {
        var buffer = new StringBuilder(128);
        return mciSendString($"status {Alias} {what}", buffer, buffer.Capacity, IntPtr.Zero) == 0
            ? buffer.ToString().Trim()
            : "";
    }

    private static string ErrorText(int code)
    {
        var buffer = new StringBuilder(256);
        return mciGetErrorString(code, buffer, buffer.Capacity)
            ? buffer.ToString().Trim()
            : $"MCI 오류 {code}";
    }
}
