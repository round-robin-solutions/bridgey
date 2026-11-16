using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using static Bridgey.Platform.Win32;

namespace Bridgey.Platform;

/// <summary>
/// Bridgey's icon in the notification area and its menu, on a hidden window of the UI thread. The same window takes
/// commands from a second launch (WM_COPYDATA): <c>--show</c>, <c>--tray-menu</c>, <c>--pair</c>, <c>--quit</c>.
/// </summary>
internal sealed unsafe class TrayIcon : IDisposable
{
    public const string CommandShow = "show";
    public const string CommandMenu = "tray-menu";
    public const string CommandPair = "pair";
    public const string CommandQuit = "quit";

    private const uint CallbackMessage = WM_APP + 1;
    private const uint IconId = 1;
    private const int MenuOpen = 1, MenuAllow = 2, MenuPair = 3, MenuSettings = 4, MenuQuit = 9, MenuSendFirst = 100;

    public static string ClassName => "BridgeyByRoundRobin." + Paths.ProfileTag;

    private static TrayIcon? _current;
    private readonly nint _hwnd;
    private readonly nint _icon;
    private readonly uint _taskbarCreated;
    private readonly ITrayHost _host;
    private string _tip = Edition.DisplayName;
    private bool _added;

    public interface ITrayHost
    {
        IReadOnlyList<(string Id, string Name)> ClipboardTargets();
        void Open();
        void Pair();
        void Settings();
        void AllowPairing();
        void SendClipboard(string deviceId);
        void Quit();
        void Command(string command);
    }

    public TrayIcon(ITrayHost host)
    {
        _host = host;
        var instance = GetModuleHandle(null);
        fixed (char* cls = ClassName)
        {
            var wc = new WNDCLASSEXW
            {
                cbSize = (uint)sizeof(WNDCLASSEXW),
                lpfnWndProc = &WndProc,
                hInstance = instance,
                lpszClassName = cls,
            };
            RegisterClassEx(&wc);
            fixed (char* title = Edition.DisplayName)
                _hwnd = CreateWindowEx(WS_EX_TOOLWINDOW, cls, title, WS_POPUP, 0, 0, 0, 0, 0, 0, instance, 0);
        }
        fixed (char* name = "TaskbarCreated") _taskbarCreated = RegisterWindowMessage(name);
        fixed (char* path = Paths.Asset("Bridgey.ico")) _icon = LoadImage(0, path, IMAGE_ICON, 0, 0, LR_LOADFROMFILE);
        _current = this;
        Add();
    }

    public nint Handle => _hwnd;

    private NOTIFYICONDATAW Data(uint flags)
    {
        var data = new NOTIFYICONDATAW { cbSize = (uint)sizeof(NOTIFYICONDATAW), hWnd = _hwnd, uID = IconId, uFlags = flags, uCallbackMessage = CallbackMessage, hIcon = _icon };
        var tip = _tip.Length > 127 ? _tip[..127] : _tip;
        for (var i = 0; i < tip.Length; i++) data.szTip[i] = tip[i];
        return data;
    }

    private void Add()
    {
        var data = Data(NIF_MESSAGE | NIF_ICON | NIF_TIP | NIF_SHOWTIP);
        _added = Shell_NotifyIcon(NIM_ADD, &data);
    }

