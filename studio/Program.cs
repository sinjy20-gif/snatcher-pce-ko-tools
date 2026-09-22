using System.Text;

namespace SnatcherTranslationStudio;

internal static class Program
{
    [STAThread]
    private static void Main()
    {
        Encoding.RegisterProvider(CodePagesEncodingProvider.Instance);
        ApplicationConfiguration.Initialize();
        using var mainForm = new MainForm();
        Application.Run(mainForm);
        Application.ExitThread();
        // FileSystemWatcher/WinForms callbacks can occasionally keep the
        // single-file portable process alive after its last window closes.
        // The form has already prompted for unsaved work and disposed all
        // background services at this point, so terminate the process cleanly.
        Environment.Exit(0);
    }
}
