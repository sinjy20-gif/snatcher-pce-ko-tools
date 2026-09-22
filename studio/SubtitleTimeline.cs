using System.Drawing.Drawing2D;

namespace SnatcherTranslationStudio;

/// <summary>오디오 길이 위에 자막을 블록으로 놓고 끌어서 싱크를 맞추는 타임라인.</summary>
/// <remarks>
/// 왜 끌 수 있어야 하나
/// --------------------
/// 전에는 start/duration 을 숫자로 쳐서 맞췄다.  자막 수백 개를 그렇게 맞추려면
/// "듣기 -> 숫자 고치기 -> 다시 듣기" 를 매번 도는데, 0.2 초를 당기고 싶을 때
/// 숫자를 얼마로 고쳐야 하는지 귀로는 알 수 없다.  눈으로 보고 끄는 편이 맞다.
///
/// **숫자 입력은 그대로 둔다.**  이것은 대체가 아니라 추가다 -- 정밀하게 박아야
/// 할 때는 여전히 숫자가 빠르고, 이 컨트롤이 쓰는 값과 같은 값이다.
///
/// 바깥과 어떻게 붙나
/// ------------------
///     Spans           블록 목록.  Tag 에 바깥의 행 객체를 담아 두면 그대로 돌려준다
///     SelectedTag     지금 고른 블록.  그리드 선택과 양쪽으로 묶으라고 있는 것
///     SpanDragging    끄는 중에 매 번 뜬다 -- 숫자칸을 실시간으로 갱신하라고
///     SpanDragged     놓았을 때 한 번.  여기서 저장·재정렬 같은 무거운 일을 한다
///     SelectionChanged 블록을 눌렀을 때
///
/// 끄는 중에 바깥이 Spans 를 다시 만들면 잡고 있던 블록이 사라진다.  그래서
/// 끄는 동안에는 Spans 대입을 **무시한다** (IsDragging 이 그 신호다).
/// </remarks>
internal sealed class SubtitleTimeline : Control
{
    internal sealed record Span(double Start, double Duration, string Label, object? Tag = null);

    /// <summary>블록 어디를 잡았나.</summary>
    internal enum Grip { None, Body, Left, Right }

    private const int EdgeGrabPx = 6;      // 양 끝에서 이만큼은 길이 조절로 잡는다
    private const double MinDuration = 0.05;

    private IReadOnlyList<Span> spans = Array.Empty<Span>();
    private int[] lanes = Array.Empty<int>();   // 블록마다 몇 번째 줄에 그릴까
    private int laneCount = 1;

    private Grip grip = Grip.None;
    private int dragIndex = -1;
    private double dragGrabOffset;              // 블록 시작점에서 몇 초 지점을 잡았나
    private double dragStart, dragDuration;     // 끄는 중의 살아 있는 값

    // 끌기를 시작할 때 굳혀 두는 이웃.  끄는 도중에 다시 찾으면 블록이 서로
    // 지나칠 때 이웃이 바뀌어 버린다.
    private int prevIndex = -1, nextIndex = -1;
    private double prevStart, prevDuration, nextStart, nextDuration;

    // 끄는 중의 값.  끌린 블록과 밀려난 이웃이 여기 들어간다.
    private readonly Dictionary<int, (double Start, double Duration)> liveEdits = new();

    // 노란 선(재생 머리)을 잡고 있나.  블록 끌기와는 다른 동작이라 따로 둔다 --
    // 이쪽은 자료를 안 고치고 소리의 자리만 옮긴다.
    private bool headDragging;
    private const int HeadGrabPx = 7;      // 선에서 이만큼 안이면 선을 잡은 것으로 본다

    // 가로 스크롤 막대.  확대했을 때만 나온다 (2026-09-07).
    //
    // 왜 필요한가: 확대해 놓으면 창 밖의 자막으로 갈 방법이 "다른 조각을 골라
    // 창을 다시 맞추는 것" 뿐이었다.  그런데 그러면 **창이 통째로 점프해서**
    // 손으로 맞추던 자리를 잃는다.  막대로 밀면 배율은 그대로 두고 자리만 옮긴다.
    private const int ScrollBarHeight = 15;
    private const double ScrollUnit = 0.01;   // 막대 한 칸 = 10 ms
    private readonly HScrollBar scroller = new() {
        Dock = DockStyle.Bottom, Height = ScrollBarHeight, Visible = false,
    };
    private bool syncingScroller;             // 우리가 맞추는 중이면 되먹임을 막는다

