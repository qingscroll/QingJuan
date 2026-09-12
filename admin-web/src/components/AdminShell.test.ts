import { navigationAvailable, navigationFromHash } from "./AdminShell";

describe("admin deep links", () => {
  it("opens model settings from the fixed settings hash", () => {
    expect(navigationFromHash("#settings")).toBe("settings");
    expect(navigationFromHash("#/settings")).toBe("settings");
  });

  it("opens plugin management from the fixed plugins hash", () => {
    expect(navigationFromHash("#plugins")).toBe("plugins");
    expect(navigationFromHash("#/plugins")).toBe("plugins");
  });

  it("opens user management from the fixed users hash", () => {
    expect(navigationFromHash("#users")).toBe("users");
    expect(navigationFromHash("#/users")).toBe("users");
  });

  it("opens registration settings from the fixed registration hash", () => {
    expect(navigationFromHash("#registration")).toBe("registration");
    expect(navigationFromHash("#/registration")).toBe("registration");
  });

  it("opens backend upgrade from the fixed upgrade hash", () => {
    expect(navigationFromHash("#upgrade")).toBe("upgrade");
    expect(navigationFromHash("#/upgrade")).toBe("upgrade");
  });

  it("opens backup management only when the backend supports backups", () => {
    expect(navigationFromHash("#backups")).toBe("backups");
    expect(navigationAvailable("backups", { backups: true })).toBe(true);
    expect(navigationAvailable("backups", { backups: false })).toBe(false);
    expect(navigationAvailable("backups", undefined)).toBe(false);
  });

  it("falls back to the overview for unknown hashes", () => {
    expect(navigationFromHash("#unknown" as string)).toBe("overview");
    expect(navigationFromHash("")).toBe("overview");
  });

  it("hides all multi-user administration routes from a single-user backend", () => {
    expect(navigationAvailable("users", { multiUser: false })).toBe(false);
    expect(navigationAvailable("registration", { multiUser: false })).toBe(false);
    expect(navigationAvailable("registration", undefined)).toBe(false);
    expect(navigationAvailable("users", { multiUser: true })).toBe(true);
    expect(navigationAvailable("settings", { multiUser: false })).toBe(true);
  });
});