    /// <summary>The tooltip: "Bridgey: Connected to Pixel 9".</summary>
    public void SetTooltip(string status)
    {
        _tip = $"Bridgey: {status}";
        if (!_added) return;
        var data = Data(NIF_TIP | NIF_SHOWTIP);
        Shell_NotifyIcon(NIM_MODIFY, &data);
    }

    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvStdcall)])]
    private static nint WndProc(nint hwnd, uint msg, nint wParam, nint lParam)
    {
        try
        {
            if (_current is { } tray && tray._hwnd == hwnd && tray.Handle(msg, wParam, lParam, out var result)) return result;
        }
        catch (Exception e)
        {
            System.Diagnostics.Debug.WriteLine($"Bridgey tray: {e}");
        }
        return DefWindowProc(hwnd, msg, wParam, lParam);
    }

    private bool Handle(uint msg, nint wParam, nint lParam, out nint result)
    {
        result = 0;
        if (msg == CallbackMessage)
        {
            switch ((uint)(lParam & 0xFFFF))
            {
                case WM_LBUTTONUP:
                    _host.Open();
                    break;
                case WM_RBUTTONUP:
                case WM_CONTEXTMENU:
                    ShowMenu();
                    break;
            }
            return true;
        }
        if (msg == _taskbarCreated && _taskbarCreated != 0)
        {
            // Explorer restarted: put the icon back.
            Add();
            return true;
        }
        if (msg == WM_COPYDATA)
        {
            var copy = (COPYDATASTRUCT*)lParam;
            if (copy != null && copy->lpData != null && copy->cbData <= 512)
            {
                _host.Command(new string((char*)copy->lpData, 0, (int)(copy->cbData / 2)));
                result = 1;
            }
            return true;
        }
        return false;
    }

    /// <summary>The menu, at the pointer. It blocks the UI thread while open, as every Win32 menu does.</summary>
    public void ShowMenu()
    {
        POINT point;
        GetCursorPos(&point);
        var menu = CreatePopupMenu();
        Item(menu, MenuOpen, "Open Bridgey");
        Separator(menu);
        var targets = _host.ClipboardTargets();
        if (targets.Count == 0) Item(menu, 0, "No devices connected", MF_GRAYED);
        for (var i = 0; i < Math.Min(targets.Count, 8); i++) Item(menu, MenuSendFirst + i, $"Send clipboard to {targets[i].Name}");
        Separator(menu);
        Item(menu, MenuPair, "Pair a device");
        Item(menu, MenuAllow, "Allow pairing for 2 minutes");
        Item(menu, MenuSettings, "Settings");
        Separator(menu);
        Item(menu, MenuQuit, "Quit Bridgey");
        SetForegroundWindow(_hwnd);
        var chosen = TrackPopupMenuEx(menu, TPM_RETURNCMD | TPM_RIGHTBUTTON | TPM_NONOTIFY, point.X, point.Y, _hwnd, 0);
        PostMessage(_hwnd, WM_NULL, 0, 0);
        DestroyMenu(menu);
        switch (chosen)
        {
            case MenuOpen: _host.Open(); break;
            case MenuAllow: _host.AllowPairing(); break;
            case MenuPair: _host.Pair(); break;
            case MenuSettings: _host.Settings(); break;
            case MenuQuit: _host.Quit(); break;
            case >= MenuSendFirst when chosen - MenuSendFirst < targets.Count: _host.SendClipboard(targets[chosen - MenuSendFirst].Id); break;
        }
    }

    private static void Item(nint menu, int id, string text, uint flags = MF_STRING)
    {
        fixed (char* t = text) AppendMenu(menu, flags, (nuint)id, t);
    }

    private static void Separator(nint menu) => AppendMenu(menu, MF_SEPARATOR, 0, null);

    public void Dispose()
    {
        if (_added)
        {
            var data = Data(0);
            Shell_NotifyIcon(NIM_DELETE, &data);
            _added = false;
        }
        if (_icon != 0) DestroyIcon(_icon);
        DestroyWindow(_hwnd);
        if (_current == this) _current = null;
    }

    /// <summary>A second launch hands its command to the running one and exits. True when it found one.</summary>
    public static bool Forward(string command)
    {
        nint target;
        fixed (char* cls = ClassName) target = FindWindow(cls, null);
        if (target == 0) return false;
        fixed (char* text = command)
        {
            var copy = new COPYDATASTRUCT { dwData = 1, cbData = (uint)(command.Length * 2), lpData = text };
            SendMessage(target, WM_COPYDATA, 0, (nint)(&copy));
        }
        return true;
    }
}