    private double durationSeconds = 1;
    public double DurationSeconds
    {
        get => durationSeconds;
        set { durationSeconds = value; SyncScroller(); }
    }

    public double PositionSeconds { get; set; }
    public object? SelectedTag { get; private set; }
    public bool IsDragging => grip != Grip.None;

    // 0 이면 트랙 전체, 양수면 그 시간 창만 그린다. CD-DA처럼 3분짜리
    // 트랙에 조각이 빽빽할 때 선택 부분을 실제로 확대하기 위한 좌표계다.
    private double viewStartSeconds;
    private double viewDurationSeconds;
    public bool IsZoomed => viewDurationSeconds > 0.001
                            && viewDurationSeconds < Math.Max(0.01, DurationSeconds) - 0.001;
    public double ViewStartSeconds => VisibleRange().Start;
    public double ViewEndSeconds
    {
        get
        {
            var view = VisibleRange();
            return view.Start + view.Duration;
        }
    }

    /// <summary>사람이 직접 창을 옮겼을 때 (막대·휠).  바깥의 확대 폭을 맞추라고.</summary>
    /// <remarks>바깥이 다시 `SetView` 를 부르지는 말 것 -- 되먹임이 된다.</remarks>
    public event Action<double, double>? ViewChanged;

    /// <summary>재생 머리를 끄는 중.  매 움직임마다 뜬다 (소리를 따라 옮기라고).</summary>
    public event Action<double>? Seeking;
    /// <summary>재생 머리를 놓았을 때 한 번.  여기서 실제로 그 자리부터 튼다.</summary>
    public event Action<double>? Seeked;

    /// <summary>한 블록의 새 시각.</summary>
    internal sealed record SpanEdit(object? Tag, double Start, double Duration);

    /// <summary>끄는 중 매 움직임마다.  끌린 블록과 밀려난 이웃이 같이 온다.</summary>
    public event Action<IReadOnlyList<SpanEdit>>? SpanDragging;
    /// <summary>놓았을 때 한 번.  끌린 블록과 밀려난 이웃이 같이 온다.</summary>
    public event Action<IReadOnlyList<SpanEdit>>? SpanDragged;
    /// <summary>블록을 눌러 고른 것이 바뀌었을 때.</summary>
    public event Action<object?>? SelectionChanged;

    public IReadOnlyList<Span> Spans
    {
        get => spans;
        set
        {
            // 끄는 중에 목록이 갈리면 잡고 있던 블록의 인덱스가 어긋난다.
            // 바깥이 우리 값을 되받아 쓰는 중일 뿐이므로 그냥 무시하면 된다.
            if (IsDragging) return;
            spans = value;
            LayoutLanes();
            if (SelectedTag != null && !spans.Any(s => ReferenceEquals(s.Tag, SelectedTag)))
                SelectedTag = null;
            Invalidate();
        }
    }

    public SubtitleTimeline()
    {
        DoubleBuffered = true;
        BackColor = Color.FromArgb(20, 20, 20);
        MinimumSize = new Size(160, 72);
        SetStyle(ControlStyles.Selectable, true);
        scroller.ValueChanged += OnScrollerValue;
        Controls.Add(scroller);
    }

    /// <summary>트랙 중 일부만 화면 폭 전체에 펼친다.</summary>
    public void SetView(double start, double duration)
    {
        var total = Math.Max(0.01, DurationSeconds);
        duration = Math.Clamp(duration, 0.25, total);
        viewStartSeconds = Math.Clamp(start, 0, Math.Max(0, total - duration));
        viewDurationSeconds = duration;
        SyncScroller();
        Invalidate();
    }

    /// <summary>배율은 그대로 두고 창만 옮긴다.  막대·휠이 쓰는 길.</summary>
    public void PanView(double start)
    {
        if (!IsZoomed) return;
        SetView(start, VisibleRange().Duration);
    }

    /// <summary>전체 트랙 보기로 돌아간다.</summary>
    public void ClearView()
    {
        viewStartSeconds = 0;
        viewDurationSeconds = 0;
        SyncScroller();
        Invalidate();
    }

