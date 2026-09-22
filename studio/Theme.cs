using System.Runtime.InteropServices;

namespace SnatcherTranslationStudio;

/// <summary>
/// Dark palette and the one place that knows how to paint a WinForms control.
///
/// WinForms has no theming, so every surface is coloured explicitly.  Controls
/// are created as field initialisers all over MainForm; rather than colour each
/// one at its declaration, <see cref="Apply"/> walks the finished tree once at
/// the end of the constructor.  Anything added later just needs another Apply
/// call on its parent.
/// </summary>
internal static class Theme
{
    // Surfaces, back to front.
    internal static readonly Color Background = Color.FromArgb(0x1E, 0x1E, 0x1E);
    internal static readonly Color Surface = Color.FromArgb(0x25, 0x25, 0x26);
    internal static readonly Color SurfaceAlt = Color.FromArgb(0x2D, 0x2D, 0x30);
    internal static readonly Color Input = Color.FromArgb(0x1B, 0x1B, 0x1C);
    internal static readonly Color Border = Color.FromArgb(0x3F, 0x3F, 0x46);

    // Text.
    internal static readonly Color Text = Color.FromArgb(0xE4, 0xE4, 0xE4);
    internal static readonly Color TextMuted = Color.FromArgb(0x9A, 0x9A, 0x9A);
    internal static readonly Color TextOnAccent = Color.White;

    // Accent and selection.
    internal static readonly Color Accent = Color.FromArgb(0x2D, 0x7F, 0xF9);
    internal static readonly Color AccentHover = Color.FromArgb(0x46, 0x8F, 0xFA);
    internal static readonly Color Selection = Color.FromArgb(0x09, 0x47, 0x71);

    // Status text.  Light enough to read on Background, not neon.
    internal static readonly Color Good = Color.FromArgb(0x4E, 0xC9, 0x6A);
    internal static readonly Color Bad = Color.FromArgb(0xF1, 0x70, 0x7B);

    // Row tints.  These replace the light-theme pastels (MistyRose, Honeydew,
    // PaleGreen, PeachPuff, Thistle, LightSteelBlue).  They are dark enough that
    // the grid's light ForeColor still reads on top, so callers only ever set
    // BackColor and let the foreground inherit.
    internal static readonly Color RowDefault = Input;
    internal static readonly Color RowOverLimit = Color.FromArgb(0x4A, 0x23, 0x27);   // was MistyRose
    internal static readonly Color RowComplete = Color.FromArgb(0x1F, 0x3A, 0x2A);    // was Honeydew
    internal static readonly Color RowNew = Color.FromArgb(0x23, 0x40, 0x2E);         // was PaleGreen
    internal static readonly Color RowLookupFail = Color.FromArgb(0x4A, 0x3A, 0x20);  // was PeachPuff
    internal static readonly Color RowRouteFail = Color.FromArgb(0x3A, 0x2B, 0x4A);   // was Thistle
    internal static readonly Color RowMasterOnly = Color.FromArgb(0x24, 0x38, 0x4F);  // was LightSteelBlue
    internal static readonly Color RowConflict = Color.FromArgb(0x4A, 0x44, 0x1E);    // was LemonChiffon
    internal static readonly Color RowNeedsReview = Color.FromArgb(0x1E, 0x3D, 0x44); // was LightCyan

    // Selection tints for rows that already carry a status colour.
    internal static readonly Color SelectOverLimit = Color.FromArgb(0x7A, 0x2F, 0x37);
    internal static readonly Color SelectActive = Color.FromArgb(0x1B, 0x6B, 0x3A);

    [DllImport("dwmapi.dll")]
    private static extern int DwmSetWindowAttribute(IntPtr hwnd, int attribute, ref int value, int size);
    private const int DwmwaUseImmersiveDarkMode = 20;

    [DllImport("uxtheme.dll", CharSet = CharSet.Unicode)]
    private static extern int SetWindowTheme(IntPtr hwnd, string? subAppName, string? subIdList);

    // Undocumented, but the only way to make DarkMode_Explorer take effect for a
    // Win32 app.  Ordinal 135 exists from Windows 10 1809; on anything older the
    // P/Invoke throws and the scroll bars simply stay light.
    [DllImport("uxtheme.dll", EntryPoint = "#135", CharSet = CharSet.Unicode)]
    private static extern int SetPreferredAppMode(int mode);
    private const int PreferredAppModeForceDark = 2;
    private static bool darkModeRequested;

