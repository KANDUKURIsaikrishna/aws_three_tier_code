import { attachAuthHeader, handleAuthError } from "./api";

describe("attachAuthHeader", () => {
  beforeEach(() => {
    localStorage.clear();
  });

  test("attaches Authorization header when a token is stored", () => {
    localStorage.setItem("bookstore_token", "abc123");
    const config = { headers: {} };
    const result = attachAuthHeader(config);
    expect(result.headers.Authorization).toBe("Bearer abc123");
  });

  test("does not attach a header when no token is stored", () => {
    const config = { headers: {} };
    const result = attachAuthHeader(config);
    expect(result.headers.Authorization).toBeUndefined();
  });
});

describe("handleAuthError", () => {
  beforeEach(() => {
    localStorage.clear();
    localStorage.setItem("bookstore_token", "abc123");
    localStorage.setItem("bookstore_email", "test@example.com");
    Object.defineProperty(window, "location", {
      writable: true,
      value: { href: "" },
    });
  });

  test("clears stored auth and redirects to /login on a 401", async () => {
    const error = { response: { status: 401 } };
    await expect(handleAuthError(error)).rejects.toBe(error);
    expect(localStorage.getItem("bookstore_token")).toBeNull();
    expect(localStorage.getItem("bookstore_email")).toBeNull();
    expect(window.location.href).toBe("/login");
  });

  test("leaves stored auth alone and does not redirect on other errors", async () => {
    const error = { response: { status: 500 } };
    await expect(handleAuthError(error)).rejects.toBe(error);
    expect(localStorage.getItem("bookstore_token")).toBe("abc123");
    expect(window.location.href).toBe("");
  });

  test("does not clear stored auth or redirect on a 401 from /auth/login", async () => {
    // A 401 here means "wrong credentials," an expected error the Login
    // page's own catch block needs to display -- not a session expiry.
    const error = { response: { status: 401 }, config: { url: "/auth/login" } };
    await expect(handleAuthError(error)).rejects.toBe(error);
    expect(localStorage.getItem("bookstore_token")).toBe("abc123");
    expect(window.location.href).toBe("");
  });

  test("does not clear stored auth or redirect on a 401 from /auth/register", async () => {
    const error = { response: { status: 401 }, config: { url: "/auth/register" } };
    await expect(handleAuthError(error)).rejects.toBe(error);
    expect(localStorage.getItem("bookstore_token")).toBe("abc123");
    expect(window.location.href).toBe("");
  });
});