    /// <summary>가로 막대를 트랙 길이와 지금 창에 맞춘다.</summary>
    /// <remarks>
    /// 막대는 정수만 다룬다.  한 칸을 10 ms 로 잘라 쓴다 -- CD-DA 가 3 분이면
    /// 18,000 칸이라 int 로 넉넉하고, 손으로 밀면서 10 ms 보다 잘게 맞출 일은
    /// 없다 (그건 F6/F7 로 찍는다).
    ///
    /// `LargeChange` 가 곧 창 폭이다.  WinForms 는 Value 를
    /// `Maximum - LargeChange + 1` 까지만 받으므로, 이렇게 두면 손잡이 길이가
    /// 저절로 "전체 중 보이는 만큼" 이 된다.  ★대입 순서가 중요하다 --
    /// Maximum 을 먼저 올려야 LargeChange·Value 가 안 잘린다.
    /// </remarks>
    private void SyncScroller()
    {
        var wasVisible = scroller.Visible;
        if (!IsZoomed)
        {
            scroller.Visible = false;
            if (wasVisible) Invalidate();
            return;
        }

        var total = Math.Max(0.01, DurationSeconds);
        var view = VisibleRange();
        var totalUnits = Math.Max(2, (int)Math.Round(total / ScrollUnit));
        var windowUnits = Math.Clamp((int)Math.Round(view.Duration / ScrollUnit), 1, totalUnits);

        syncingScroller = true;
        scroller.Minimum = 0;
        scroller.Maximum = totalUnits - 1;
        scroller.LargeChange = windowUnits;
        scroller.SmallChange = Math.Max(1, windowUnits / 8);
        scroller.Value = Math.Clamp((int)Math.Round(view.Start / ScrollUnit),
                                    0, Math.Max(0, totalUnits - windowUnits));
        syncingScroller = false;

        scroller.Visible = true;
        if (!wasVisible) Invalidate();
    }

    private void OnScrollerValue(object? sender, EventArgs e)
    {
        if (syncingScroller || !IsZoomed) return;
        var view = VisibleRange();
        var total = Math.Max(0.01, DurationSeconds);
        viewStartSeconds = Math.Clamp(scroller.Value * ScrollUnit, 0,
                                      Math.Max(0, total - view.Duration));
        Invalidate();
        ViewChanged?.Invoke(viewStartSeconds, view.Duration);
    }

    private (double Start, double Duration) VisibleRange()
    {
        var total = Math.Max(0.01, DurationSeconds);
        if (viewDurationSeconds <= 0.001 || viewDurationSeconds >= total - 0.001)
            return (0, total);
        var duration = Math.Clamp(viewDurationSeconds, 0.25, total);
        return (Math.Clamp(viewStartSeconds, 0, Math.Max(0, total - duration)), duration);
    }

    /// <summary>바깥(그리드)에서 고른 것을 타임라인에 반영한다.  이벤트는 안 낸다.</summary>
    public void SelectByTag(object? tag)
    {
        if (ReferenceEquals(SelectedTag, tag)) return;
        SelectedTag = tag;
        Invalidate();
    }

    // ---------------------------------------------------------------- 그리기

    // 아래 12 px 은 눈금 글씨 자리다.  막대가 떠 있으면 그만큼 더 비운다 --
    // 안 그러면 막대가 눈금 위에 얹혀 초를 못 읽는다.
    private Rectangle RailArea()
        => new(12, 30, Math.Max(1, ClientSize.Width - 24),
               Math.Max(12, ClientSize.Height - 42 - (scroller.Visible ? ScrollBarHeight : 0)));

    /// <summary>겹치는 블록을 아래 줄로 내린다.  안 그러면 가려진 블록을 잡을 수 없다.</summary>
    private void LayoutLanes()
    {
        lanes = new int[spans.Count];
        var laneEnd = new List<double>();
        // 시작 순서대로 놓아야 줄이 적게 나온다.  원래 인덱스는 지켜야 하므로
        // 순서만 따로 만든다.
        foreach (var index in Enumerable.Range(0, spans.Count).OrderBy(i => spans[i].Start))
        {
            var span = spans[index];
            var lane = 0;
            while (lane < laneEnd.Count && span.Start < laneEnd[lane] - 0.0001) lane++;
            if (lane == laneEnd.Count) laneEnd.Add(0);
            laneEnd[lane] = span.Start + Math.Max(span.Duration, 0);
            lanes[index] = lane;
        }
        laneCount = Math.Max(1, laneEnd.Count);
    }

