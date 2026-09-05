#ifndef RUNNER_TRAY_ICON_H_
#define RUNNER_TRAY_ICON_H_

#include <windows.h>

#include <optional>

// Owns only the notification icon. Hiding never destroys the application window
// or its Flutter engine, so work already running can continue in the tray.
class TrayIcon {
 public:
  static constexpr UINT kCallbackMessage = WM_APP + 0x51;
  static constexpr UINT kIconId = 1;

  explicit TrayIcon(HWND window);
  ~TrayIcon();

  TrayIcon(const TrayIcon&) = delete;
  TrayIcon& operator=(const TrayIcon&) = delete;

  // Returns false without hiding if the notification icon cannot be registered.
  bool HideToTray();
  void RestoreWindow();
  std::optional<LRESULT> HandleMessage(UINT message, WPARAM wparam,
                                       LPARAM lparam);

 private:
  bool EnsureIcon();
  void RemoveIcon();
  void ShowContextMenu(POINT anchor);

  HWND window_;
  UINT taskbar_created_message_;
  HICON icon_ = nullptr;
  bool icon_registered_ = false;
  bool icon_requested_ = false;
  bool version_four_ = false;
  bool hidden_by_tray_ = false;
  int restore_show_command_ = SW_SHOWNORMAL;
};

#endif  // RUNNER_TRAY_ICON_H_
