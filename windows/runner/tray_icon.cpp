#include "tray_icon.h"

#include <shellapi.h>
#include <windowsx.h>

#include "resource.h"

namespace {

constexpr UINT kShowCommand = 1;
constexpr UINT kExitCommand = 2;

NOTIFYICONDATAW IconData(HWND window) {
  NOTIFYICONDATAW data{};
  data.cbSize = sizeof(data);
  data.hWnd = window;
  data.uID = TrayIcon::kIconId;
  return data;
}

}  // namespace

TrayIcon::TrayIcon(HWND window)
    : window_(window),
      taskbar_created_message_(RegisterWindowMessageW(L"TaskbarCreated")) {}

TrayIcon::~TrayIcon() {
  RemoveIcon();
  if (icon_) {
    DestroyIcon(icon_);
  }
}

bool TrayIcon::EnsureIcon() {
  // A restart notification is required to keep a hidden window recoverable.
  if (!IsWindow(window_) || taskbar_created_message_ == 0) {
    return false;
  }
  if (!icon_) {
    // LoadImage without LR_SHARED gives this controller an owned icon handle.
    icon_ = static_cast<HICON>(LoadImageW(
        GetModuleHandleW(nullptr), MAKEINTRESOURCEW(IDI_APP_ICON), IMAGE_ICON,
        GetSystemMetrics(SM_CXSMICON), GetSystemMetrics(SM_CYSMICON),
        LR_DEFAULTCOLOR));
    if (!icon_) {
      return false;
    }
  }

  auto data = IconData(window_);
  data.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP | NIF_SHOWTIP;
  data.uCallbackMessage = kCallbackMessage;
  data.hIcon = icon_;
  wcscpy_s(data.szTip, L"青卷 — 点击显示窗口");
  if (icon_registered_ && Shell_NotifyIconW(NIM_MODIFY, &data)) {
    return true;
  }
  icon_registered_ = false;
  version_four_ = false;
  if (!Shell_NotifyIconW(NIM_ADD, &data)) {
    return false;
  }
  icon_registered_ = true;
  icon_requested_ = true;

  // The version must be set again after every NIM_ADD, including Explorer
  // restarts. If unavailable, retain the legacy notification decoding below.
  data.uVersion = NOTIFYICON_VERSION_4;
  version_four_ = Shell_NotifyIconW(NIM_SETVERSION, &data) != FALSE;
  return true;
}

void TrayIcon::RemoveIcon() {
  if (icon_registered_) {
    auto data = IconData(window_);
    Shell_NotifyIconW(NIM_DELETE, &data);
    icon_registered_ = false;
  }
  version_four_ = false;
}

bool TrayIcon::HideToTray() {
  if (!EnsureIcon()) {
    // This also covers a second request after Explorer has disappeared.
    if (hidden_by_tray_) {
      RestoreWindow();
    }
    return false;
  }
  if (!hidden_by_tray_ || IsWindowVisible(window_)) {
    WINDOWPLACEMENT placement{};
    placement.length = sizeof(placement);
    const bool restore_maximized =
        IsIconic(window_) && GetWindowPlacement(window_, &placement) &&
        (placement.flags & WPF_RESTORETOMAXIMIZED) != 0;
    restore_show_command_ = IsZoomed(window_) || restore_maximized
                                ? SW_SHOWMAXIMIZED
                                : SW_SHOWNORMAL;
  }
  ShowWindow(window_, SW_HIDE);
  hidden_by_tray_ = IsWindowVisible(window_) == FALSE;
  return hidden_by_tray_;
}

void TrayIcon::RestoreWindow() {
  if (!IsWindow(window_)) {
    return;
  }
  if (!IsWindowVisible(window_) && hidden_by_tray_) {
    ShowWindow(window_, restore_show_command_);
  } else if (IsIconic(window_)) {
    ShowWindow(window_, SW_RESTORE);
  } else {
    // SW_SHOW preserves the current maximized state when already visible.
    ShowWindow(window_, SW_SHOW);
  }
  hidden_by_tray_ = false;
  SetForegroundWindow(window_);
  BringWindowToTop(window_);
}

void TrayIcon::ShowContextMenu(POINT anchor) {
  HMENU menu = CreatePopupMenu();
  if (!menu) {
    RestoreWindow();
    return;
  }
  if (!AppendMenuW(menu, MF_STRING, kShowCommand, L"显示青卷") ||
      !AppendMenuW(menu, MF_SEPARATOR, 0, nullptr) ||
      !AppendMenuW(menu, MF_STRING, kExitCommand, L"退出青卷")) {
    DestroyMenu(menu);
    RestoreWindow();
    return;
  }
  SetMenuDefaultItem(menu, kShowCommand, FALSE);
  SetForegroundWindow(window_);
  const UINT command = static_cast<UINT>(TrackPopupMenu(
      menu, TPM_RETURNCMD | TPM_NONOTIFY | TPM_RIGHTBUTTON, anchor.x, anchor.y,
      0, window_, nullptr));
  // Required by the Shell menu pattern: dismiss correctly on the next click,
  // including when the popup owner is the hidden main window.
  PostMessageW(window_, WM_NULL, 0, 0);
  DestroyMenu(menu);

  if (command == kShowCommand) {
    RestoreWindow();
  } else if (command == kExitCommand) {
    // Keep any existing close confirmation visible and follow the same close
    // path as the title bar. Do not terminate the process or backend directly.
    RestoreWindow();
    PostMessageW(window_, WM_CLOSE, 0, 0);
  } else if (icon_registered_) {
    auto data = IconData(window_);
    Shell_NotifyIconW(NIM_SETFOCUS, &data);
  }
}

std::optional<LRESULT> TrayIcon::HandleMessage(UINT message, WPARAM wparam,
                                              LPARAM lparam) {
  if (taskbar_created_message_ != 0 && message == taskbar_created_message_) {
    if (icon_requested_) {
      // Explorer discards all notification icons when it recreates the taskbar.
      // Deleting first also handles DPI-triggered TaskbarCreated broadcasts.
      RemoveIcon();
      if (!EnsureIcon() && hidden_by_tray_) {
        RestoreWindow();
      }
    }
    return 0;
  }
  if (message != kCallbackMessage) {
    return std::nullopt;
  }
  if (!icon_registered_) {
    return 0;
  }
  const UINT icon_id = version_four_ ? HIWORD(lparam)
                                     : static_cast<UINT>(wparam);
  if (icon_id != kIconId) {
    return 0;
  }
  const UINT notification = version_four_ ? LOWORD(lparam)
                                          : static_cast<UINT>(lparam);
  switch (notification) {
    case NIN_SELECT:
    case NIN_KEYSELECT:
    case WM_LBUTTONUP:
    case WM_LBUTTONDBLCLK:
      RestoreWindow();
      break;
    case WM_CONTEXTMENU:
    case WM_RBUTTONUP: {
      POINT anchor{};
      GetCursorPos(&anchor);
      // Version 4 coordinates include the icon location for keyboard access.
      if (version_four_) {
        const POINT event_anchor{GET_X_LPARAM(wparam), GET_Y_LPARAM(wparam)};
        if (event_anchor.x != -1 || event_anchor.y != -1) {
          anchor = event_anchor;
        }
      }
      ShowContextMenu(anchor);
      break;
    }
    default:
      break;
  }
  return 0;
}