    private Rectangle BlockRect(int index)
    {
        var area = RailArea();
        var view = VisibleRange();
        var (start, duration) = LiveValues(index);
        var left = area.Left + (int)Math.Round(area.Width * Math.Clamp((start - view.Start) / view.Duration, 0, 1));
        var right = area.Left + (int)Math.Round(area.Width * Math.Clamp((start + duration - view.Start) / view.Duration, 0, 1));
        var laneHeight = Math.Max(10, area.Height / laneCount);
        var top = area.Top + lanes[index] * laneHeight;
        return Rectangle.FromLTRB(left, top + 1, Math.Max(left + 3, right), top + laneHeight - 2);
    }

    private bool SpanIsVisible(int index)
    {
        var view = VisibleRange();
        var (start, duration) = LiveValues(index);
        return start + duration >= view.Start && start <= view.Start + view.Duration;
    }

    /// <summary>끄는 중에 바뀐 블록은 살아 있는 값을, 나머지는 목록 값을 쓴다.</summary>
    private (double Start, double Duration) LiveValues(int index)
        => liveEdits.TryGetValue(index, out var live)
            ? live
            : (spans[index].Start, spans[index].Duration);

    protected override void OnPaint(PaintEventArgs e)
    {
        base.OnPaint(e);
        var g = e.Graphics;
        g.SmoothingMode = SmoothingMode.AntiAlias;
        var area = RailArea();
        var view = VisibleRange();

        using (var rail = new SolidBrush(Color.FromArgb(38, 46, 52)))
            g.FillRectangle(rail, area);

        DrawTicks(g, area, view.Start, view.Duration);

        for (var index = 0; index < spans.Count; index++)
        {
            if (!SpanIsVisible(index)) continue;
            var rect = BlockRect(index);
            var (start, duration) = LiveValues(index);
            var selected = SelectedTag != null && ReferenceEquals(spans[index].Tag, SelectedTag);
            var playing = PositionSeconds >= start && PositionSeconds < start + duration;

            var fill = selected ? Color.FromArgb(255, 168, 60)
                     : playing ? Color.FromArgb(80, 190, 255)
                               : Color.FromArgb(60, 135, 210);
            using (var brush = new SolidBrush(fill)) g.FillRectangle(brush, rect);
            using (var border = new Pen(selected ? Color.White : Color.FromArgb(20, 30, 40)))
                g.DrawRectangle(border, rect);

            // 지금 말하고 있는 블록에는 밑줄을 하나 긋는다.  ★고른 블록이 곧
            // 재생 중인 블록일 때 채움색만으로는 둘을 구분할 수 없다 -- 고른
            // 색이 이기기 때문이다.  **표시만 한다.  아무것도 움직이지 않는다.**
            if (playing)
            {
                using var mark = new Pen(Color.FromArgb(255, 220, 85), 2);
                g.DrawLine(mark, rect.Left + 1, rect.Bottom - 1, rect.Right - 1, rect.Bottom - 1);
            }

            // 잡는 자리를 눈에 보이게 -- 여기가 길이 조절이라는 표시
            if (rect.Width > EdgeGrabPx * 3)
            {
                using var handle = new SolidBrush(Color.FromArgb(selected ? 220 : 120, 255, 255, 255));
                g.FillRectangle(handle, rect.Left + 1, rect.Top + 3, 2, rect.Height - 6);
                g.FillRectangle(handle, rect.Right - 3, rect.Top + 3, 2, rect.Height - 6);
            }

            if (rect.Width > 26)
            {
                var label = spans[index].Label;
                TextRenderer.DrawText(g, label, Font,
                    Rectangle.Inflate(rect, -EdgeGrabPx, 0),
                    selected ? Color.Black : Color.White,
                    TextFormatFlags.VerticalCenter | TextFormatFlags.Left | TextFormatFlags.EndEllipsis);
            }
        }

        var headVisible = PositionSeconds >= view.Start - 0.0001
                          && PositionSeconds <= view.Start + view.Duration + 0.0001;
        if (headVisible)
        {
            var head = area.Left + (int)Math.Round(area.Width *
                Math.Clamp((PositionSeconds - view.Start) / view.Duration, 0, 1));
            var headColor = headDragging ? Color.FromArgb(255, 245, 160) : Color.FromArgb(255, 220, 85);
            using (var pen = new Pen(headColor, 2))
                g.DrawLine(pen, head, area.Top - 8, head, area.Bottom + 4);
            // 손잡이. 잡을 수 있는 것이라는 표시가 없으면 아무도 안 잡는다.
            using (var knob = new SolidBrush(headColor))
                g.FillPolygon(knob, new[] {
                    new Point(head - 6, area.Top - 10), new Point(head + 6, area.Top - 10),
                    new Point(head, area.Top - 1) });
        }

        var caption = IsDragging && dragIndex >= 0
            ? $"{spans[dragIndex].Label}   {dragStart:0.000} → {dragStart + dragDuration:0.000}s  (길이 {dragDuration:0.000})"
            : headDragging
            ? $"{PositionSeconds:0.000}s  ← 놓으면 여기서부터 튼다"
            : IsZoomed
            ? $"{PositionSeconds:0.000}s / {DurationSeconds:0.000}s{PlayingCaption()}     확대 {view.Start:0.0}–{view.Start + view.Duration:0.0}s · 아래 막대로 좌우 이동 (휠 = 이동 · Ctrl+휠 = 배율)"
            : $"{PositionSeconds:0.000}s / {DurationSeconds:0.000}s{PlayingCaption()}     F5 재생·정지 · 노란 선을 끌어 그 자리로 · 블록을 끌어 싱크";
        TextRenderer.DrawText(g, caption, Font, new Point(12, 6),
            IsDragging ? Color.FromArgb(255, 210, 120) : Color.Gainsboro);
    }

