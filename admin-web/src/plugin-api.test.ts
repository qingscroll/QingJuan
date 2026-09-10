import * as api from "./api";

it("uses multipart, same-origin sessions and CSRF for inspection and installation", async () => {
  const fetchMock = vi.fn().mockImplementation(() => Promise.resolve(new Response("{}", {headers: {"Content-Type": "application/json"}})));
  fetchMock.mockResolvedValueOnce(new Response(JSON.stringify({csrfToken: "package-csrf", csrfHeader: "X-QingJuan-CSRF"}),
    {headers: {"Content-Type": "application/json"}}));
  vi.stubGlobal("fetch", fetchMock);
  await api.login("password");
  const file = new File(["example"], "example.zip");
  await api.inspectSitePluginPackage(file);
  await api.importSitePluginPackage(file, true);
  for (const call of fetchMock.mock.calls.slice(1)) {
    const options = call[1] as RequestInit;
    expect(options.body).toBeInstanceOf(FormData);
    expect((options.body as FormData).get("file")).toBe(file);
    expect((options.headers as Headers).get("Content-Type")).toBeNull();
    expect((options.headers as Headers).get("X-QingJuan-CSRF")).toBe("package-csrf");
    expect(options.credentials).toBe("same-origin");
  }
  expect((fetchMock.mock.calls[2][1].body as FormData).get("replace")).toBe("true");
  api.clearSessionSecurity();
});