    /// <summary>
    /// Scroll bars are drawn by the OS, not by WinForms, so BackColor never
    /// reaches them -- a dark grid still shows a bright white scroll bar down
    /// its edge.  Opting the control into the shell's dark theme is what paints
    /// them.  The handle has to exist first, so late-created controls are hooked
    /// rather than skipped.
    /// </summary>
    private static void UseDarkScrollBars(Control control)
    {
        if (!darkModeRequested)
        {
            darkModeRequested = true;
            try { SetPreferredAppMode(PreferredAppModeForceDark); }
            catch (EntryPointNotFoundException) { }
            catch (DllNotFoundException) { }
        }

        ThemeWindow(control);

        // A DataGridView's scroll bars are separate child windows, so theming
        // the grid itself never reaches them.  They are also created lazily --
        // a grid with no rows yet has none -- so newcomers are caught too.
        foreach (Control child in control.Controls) ThemeWindow(child);
        control.ControlAdded += (_, e) => ThemeWindow(e.Control);
    }

    private static void ThemeWindow(Control control)
    {
        if (control.IsHandleCreated) Send(control);
        else control.HandleCreated += (_, _) => Send(control);

        static void Send(Control target)
        {
            try { SetWindowTheme(target.Handle, "DarkMode_Explorer", null); }
            catch (EntryPointNotFoundException) { }
            catch (DllNotFoundException) { }
        }
    }

    /// <summary>
    /// WinForms controls stop at the client area -- the OS still paints the title
    /// bar and its buttons, which stays light-grey unless the app opts in via
    /// this DWM attribute (Windows 10 1809+/11). No-op on older builds.
    /// </summary>
    internal static void ApplyDarkTitleBar(IntPtr handle)
    {
        var enabled = 1;
        DwmSetWindowAttribute(handle, DwmwaUseImmersiveDarkMode, ref enabled, sizeof(int));
    }

    /// <summary>Paint a control and everything under it.</summary>
    internal static void Apply(Control control)
    {
        switch (control)
        {
            case Form form:
                form.BackColor = Background;
                form.ForeColor = Text;
                break;

            case DataGridView grid:
                StyleGrid(grid);
                UseDarkScrollBars(grid);
                break;

            case TabControl tabs:
                StyleTabs(tabs);
                break;

            case TabPage page:
                page.BackColor = Background;
                page.ForeColor = Text;
                break;

            case Button button:
                StyleButton(button);
                break;

            case TextBox textBox:
                // A read-only box is a display surface, not an input.
                textBox.BackColor = textBox.ReadOnly ? SurfaceAlt : Input;
                textBox.ForeColor = Text;
                textBox.BorderStyle = BorderStyle.FixedSingle;
                if (textBox.Multiline) UseDarkScrollBars(textBox);
                break;

            case ComboBox combo:
                combo.BackColor = Input;
                combo.ForeColor = Text;
                combo.FlatStyle = FlatStyle.Flat;
                break;

            case ListBox list:
                list.BackColor = Input;
                list.ForeColor = Text;
                list.BorderStyle = BorderStyle.FixedSingle;
                UseDarkScrollBars(list);
                break;

            case CheckBox or RadioButton:
                control.BackColor = Color.Transparent;
                control.ForeColor = Text;
                break;

            case Label label:
                label.BackColor = Color.Transparent;
                // Leave a colour the caller set deliberately (metric warnings).
                if (label.ForeColor == SystemColors.ControlText) label.ForeColor = Text;
                break;

            case GroupBox group:
                group.BackColor = Background;
                group.ForeColor = TextMuted;
                break;

            case SplitContainer split:
                split.BackColor = Border;
                split.Panel1.BackColor = Background;
                split.Panel2.BackColor = Background;
                break;

            case FlowLayoutPanel or Panel or TableLayoutPanel:
                // Toolbars read as a raised strip; plain panels stay flush.
                control.BackColor = control.Dock == DockStyle.Top ? Surface : Background;
                control.ForeColor = Text;
                break;

            // Reached when the recursion walks into a grid's own scroll bars.
            // BackColor does nothing to a native scroll bar; the shell theme is
            // the only thing that paints it.
            case ScrollBar scrollBar:
                UseDarkScrollBars(scrollBar);
                break;

            default:
                control.BackColor = Background;
                control.ForeColor = Text;
                break;
        }

        foreach (Control child in control.Controls) Apply(child);
    }

    private static void StyleButton(Button button)
    {
        button.FlatStyle = FlatStyle.Flat;
        button.BackColor = SurfaceAlt;
        button.ForeColor = Text;
        button.FlatAppearance.BorderColor = Border;
        button.FlatAppearance.MouseOverBackColor = Color.FromArgb(0x3A, 0x3A, 0x3E);
        button.FlatAppearance.MouseDownBackColor = Color.FromArgb(0x45, 0x45, 0x4A);
        button.Padding = new Padding(8, 3, 8, 3);
        button.UseVisualStyleBackColor = false;
    }