    /// <summary>지금 말하고 있는 자막을 글로 적는다.  **보여주기만 한다.**</summary>
    /// <remarks>
    /// 2026-09-07: 전에는 재생이 자막을 지날 때마다 바깥이 그 행을 골라 창을
    /// 다시 맞췄다.  그러면 싱크를 맞추던 손에서 화면이 통째로 빠져나간다.
    /// 이제 움직이는 대신 여기 적기만 한다 -- 어디를 지나는지는 알 수 있고,
    /// 고른 것도 창도 그대로 있다.
    /// </remarks>
    private string PlayingCaption()
    {
        for (var index = 0; index < spans.Count; index++)
        {
            var (start, duration) = LiveValues(index);
            if (PositionSeconds >= start && PositionSeconds < start + duration)
                return "   ♪ " + spans[index].Label;
        }
        return "";
    }

    private void DrawTicks(Graphics g, Rectangle area, double viewStart, double viewDuration)
    {
        // 눈금 간격은 폭에 맞춰 고른다.  1초 눈금이 3px 이 되면 읽을 수 없다.
        double[] steps = { 0.5, 1, 2, 5, 10, 15, 30, 60 };
        var step = steps.FirstOrDefault(s => area.Width * s / viewDuration >= 48, 60.0);
        using var pen = new Pen(Color.FromArgb(70, 82, 92));
        var first = Math.Ceiling(viewStart / step) * step;
        for (var t = first; t <= viewStart + viewDuration + 1e-6; t += step)
        {
            var x = area.Left + (int)Math.Round(area.Width * Math.Clamp((t - viewStart) / viewDuration, 0, 1));
            g.DrawLine(pen, x, area.Top, x, area.Bottom);
            TextRenderer.DrawText(g, $"{t:0.#}s", Font, new Point(x + 2, area.Bottom + 1),
                Color.FromArgb(120, 132, 142));
        }
    }

    // ------------------------------------------------------------- 마우스

    private double SecondsAt(int x)
    {
        var area = RailArea();
        var view = VisibleRange();
        return Math.Clamp(view.Start + (x - area.Left) / (double)Math.Max(1, area.Width) * view.Duration,
                          view.Start, view.Start + view.Duration);
    }

    /// <summary>재생 머리가 지금 몇 픽셀에 서 있나.</summary>
    private int HeadX()
    {
        var area = RailArea();
        var view = VisibleRange();
        return area.Left + (int)Math.Round(area.Width *
            Math.Clamp((PositionSeconds - view.Start) / view.Duration, 0, 1));
    }

    private bool HeadIsVisible()
    {
        var view = VisibleRange();
        return PositionSeconds >= view.Start - 0.0001
               && PositionSeconds <= view.Start + view.Duration + 0.0001;
    }

    private void BeginHeadDrag(int x)
    {
        headDragging = true;
        PositionSeconds = SecondsAt(x);
        Capture = true;
        Cursor = Cursors.SizeWE;
        Seeking?.Invoke(PositionSeconds);
        Invalidate();
    }

