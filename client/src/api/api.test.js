import axios, { __mockApiInstance as mockApiInstance } from "axios";
import { attachAuthHeader, handleAuthError, clearSession, resetRefreshState } from "./api";

// The mock instance is created entirely inside the factory (not referenced
// from outer scope) and exposed as a named export -- referencing an
// outer-scope const from inside jest.mock's factory hits a hoisting/TDZ
// error, since the factory can run before that const's own initializer has.
// Jest's babel-plugin-jest-hoist moves this call above the imports above at
// transform time regardless of source order, so this placement is safe.
jest.mock("axios", () => {
  const instance = {
    interceptors: { request: { use: jest.fn() }, response: { use: jest.fn() } },
    request: jest.fn(),
  };
  return {
    __esModule: true,
    default: { create: jest.fn(() => instance), post: jest.fn() },
    __mockApiInstance: instance,
  };
});

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

describe("clearSession", () => {
  test("removes the token, refresh token, and email from localStorage", () => {
    localStorage.setItem("bookstore_token", "t");
    localStorage.setItem("bookstore_refresh_token", "r");
    localStorage.setItem("bookstore_email", "e@example.com");
    clearSession();
    expect(localStorage.getItem("bookstore_token")).toBeNull();
    expect(localStorage.getItem("bookstore_refresh_token")).toBeNull();
    expect(localStorage.getItem("bookstore_email")).toBeNull();
  });
});

describe("handleAuthError", () => {
  beforeEach(() => {
    localStorage.clear();
    localStorage.setItem("bookstore_token", "abc123");
    localStorage.setItem("bookstore_refresh_token", "refresh-abc");
    localStorage.setItem("bookstore_email", "test@example.com");
    Object.defineProperty(window, "location", {
      writable: true,
      value: { href: "" },
    });
    mockApiInstance.request.mockReset();
    axios.post.mockReset();
    resetRefreshState();
  });

  test("leaves stored auth alone and does not redirect on a non-401 error", async () => {
    const error = { response: { status: 500 }, config: { url: "/orders" } };
    await expect(handleAuthError(error)).rejects.toBe(error);
    expect(localStorage.getItem("bookstore_token")).toBe("abc123");
    expect(window.location.href).toBe("");
  });

  test("does not attempt a refresh or redirect on a 401 from /auth/login", async () => {
    // A 401 here means "wrong credentials," an expected error the Login
    // page's own catch block needs to display -- not a session to recover.
    const error = { response: { status: 401 }, config: { url: "/auth/login" } };
    await expect(handleAuthError(error)).rejects.toBe(error);
    expect(axios.post).not.toHaveBeenCalled();
    expect(localStorage.getItem("bookstore_token")).toBe("abc123");
    expect(window.location.href).toBe("");
  });

  test("does not attempt a refresh or redirect on a 401 from /auth/register", async () => {
    const error = { response: { status: 401 }, config: { url: "/auth/register" } };
    await expect(handleAuthError(error)).rejects.toBe(error);
    expect(axios.post).not.toHaveBeenCalled();
    expect(window.location.href).toBe("");
  });

  test("does not attempt a refresh or redirect on a 401 from /auth/refresh itself", async () => {
    // A 401 here means the refresh token itself was invalid/expired --
    // attempting to refresh the refresh call would recurse forever.
    const error = { response: { status: 401 }, config: { url: "/auth/refresh" } };
    await expect(handleAuthError(error)).rejects.toBe(error);
    expect(axios.post).not.toHaveBeenCalled();
    expect(window.location.href).toBe("");
  });

  test("on a 401 from any other endpoint, silently refreshes and retries the original request", async () => {
    axios.post.mockResolvedValueOnce({
      data: { token: "new-access", refreshToken: "new-refresh" },
    });
    mockApiInstance.request.mockResolvedValueOnce({ data: { ok: true } });

    const originalRequest = { url: "/orders", headers: {} };
    const error = { response: { status: 401 }, config: originalRequest };

    const result = await handleAuthError(error);

    expect(axios.post).toHaveBeenCalledWith(
      expect.stringContaining("/auth/refresh"),
      { refreshToken: "refresh-abc" }
    );
    expect(localStorage.getItem("bookstore_token")).toBe("new-access");
    expect(localStorage.getItem("bookstore_refresh_token")).toBe("new-refresh");
    expect(mockApiInstance.request).toHaveBeenCalledWith(
      expect.objectContaining({
        url: "/orders",
        _retriedAfterRefresh: true,
        headers: expect.objectContaining({ Authorization: "Bearer new-access" }),
      })
    );
    expect(result).toEqual({ data: { ok: true } });
    expect(window.location.href).toBe("");
  });

  test("clears the session and redirects when no refresh token is stored", async () => {
    localStorage.removeItem("bookstore_refresh_token");
    const error = { response: { status: 401 }, config: { url: "/orders", headers: {} } };

    await expect(handleAuthError(error)).rejects.toBeInstanceOf(Error);

    expect(axios.post).not.toHaveBeenCalled();
    expect(localStorage.getItem("bookstore_token")).toBeNull();
    expect(window.location.href).toBe("/login");
  });

  test("clears the session and redirects when the refresh call itself fails", async () => {
    axios.post.mockRejectedValueOnce({ response: { status: 401 } });
    const error = { response: { status: 401 }, config: { url: "/orders", headers: {} } };

    await expect(handleAuthError(error)).rejects.toBeTruthy();

    expect(localStorage.getItem("bookstore_token")).toBeNull();
    expect(localStorage.getItem("bookstore_refresh_token")).toBeNull();
    expect(window.location.href).toBe("/login");
  });

  test("clears the session and redirects instead of retrying again if already retried once", async () => {
    const error = {
      response: { status: 401 },
      config: { url: "/orders", headers: {}, _retriedAfterRefresh: true },
    };

    await expect(handleAuthError(error)).rejects.toBe(error);

    expect(axios.post).not.toHaveBeenCalled();
    expect(localStorage.getItem("bookstore_token")).toBeNull();
    expect(window.location.href).toBe("/login");
  });
});