    /// <summary>Mark the one button on a toolbar that performs the main action.</summary>
    internal static Button AsPrimary(Button button)
    {
        button.BackColor = Accent;
        button.ForeColor = TextOnAccent;
        button.FlatAppearance.BorderColor = Accent;
        button.FlatAppearance.MouseOverBackColor = AccentHover;
        button.FlatAppearance.MouseDownBackColor = Accent;
        return button;
    }

    private static void StyleGrid(DataGridView grid)
    {
        grid.EnableHeadersVisualStyles = false;
        grid.BackgroundColor = Input;
        grid.ForeColor = Text;
        grid.GridColor = Border;
        grid.BorderStyle = BorderStyle.None;
        grid.CellBorderStyle = DataGridViewCellBorderStyle.SingleHorizontal;

        grid.ColumnHeadersDefaultCellStyle.BackColor = SurfaceAlt;
        grid.ColumnHeadersDefaultCellStyle.ForeColor = Text;
        grid.ColumnHeadersDefaultCellStyle.SelectionBackColor = SurfaceAlt;
        grid.ColumnHeadersDefaultCellStyle.SelectionForeColor = Text;
        grid.ColumnHeadersBorderStyle = DataGridViewHeaderBorderStyle.Single;
        grid.ColumnHeadersHeight = 30;

        grid.DefaultCellStyle.BackColor = Input;
        grid.DefaultCellStyle.ForeColor = Text;
        grid.DefaultCellStyle.SelectionBackColor = Selection;
        grid.DefaultCellStyle.SelectionForeColor = Color.White;
        grid.DefaultCellStyle.Padding = new Padding(4, 0, 4, 0);

        grid.AlternatingRowsDefaultCellStyle.BackColor = Color.FromArgb(0x21, 0x21, 0x22);
        grid.RowsDefaultCellStyle.BackColor = Input;
    }

    /// <summary>
    /// TabControl ignores BackColor, so the strip is owner drawn.  Without this
    /// the tab row stays light grey above a dark page and looks broken.
    /// </summary>
    private static void StyleTabs(TabControl tabs)
    {
        tabs.DrawMode = TabDrawMode.OwnerDrawFixed;
        tabs.SizeMode = TabSizeMode.Normal;
        tabs.ItemSize = new Size(150, 30);
        tabs.Padding = new Point(14, 4);
        tabs.BackColor = Background;
        tabs.ForeColor = Text;

        tabs.DrawItem -= PaintTab;
        tabs.DrawItem += PaintTab;

        // DrawItem only covers the tab bodies.  The strip to the right of the
        // last tab is painted by the control itself in the system colour, which
        // is white -- an earlier comment assumed the form showed through there,
        // and it does not.  Paint it before the items draw over it.
        tabs.Paint -= PaintTabStrip;
        tabs.Paint += PaintTabStrip;
    }

    private static void PaintTabStrip(object? sender, PaintEventArgs e)
    {
        if (sender is not TabControl tabs) return;
        var stripHeight = tabs.ItemSize.Height + 4;
        using var back = new SolidBrush(Background);
        e.Graphics.FillRectangle(back, 0, 0, tabs.Width, stripHeight);

        // Repaint the tabs themselves: filling the strip erases whatever
        // DrawItem already put there when Paint runs after it.
        for (var index = 0; index < tabs.TabPages.Count; index++)
        {
            var bounds = tabs.GetTabRect(index);
            DrawTab(e.Graphics, tabs, index, bounds);
        }
    }

    private static void PaintTab(object? sender, DrawItemEventArgs e)
    {
        if (sender is not TabControl tabs || e.Index < 0 || e.Index >= tabs.TabPages.Count) return;
        DrawTab(e.Graphics, tabs, e.Index, e.Bounds);
    }

    private static void DrawTab(Graphics graphics, TabControl tabs, int index, Rectangle bounds)
    {
        var selected = tabs.SelectedIndex == index;
        using (var back = new SolidBrush(selected ? Background : Surface))
            graphics.FillRectangle(back, bounds);

        if (selected)
        {
            // A 2px accent underline is the whole "which tab am I on" signal
            // once the strip and the page share one background colour.
            using var accent = new SolidBrush(Accent);
            graphics.FillRectangle(accent, bounds.Left, bounds.Bottom - 2, bounds.Width, 2);
        }
        else
        {
            using var edge = new Pen(Border);
            graphics.DrawLine(edge, bounds.Right - 1, bounds.Top + 6, bounds.Right - 1, bounds.Bottom - 6);
        }

        TextRenderer.DrawText(
            graphics,
            tabs.TabPages[index].Text,
            tabs.Font,
            bounds,
            selected ? Text : TextMuted,
            TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.EndEllipsis);
    }
}