    /// <summary>점 아래의 블록과 잡은 자리.  위에 그려진 것부터 본다.</summary>
    private (int Index, Grip Grip) HitTest(Point point)
    {
        for (var index = spans.Count - 1; index >= 0; index--)
        {
            var rect = BlockRect(index);
            if (!rect.Contains(point)) continue;
            if (point.X - rect.Left <= EdgeGrabPx && rect.Width > EdgeGrabPx * 2) return (index, Grip.Left);
            if (rect.Right - point.X <= EdgeGrabPx && rect.Width > EdgeGrabPx * 2) return (index, Grip.Right);
            return (index, Grip.Body);
        }
        return (-1, Grip.None);
    }

    /// <summary>시간 순서에서 이 블록의 앞/뒤 이웃을 찾는다.</summary>
    /// <remarks>
    /// part 순서가 아니라 **시간 순서**로 본다.  눈에 보이는 이웃이 곧 겹칠 수
    /// 있는 상대이고, 자료가 어긋나 있으면 part 순서와 시간 순서가 다르다.
    /// </remarks>
    private (int Prev, int Next) NeighboursOf(int index)
    {
        var self = spans[index].Start;
        int prev = -1, next = -1;
        double prevBest = double.NegativeInfinity, nextBest = double.PositiveInfinity;
        for (var i = 0; i < spans.Count; i++)
        {
            if (i == index) continue;
            var start = spans[i].Start;
            if (start <= self && start > prevBest) { prevBest = start; prev = i; }
            if (start > self && start < nextBest) { nextBest = start; next = i; }
        }
        return (prev, next);
    }

    protected override void OnMouseDown(MouseEventArgs e)
    {
        base.OnMouseDown(e);
        if (e.Button != MouseButtons.Left) return;
        Focus();

        // 재생 머리를 먼저 본다.  블록 위에 겹쳐 있어도 선을 잡을 수 있어야 한다 --
        // CD-DA 는 3 분이 넘어서, 한 번 틀면 손으로 되감을 방법이 이것뿐이다.
        if ((HeadIsVisible() && Math.Abs(e.X - HeadX()) <= HeadGrabPx) || e.Y < RailArea().Top)
        {
            BeginHeadDrag(e.X);
            return;
        }

        var (index, hit) = HitTest(e.Location);
        if (index < 0)
        {
            // 빈 곳을 누르면 재생 위치만 옮긴다 -- 선택은 건드리지 않는다.
            // 누른 채로 끌면 그대로 훑기가 된다.
            BeginHeadDrag(e.X);
            return;
        }

        if (!ReferenceEquals(SelectedTag, spans[index].Tag))
        {
            SelectedTag = spans[index].Tag;
            SelectionChanged?.Invoke(SelectedTag);
        }

        grip = hit;
        dragIndex = index;
        dragStart = spans[index].Start;
        dragDuration = spans[index].Duration;
        dragGrabOffset = SecondsAt(e.X) - dragStart;

        // 이웃은 여기서 한 번만 정한다.  끄는 도중에 다시 찾으면 블록이 서로
        // 지나칠 때 이웃이 바뀌어 엉뚱한 블록이 밀린다.
        (prevIndex, nextIndex) = NeighboursOf(index);
        if (prevIndex >= 0) { prevStart = spans[prevIndex].Start; prevDuration = spans[prevIndex].Duration; }
        if (nextIndex >= 0) { nextStart = spans[nextIndex].Start; nextDuration = spans[nextIndex].Duration; }

        liveEdits.Clear();
        Capture = true;
        Invalidate();
    }

    /// <summary>끌린 블록의 새 시각에서 이웃까지 정리한다.</summary>
    /// <remarks>
    /// 규칙은 둘이다.
    ///
    ///     겹치지 않는다   자막 두 개가 동시에 뜨면 안 된다.  밀고 들어가면
    ///                     이웃이 **줄어든다** (끝이 물러나거나 시작이 밀린다)
    ///     틈은 허용한다   물러날 때 이웃을 늘려 채우지는 않는다.  말이 없는
    ///                     구간은 화면도 비는 것이 맞다
    ///
    /// 이웃은 `MinDuration` 아래로는 안 줄인다.  더 밀면 이웃이 아니라 **끌고
    /// 있는 블록이 막힌다** -- 한 번 잘못 끌어서 이웃이 사라지면 되돌릴 방법이
    /// 없기 때문이다.  거기까지 옮기려면 숫자 칸을 쓰면 된다.
    ///
    /// 미는 것은 **바로 옆 하나까지**다.  연쇄로 밀면 한 번의 드래그가 앞쪽
    /// 자막을 줄줄이 뭉갤 수 있다.
    /// </remarks>
    /// <summary>한 이웃의 정리 결과.  안 바뀌면 null 이다.</summary>
    internal readonly record struct Adjust(double Start, double Duration);

