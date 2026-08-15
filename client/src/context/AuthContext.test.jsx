import { useState } from "react";
import { render, screen, act } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { AuthProvider, useAuth } from "./AuthContext";
import api from "../api/api";

jest.mock("../api/api");

function TestConsumer() {
  const { isAuthenticated, email, login, register, logout } = useAuth();
  const [loginError, setLoginError] = useState("");

  const handleLogin = async () => {
    try {
      await login("test@example.com", "pw");
    } catch (err) {
      setLoginError("failed");
    }
  };

  return (
    <div>
      <span data-testid="status">{isAuthenticated ? "in" : "out"}</span>
      <span data-testid="email">{email || "none"}</span>
      <span data-testid="loginError">{loginError}</span>
      <button onClick={handleLogin}>do-login</button>
      <button onClick={() => register("new@example.com", "pw")}>do-register</button>
      <button onClick={logout}>do-logout</button>
    </div>
  );
}

describe("AuthContext", () => {
  beforeEach(() => {
    localStorage.clear();
    jest.clearAllMocks();
    // Sane default so any incidental api.post call (e.g. logout()'s
    // best-effort revoke) doesn't blow up on an auto-mocked function
    // returning undefined instead of a promise -- tests that care about a
    // specific call override this with mockResolvedValueOnce.
    api.post.mockResolvedValue({ data: {} });
  });

  test("starts logged out when localStorage has no token", () => {
    render(
      <AuthProvider>
        <TestConsumer />
      </AuthProvider>
    );
    expect(screen.getByTestId("status")).toHaveTextContent("out");
    expect(screen.getByTestId("email")).toHaveTextContent("none");
  });

  test("restores session from localStorage on mount", () => {
    localStorage.setItem("bookstore_token", "stored-token");
    localStorage.setItem("bookstore_email", "saved@example.com");
    render(
      <AuthProvider>
        <TestConsumer />
      </AuthProvider>
    );
    expect(screen.getByTestId("status")).toHaveTextContent("in");
    expect(screen.getByTestId("email")).toHaveTextContent("saved@example.com");
  });

  test("login calls POST /auth/login and stores the returned access + refresh tokens", async () => {
    api.post.mockResolvedValueOnce({ data: { token: "new-token", refreshToken: "new-refresh" } });
    render(
      <AuthProvider>
        <TestConsumer />
      </AuthProvider>
    );
    await act(async () => {
      await userEvent.click(screen.getByText("do-login"));
    });
    expect(api.post).toHaveBeenCalledWith("/auth/login", {
      email: "test@example.com",
      password: "pw",
    });
    expect(screen.getByTestId("status")).toHaveTextContent("in");
    expect(localStorage.getItem("bookstore_token")).toBe("new-token");
    expect(localStorage.getItem("bookstore_refresh_token")).toBe("new-refresh");
    expect(localStorage.getItem("bookstore_email")).toBe("test@example.com");
  });

  test("logout clears state and localStorage, and revokes the refresh token server-side", async () => {
    localStorage.setItem("bookstore_token", "stored-token");
    localStorage.setItem("bookstore_refresh_token", "stored-refresh");
    localStorage.setItem("bookstore_email", "saved@example.com");
    render(
      <AuthProvider>
        <TestConsumer />
      </AuthProvider>
    );
    await act(async () => {
      await userEvent.click(screen.getByText("do-logout"));
    });
    expect(screen.getByTestId("status")).toHaveTextContent("out");
    expect(localStorage.getItem("bookstore_token")).toBeNull();
    expect(localStorage.getItem("bookstore_refresh_token")).toBeNull();
    expect(api.post).toHaveBeenCalledWith("/auth/logout", { refreshToken: "stored-refresh" });
  });

  test("logout does not call /auth/logout when there was no refresh token to revoke", async () => {
    localStorage.setItem("bookstore_token", "stored-token");
    localStorage.setItem("bookstore_email", "saved@example.com");
    render(
      <AuthProvider>
        <TestConsumer />
      </AuthProvider>
    );
    await act(async () => {
      await userEvent.click(screen.getByText("do-logout"));
    });
    expect(api.post).not.toHaveBeenCalledWith("/auth/logout", expect.anything());
  });

  test("register calls POST /auth/register and does not log the user in", async () => {
    api.post.mockResolvedValueOnce({ data: { id: 1, email: "new@example.com" } });
    render(
      <AuthProvider>
        <TestConsumer />
      </AuthProvider>
    );
    await act(async () => {
      await userEvent.click(screen.getByText("do-register"));
    });
    expect(api.post).toHaveBeenCalledWith("/auth/register", {
      email: "new@example.com",
      password: "pw",
    });
    // /auth/register returns {id, email}, not a token -- register() must not
    // log the user in, only login() does.
    expect(screen.getByTestId("status")).toHaveTextContent("out");
    expect(screen.getByTestId("email")).toHaveTextContent("none");
    expect(localStorage.getItem("bookstore_token")).toBeNull();
  });

  test("a failed login rejects and leaves state/localStorage untouched", async () => {
    api.post.mockRejectedValueOnce({ response: { status: 401 } });
    render(
      <AuthProvider>
        <TestConsumer />
      </AuthProvider>
    );
    await act(async () => {
      await userEvent.click(screen.getByText("do-login"));
    });
    // The rejection must propagate out of login() uncaught so callers (e.g.
    // Login.jsx) can catch it and show their own error message -- confirmed
    // here via TestConsumer's own try/catch around login().
    expect(screen.getByTestId("loginError")).toHaveTextContent("failed");
    expect(screen.getByTestId("status")).toHaveTextContent("out");
    expect(localStorage.getItem("bookstore_token")).toBeNull();
  });

  test("useAuth throws when used outside an AuthProvider", () => {
    const consoleError = jest.spyOn(console, "error").mockImplementation(() => {});
    expect(() => render(<TestConsumer />)).toThrow(
      "useAuth must be used within an AuthProvider"
    );
    consoleError.mockRestore();
  });
});
