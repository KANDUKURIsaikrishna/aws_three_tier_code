import { render, screen, act } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { AuthProvider, useAuth } from "./AuthContext";
import api from "../api/api";

jest.mock("../api/api");

function TestConsumer() {
  const { isAuthenticated, email, login, logout } = useAuth();
  return (
    <div>
      <span data-testid="status">{isAuthenticated ? "in" : "out"}</span>
      <span data-testid="email">{email || "none"}</span>
      <button onClick={() => login("test@example.com", "pw")}>do-login</button>
      <button onClick={logout}>do-logout</button>
    </div>
  );
}

describe("AuthContext", () => {
  beforeEach(() => {
    localStorage.clear();
    jest.clearAllMocks();
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

  test("login calls POST /auth/login and stores the returned token", async () => {
    api.post.mockResolvedValueOnce({ data: { token: "new-token" } });
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
    expect(localStorage.getItem("bookstore_email")).toBe("test@example.com");
  });

  test("logout clears state and localStorage", async () => {
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