    /// <summary>끌린 블록과 이웃의 새 시각을 계산한다.  순수 함수 -- 시험할 수 있게.</summary>
    /// <remarks>
    /// `prev`/`next` 는 끌기를 시작할 때의 이웃 값이고, null 이면 이웃이 없다.
    /// 돌려주는 것은 (끌린 블록, 앞 이웃, 뒤 이웃) 이며 이웃 쪽은 바뀔 때만 값이 있다.
    /// </remarks>
    internal static (Adjust Drag, Adjust? Prev, Adjust? Next) Resolve(
        Grip grip, double start, double duration, double total,
        Adjust? prev, Adjust? next)
    {
        // 1) 이웃이 최소 길이를 지키는 선까지만 막는다.  그 전에는 끌린 블록이
        //    우선이다 -- 막는 것이 아니라 이웃이 줄어든다.
        var lowLimit = prev.HasValue ? prev.Value.Start + MinDuration : 0;
        var highLimit = next.HasValue ? next.Value.Start + next.Value.Duration - MinDuration : total;

        switch (grip)
        {
            case Grip.Body:
                start = Math.Clamp(start, lowLimit, Math.Max(lowLimit, highLimit - duration));
                break;
            case Grip.Left:
            {
                var end = start + duration;
                start = Math.Clamp(start, lowLimit, end - MinDuration);
                duration = end - start;
                break;
            }
            case Grip.Right:
                duration = Math.Clamp(duration, MinDuration, Math.Max(MinDuration, highLimit - start));
                break;
        }

        // 2) 앞 이웃: 우리 시작을 넘어 끝나고 있으면 끝을 물린다 (줄어든다).
        //    물러날 때 늘려서 채우지는 않는다 -- 틈은 허용한다.
        Adjust? prevOut = null;
        if (prev.HasValue && prev.Value.Start + prev.Value.Duration > start + 1e-9)
            prevOut = new Adjust(prev.Value.Start, Math.Max(MinDuration, start - prev.Value.Start));

        // 3) 뒤 이웃: 우리 끝보다 먼저 시작하면 시작을 밀어낸다.  끝은 그대로
        //    두므로 길이가 줄어든다.
        Adjust? nextOut = null;
        var dragEnd = start + duration;
        if (next.HasValue && next.Value.Start < dragEnd - 1e-9)
        {
            var end = next.Value.Start + next.Value.Duration;
            nextOut = new Adjust(dragEnd, Math.Max(MinDuration, end - dragEnd));
        }

        return (new Adjust(start, duration), prevOut, nextOut);
    }

    private void ResolveDrag()
    {
        var prev = prevIndex >= 0 ? new Adjust(prevStart, prevDuration) : (Adjust?)null;
        var next = nextIndex >= 0 ? new Adjust(nextStart, nextDuration) : (Adjust?)null;
        var (drag, prevOut, nextOut) =
            Resolve(grip, dragStart, dragDuration, Math.Max(0.01, DurationSeconds), prev, next);

        dragStart = drag.Start;
        dragDuration = drag.Duration;

        liveEdits.Clear();
        liveEdits[dragIndex] = (drag.Start, drag.Duration);
        if (prevOut.HasValue) liveEdits[prevIndex] = (prevOut.Value.Start, prevOut.Value.Duration);
        if (nextOut.HasValue) liveEdits[nextIndex] = (nextOut.Value.Start, nextOut.Value.Duration);
    }

    private IReadOnlyList<SpanEdit> CurrentEdits()
        => liveEdits.Select(kv => new SpanEdit(spans[kv.Key].Tag, kv.Value.Start, kv.Value.Duration)).ToList();

