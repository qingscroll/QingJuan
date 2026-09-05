// Standalone Win32 regression tests for the production tray controller.
// --real exercises only non-activating operations on an owned off-screen window.
// --shim isolates activation/menu/failure APIs so the user's foreground is never
// changed. The production source is included unchanged, with test-local aliases.
#include <windows.h>
#include <shellapi.h>
#include <windowsx.h>

#include <algorithm>
#include <cstdio>
#include <memory>
#include <stdexcept>
#include <string>
#include <vector>

#include "../../windows/runner/tray_icon.h"

namespace smoke {

struct State {
  bool real = false;
  bool visible = true;
  bool iconic = false;
  bool zoomed = false;
  UINT placement_flags = 0;
  bool registered = false;
  bool fail_add = false;
  bool fail_modify = false;
  bool fail_version = false;
  bool fail_load = false;
  bool fail_menu = false;
  bool fail_append = false;
  UINT menu_command = 0;
  unsigned ticks = 0;
  unsigned adds = 0;
  unsigned modifies = 0;
  unsigned deletes = 0;
  unsigned versions = 0;
  unsigned destroyed_icons = 0;
  unsigned foreground_calls = 0;
  unsigned top_calls = 0;
  unsigned close_posts = 0;
  unsigned unexpected_real_activations = 0;
  std::vector<int> show_commands;
} state;

void Require(bool condition, const char* message) {
  if (!condition) throw std::runtime_error(message);
}

BOOL WINAPI NotifyIcon(DWORD message, PNOTIFYICONDATAW data) {
  switch (message) {
    case NIM_ADD: ++state.adds; break;
    case NIM_MODIFY: ++state.modifies; break;
    case NIM_DELETE: ++state.deletes; break;
    case NIM_SETVERSION: ++state.versions; break;
  }
  if (state.real) return ::Shell_NotifyIconW(message, data);
  switch (message) {
    case NIM_ADD:
      if (state.fail_add) return FALSE;
      state.registered = true;
      return TRUE;
    case NIM_MODIFY:
      return state.registered && !state.fail_modify;
    case NIM_DELETE:
      state.registered = false;
      return TRUE;
    case NIM_SETVERSION:
      return !state.fail_version;
    default:
      return TRUE;
  }
}

HANDLE WINAPI LoadImage(HINSTANCE instance, LPCWSTR name, UINT type, int cx,
                        int cy, UINT flags) {
  if (state.fail_load) return nullptr;
  return ::LoadImageW(instance, name, type, cx, cy, flags);
}

BOOL WINAPI DestroyIcon(HICON icon) {
  ++state.destroyed_icons;
  return ::DestroyIcon(icon);
}

BOOL WINAPI ShowWindow(HWND window, int command) {
  state.show_commands.push_back(command);
  if (state.real) {
    // Real tests deliberately never exercise an activating restore operation.
    if (command != SW_HIDE) {
      ++state.unexpected_real_activations;
      return FALSE;
    }
    return ::ShowWindow(window, command);
  }
  const bool previous = state.visible;
  state.visible = command != SW_HIDE;
  if (command == SW_SHOWMAXIMIZED) {
    state.zoomed = true;
    state.iconic = false;
  } else if (command == SW_SHOWNORMAL || command == SW_RESTORE) {
    state.zoomed = command == SW_RESTORE &&
                   (state.placement_flags & WPF_RESTORETOMAXIMIZED) != 0;
    state.iconic = false;
  }
  return previous;
}

BOOL WINAPI IsVisible(HWND window) {
  return state.real ? ::IsWindowVisible(window) : state.visible;
}
BOOL WINAPI IsIconic(HWND window) {
  return state.real ? ::IsIconic(window) : state.iconic;
}
BOOL WINAPI IsZoomed(HWND window) {
  return state.real ? ::IsZoomed(window) : state.zoomed;
}
BOOL WINAPI GetPlacement(HWND window, WINDOWPLACEMENT* placement) {
  if (state.real) return ::GetWindowPlacement(window, placement);
  placement->flags = state.placement_flags;
  return TRUE;
}
BOOL WINAPI Foreground(HWND) {
  ++state.foreground_calls;
  if (state.real) ++state.unexpected_real_activations;
  return TRUE;
}
BOOL WINAPI BringTop(HWND) {
  ++state.top_calls;
  if (state.real) ++state.unexpected_real_activations;
  return TRUE;
}
HMENU WINAPI CreateMenu() {
  return state.fail_menu ? nullptr : ::CreatePopupMenu();
}
BOOL WINAPI AppendMenu(HMENU menu, UINT flags, UINT_PTR id, LPCWSTR label) {
  return state.fail_append ? FALSE : ::AppendMenuW(menu, flags, id, label);
}
BOOL WINAPI TrackMenu(HMENU, UINT, int, int, int, HWND, const RECT*) {
  Require(!state.real, "real smoke must not open popup menus");
  return state.menu_command;
}
BOOL WINAPI PostMessage(HWND window, UINT message, WPARAM wparam, LPARAM lparam) {
  if (message == WM_CLOSE) ++state.close_posts;
  return state.real ? ::PostMessageW(window, message, wparam, lparam) : TRUE;
}

}  // namespace smoke

