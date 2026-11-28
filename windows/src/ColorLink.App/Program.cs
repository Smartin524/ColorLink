using System.Runtime.InteropServices;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.Windows.AppLifecycle;

namespace ColorLink.App;

/// <summary>
/// 自己写的入口：只留一个实例。第二次启动（比如从资源管理器「发送到」把文件发过来）时，
/// 把命令行转给已经在运行的那个，自己马上退出。
/// </summary>
public static class Program
{
    const string InstanceKey = "ColorLink-Main";

    [STAThread]
    static int Main(string[] args)
    {
        WinRT.ComWrappersSupport.InitializeComWrappers();
        if (RedirectToRunningInstance()) return 0;

        Application.Start(p =>
        {
            var context = new DispatcherQueueSynchronizationContext(DispatcherQueue.GetForCurrentThread());
            SynchronizationContext.SetSynchronizationContext(context);
            _ = new App();
        });
        return 0;
    }

    static bool RedirectToRunningInstance()
    {
        var current = AppInstance.FindOrRegisterForKey(InstanceKey);
        if (current.IsCurrent)
        {
            current.Activated += (_, e) => App.Current?.OnRedirected(e);
            return false;
        }
        var args = AppInstance.GetCurrent().GetActivatedEventArgs();
        // 在别的线程上等转发完成，同时让本线程继续处理 COM 消息，避免 STA 上死等
        var done = CreateEvent(IntPtr.Zero, true, false, null);
        Task.Run(() =>
        {
            try { current.RedirectActivationToAsync(args).AsTask().Wait(); }
            finally { SetEvent(done); }
        });
        CoWaitForMultipleObjects(0 /* CWMO_DEFAULT */, 0xFFFFFFFF, 1, [done], out _);
        CloseHandle(done);
        return true;
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
    static extern IntPtr CreateEvent(IntPtr attributes, bool manualReset, bool initialState, string? name);

    [DllImport("kernel32.dll")]
    static extern bool SetEvent(IntPtr handle);

    [DllImport("kernel32.dll")]
    static extern bool CloseHandle(IntPtr handle);

    [DllImport("ole32.dll")]
    static extern uint CoWaitForMultipleObjects(uint flags, uint timeout, uint count, IntPtr[] handles, out uint index);
}