    protected override void OnMouseMove(MouseEventArgs e)
    {
        base.OnMouseMove(e);
        if (headDragging)
        {
            PositionSeconds = SecondsAt(e.X);
            Seeking?.Invoke(PositionSeconds);
            Invalidate();
            return;
        }
        if (!IsDragging)
        {
            // 선 근처면 블록보다 먼저 "잡을 수 있다" 고 알린다
            if ((HeadIsVisible() && Math.Abs(e.X - HeadX()) <= HeadGrabPx) || e.Y < RailArea().Top)
            {
                Cursor = Cursors.SizeWE;
                return;
            }
            var (_, hover) = HitTest(e.Location);
            Cursor = hover switch
            {
                Grip.Left or Grip.Right => Cursors.SizeWE,
                Grip.Body => Cursors.SizeAll,
                _ => Cursors.Default,
            };
            return;
        }

        var total = Math.Max(0.01, DurationSeconds);
        var at = SecondsAt(e.X);
        switch (grip)
        {
            case Grip.Body:
                // 길이는 그대로 두고 통째로 옮긴다.  끝이 밖으로 나가지 않게 막는다.
                dragStart = Math.Clamp(at - dragGrabOffset, 0, Math.Max(0, total - dragDuration));
                break;
            case Grip.Left:
            {
                var end = dragStart + dragDuration;
                dragStart = Math.Clamp(at, 0, end - MinDuration);
                dragDuration = end - dragStart;
                break;
            }
            case Grip.Right:
                dragDuration = Math.Clamp(at - dragStart, MinDuration, total - dragStart);
                break;
        }

        ResolveDrag();
        SpanDragging?.Invoke(CurrentEdits());
        Invalidate();
    }

    protected override void OnMouseUp(MouseEventArgs e)
    {
        base.OnMouseUp(e);
        if (headDragging)
        {
            headDragging = false;
            Capture = false;
            Cursor = Cursors.Default;
            // 놓았을 때 한 번만 실제로 소리를 옮긴다.  끄는 내내 옮기면 MCI 가
            // 초당 스무 번 seek 를 맞아 툭툭 끊긴다.
            Seeked?.Invoke(PositionSeconds);
            Invalidate();
            return;
        }
        if (!IsDragging) return;
        var edits = CurrentEdits();
        grip = Grip.None;
        dragIndex = -1;
        prevIndex = nextIndex = -1;
        liveEdits.Clear();
        Capture = false;
        Cursor = Cursors.Default;
        // 놓은 뒤에 부른다 -- 바깥이 여기서 Spans 를 다시 만들 것이고,
        // IsDragging 이 이미 false 라야 그 대입이 먹는다.
        SpanDragged?.Invoke(edits);
        Invalidate();
    }

    /// <summary>휠은 좌우 이동, Ctrl+휠은 배율.  확대했을 때만 듣는다.</summary>
    /// <remarks>
    /// ⚠ WinForms 는 휠을 **초점이 있는 컨트롤**에 보낸다.  타임라인을 한 번
    /// 누른 뒤부터 듣는다는 뜻이다.  마우스를 얹기만 해도 초점을 뺏게 만들면
    /// 옆 목록에서 타자를 치던 중에 글자가 날아간다 -- 그래서 그렇게 안 한다.
    /// 누르지 않고 옮기려면 아래 막대를 쓰면 된다 (그쪽은 초점과 무관하다).
    /// </remarks>
    protected override void OnMouseWheel(MouseEventArgs e)
    {
        base.OnMouseWheel(e);
        if (!IsZoomed) return;
        var view = VisibleRange();
        if (ModifierKeys.HasFlag(Keys.Control))
        {
            // 커서가 가리키는 시각을 붙잡은 채로 창을 넓히거나 좁힌다.
            var anchor = SecondsAt(e.X);
            var ratio = view.Duration <= 0 ? 0.5 : (anchor - view.Start) / view.Duration;
            var duration = Math.Clamp(view.Duration * (e.Delta > 0 ? 0.8 : 1.25),
                                      0.25, Math.Max(0.25, DurationSeconds));
            SetView(anchor - duration * ratio, duration);
        }
        else
        {
            // 한 번에 창의 1/6 씩.  더 크게 밀면 보던 자리를 놓친다.
            PanView(view.Start + view.Duration / 6.0 * (e.Delta > 0 ? -1 : 1));
        }
        var now = VisibleRange();
        ViewChanged?.Invoke(now.Start, now.Duration);
    }

    protected override void OnResize(EventArgs e)
    {
        base.OnResize(e);
        SyncScroller();
        Invalidate();
    }
}