#define Shell_NotifyIconW smoke::NotifyIcon
#define LoadImageW smoke::LoadImage
#define DestroyIcon smoke::DestroyIcon
#define ShowWindow smoke::ShowWindow
#define IsWindowVisible smoke::IsVisible
#define IsIconic smoke::IsIconic
#define IsZoomed smoke::IsZoomed
#define GetWindowPlacement smoke::GetPlacement
#define SetForegroundWindow smoke::Foreground
#define BringWindowToTop smoke::BringTop
#define CreatePopupMenu smoke::CreateMenu
#define AppendMenuW smoke::AppendMenu
#define TrackPopupMenu smoke::TrackMenu
#define PostMessageW smoke::PostMessage
#include "../../windows/runner/tray_icon.cpp"
#undef Shell_NotifyIconW
#undef LoadImageW
#undef DestroyIcon
#undef ShowWindow
#undef IsWindowVisible
#undef IsIconic
#undef IsZoomed
#undef GetWindowPlacement
#undef SetForegroundWindow
#undef BringWindowToTop
#undef CreatePopupMenu
#undef AppendMenuW
#undef TrackPopupMenu
#undef PostMessageW

namespace smoke {

TrayIcon* active_tray = nullptr;

LRESULT CALLBACK WindowProc(HWND window, UINT message, WPARAM wparam,
                            LPARAM lparam) {
  if (message == WM_TIMER) {
    ++state.ticks;
    return 0;
  }
  if (active_tray) {
    auto result = active_tray->HandleMessage(message, wparam, lparam);
    if (result) return *result;
  }
  return ::DefWindowProcW(window, message, wparam, lparam);
}

struct OwnedWindow {
  HWND handle = nullptr;
  OwnedWindow() {
    WNDCLASSW window_class{};
    window_class.lpfnWndProc = WindowProc;
    window_class.hInstance = GetModuleHandleW(nullptr);
    window_class.lpszClassName = L"QingJuanTraySmokeOwnedWindow";
    Require(RegisterClassW(&window_class) != 0, "register test window failed");
    handle = CreateWindowExW(
        WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE, window_class.lpszClassName,
        L"QingJuan tray smoke (owned test window)", WS_POPUP | WS_DISABLED,
        -32000, -32000, 160, 100, nullptr, nullptr, window_class.hInstance,
        nullptr);
    Require(handle != nullptr, "create test window failed");
  }
  ~OwnedWindow() {
    active_tray = nullptr;
    if (handle) {
      KillTimer(handle, 1);
      DestroyWindow(handle);
    }
    UnregisterClassW(L"QingJuanTraySmokeOwnedWindow", GetModuleHandleW(nullptr));
  }
};

void PumpFor(DWORD duration_ms) {
  const ULONGLONG deadline = GetTickCount64() + duration_ms;
  do {
    MSG message{};
    while (PeekMessageW(&message, nullptr, 0, 0, PM_REMOVE)) {
      TranslateMessage(&message);
      DispatchMessageW(&message);
    }
    MsgWaitForMultipleObjects(0, nullptr, FALSE, 10, QS_ALLINPUT);
  } while (GetTickCount64() < deadline);
}

void Notify(TrayIcon& tray, UINT notification, bool version_four = true,
            UINT id = TrayIcon::kIconId) {
  tray.HandleMessage(TrayIcon::kCallbackMessage,
                     version_four ? 0 : id,
                     version_four ? MAKELPARAM(notification, id) : notification);
}

void TestReal(HWND window) {
  state = State{};
  state.real = true;
  const HWND foreground_before = GetForegroundWindow();
  ::ShowWindow(window, SW_SHOWNOACTIVATE);
  Require(::IsWindowVisible(window), "off-screen test window should be visible");
  Require(SetTimer(window, 1, 15, nullptr) != 0, "test timer failed");
  {
    TrayIcon tray(window);
    active_tray = &tray;
    Require(tray.HideToTray(), "real notification icon registration/hide failed");
    Require(!::IsWindowVisible(window), "real window remained visible");
    Require(state.adds == 1 && state.versions == 1,
            "real icon add/version handshake missing");
    PumpFor(160);
    Require(state.ticks >= 2, "background timer stopped while hidden");
    const unsigned ticks_before = state.ticks;
    const UINT taskbar_created = RegisterWindowMessageW(L"TaskbarCreated");
    Require(taskbar_created != 0, "register TaskbarCreated failed");
    // Simulate only on this window. Explorer and other applications are untouched.
    SendMessageW(window, taskbar_created, 0, 0);
    Require(state.adds == 2 && state.deletes == 1 && state.versions == 2,
            "real taskbar restart handshake was not rebuilt");
    Require(!::IsWindowVisible(window), "restart unexpectedly restored test window");
    PumpFor(80);
    Require(state.ticks > ticks_before, "timer stopped after icon recreation");
    active_tray = nullptr;
  }
  Require(state.deletes == 2 && state.destroyed_icons == 1,
          "real icon resources were not cleaned on destruction");
  Require(state.unexpected_real_activations == 0,
          "real test attempted a foreground/activation operation");
  Require(GetForegroundWindow() == foreground_before,
          "foreground changed during real smoke (possibly external user activity)");
  KillTimer(window, 1);
  std::puts("PASS real: icon register/hide, background timer, owned TaskbarCreated, cleanup; no foreground activation");
}

void TestCallbacks(HWND window) {
  for (UINT event : {static_cast<UINT>(NIN_SELECT), static_cast<UINT>(NIN_KEYSELECT),
                     static_cast<UINT>(WM_LBUTTONUP),
                     static_cast<UINT>(WM_LBUTTONDBLCLK)}) {
    state = State{};
    TrayIcon tray(window);
    Require(tray.HideToTray() && !state.visible, "v4 callback setup failed");
    Notify(tray, event, true, 99);
    Require(!state.visible, "foreign notification id restored window");
    Notify(tray, event);
    Require(state.visible && state.show_commands.back() == SW_SHOWNORMAL,
            "v4 callback did not restore hidden window");
    Require(state.foreground_calls == 1 && state.top_calls == 1,
            "restore did not request foreground/top");
  }
  state = State{};
  state.fail_version = true;
  TrayIcon tray(window);
  Require(tray.HideToTray(), "legacy setup failed");
  Notify(tray, WM_LBUTTONUP, false);
  Require(state.visible, "legacy callback did not restore window");
  std::puts("PASS shim: v4 select/keyselect/click/double-click, foreign id, legacy notification");
}

void TestPlacement(HWND window) {
  state = State{};
  {
    state.zoomed = true;
    TrayIcon tray(window);
    Require(tray.HideToTray(), "maximized hide failed");
    Require(tray.HideToTray(), "repeated hide failed");
    tray.RestoreWindow();
    Require(state.show_commands.back() == SW_SHOWMAXIMIZED && state.zoomed,
            "maximized state lost across repeated hide/restore");
    tray.RestoreWindow();
    Require(state.show_commands.back() == SW_SHOW && state.zoomed,
            "visible maximize state lost when showing again");
  }
  state = State{};
  {
    state.iconic = true;
    TrayIcon tray(window);
    tray.RestoreWindow();
    Require(state.show_commands.back() == SW_RESTORE && !state.iconic,
            "ordinary minimized window did not restore");
  }
  state = State{};
  {
    state.iconic = true;
    state.placement_flags = WPF_RESTORETOMAXIMIZED;
    TrayIcon tray(window);
    Require(tray.HideToTray(), "minimized-maximized hide failed");
    tray.RestoreWindow();
    Require(state.show_commands.back() == SW_SHOWMAXIMIZED && state.zoomed,
            "minimized maximized placement was not retained");
  }
  std::puts("PASS shim: normal/maximized/repeated/minimized restore placement");
}

void TestFailures(HWND window) {
  state = State{};
  {
    state.fail_load = true;
    TrayIcon tray(window);
    Require(!tray.HideToTray() && state.visible && state.show_commands.empty(),
            "icon load failure hid the window");
  }
  state = State{};
  {
    state.fail_add = true;
    TrayIcon tray(window);
    Require(!tray.HideToTray() && state.visible && state.show_commands.empty(),
            "initial Shell registration failure hid the window");
  }
  state = State{};
  {
    TrayIcon tray(window);
    Require(tray.HideToTray(), "repeat failure setup failed");
    state.fail_modify = true;
    state.fail_add = true;
    Require(!tray.HideToTray() && state.visible,
            "lost icon left repeated hide window inaccessible");
  }
  state = State{};
  {
    TrayIcon tray(window);
    Require(tray.HideToTray(), "restart failure setup failed");
    state.fail_add = true;
    tray.HandleMessage(RegisterWindowMessageW(L"TaskbarCreated"), 0, 0);
    Require(state.visible && state.deletes == 1 && state.adds == 2,
            "failed taskbar icon recreation did not restore window");
  }
  std::puts("PASS shim: icon load/add/modify/rebuild failures leave window recoverable");
}

void TestMenusAndCleanup(HWND window) {
  state = State{};
  {
    TrayIcon tray(window);
    Require(!tray.HandleMessage(WM_USER + 10, 0, 0).has_value(),
            "unrelated message was consumed");
    tray.HandleMessage(RegisterWindowMessageW(L"TaskbarCreated"), 0, 0);
    Require(state.adds == 0, "restart registered unsolicited icon");
    Require(tray.HideToTray(), "menu show setup failed");
    state.menu_command = 1;
    Notify(tray, WM_CONTEXTMENU);
    Require(state.visible && state.close_posts == 0,
            "show menu command did not only restore");
    Require(tray.HideToTray(), "menu exit setup failed");
    state.menu_command = 2;
    Notify(tray, WM_RBUTTONUP);
    Require(state.visible && state.close_posts == 1,
            "exit menu command did not restore and post normal WM_CLOSE");
  }
  Require(state.deletes == 1 && state.destroyed_icons == 1 && !state.registered,
          "shim icon resources leaked on destruction");
  for (bool fail_create : {true, false}) {
    state = State{};
    TrayIcon tray(window);
    Require(tray.HideToTray(), "menu failure setup failed");
    state.fail_menu = fail_create;
    state.fail_append = !fail_create;
    Notify(tray, WM_CONTEXTMENU);
    Require(state.visible, "menu creation failure left window hidden");
  }
  std::puts("PASS shim: menu show/exit normal close path, menu failures, unsolicited/unrelated messages, cleanup");
}

}  // namespace smoke

int main(int argc, char** argv) {
  try {
    smoke::Require(argc == 2, "usage: windows_tray_smoke.exe --real|--shim");
    smoke::OwnedWindow window;
    if (std::string(argv[1]) == "--real") {
      smoke::TestReal(window.handle);
    } else if (std::string(argv[1]) == "--shim") {
      smoke::TestCallbacks(window.handle);
      smoke::TestPlacement(window.handle);
      smoke::TestFailures(window.handle);
      smoke::TestMenusAndCleanup(window.handle);
    } else {
      throw std::runtime_error("unknown test mode");
    }
    return 0;
  } catch (const std::exception& error) {
    std::fprintf(stderr, "FAIL: %s\n", error.what());
    return 1;
  }
}
