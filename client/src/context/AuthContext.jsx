import { createContext, useContext, useState } from "react";
import api from "../api/api";

const AuthContext = createContext(null);

export function AuthProvider({ children }) {
  const [token, setToken] = useState(() => localStorage.getItem("bookstore_token"));
  const [email, setEmail] = useState(() => localStorage.getItem("bookstore_email"));
  const [role, setRole] = useState(() => localStorage.getItem("bookstore_role"));

  const login = async (loginEmail, password) => {
    const res = await api.post("/auth/login", { email: loginEmail, password });
    localStorage.setItem("bookstore_token", res.data.token);
    localStorage.setItem("bookstore_refresh_token", res.data.refreshToken);
    localStorage.setItem("bookstore_email", loginEmail);
    localStorage.setItem("bookstore_role", res.data.role);
    setToken(res.data.token);
    setEmail(loginEmail);
    setRole(res.data.role);
  };

  // /auth/register returns {id, email}, not a token -- the caller (Register
  // page) sends the user to /login afterwards, it does not log them in.
  const register = async (registerEmail, password) => {
    await api.post("/auth/register", { email: registerEmail, password });
  };

  const logout = () => {
    const storedRefreshToken = localStorage.getItem("bookstore_refresh_token");
    localStorage.removeItem("bookstore_token");
    localStorage.removeItem("bookstore_refresh_token");
    localStorage.removeItem("bookstore_email");
    localStorage.removeItem("bookstore_role");
    setToken(null);
    setEmail(null);
    setRole(null);
    // Best-effort, not awaited -- the UI logs the user out immediately
    // either way. This just revokes the refresh token server-side so it
    // can't be used to mint new access tokens if it were ever stolen; a
    // failure here (offline, server down) shouldn't block logging out.
    if (storedRefreshToken) {
      api.post("/auth/logout", { refreshToken: storedRefreshToken }).catch(() => {});
    }
  };

  const value = {
    token,
    email,
    role,
    isAuthenticated: Boolean(token),
    isAdmin: role === "admin",
    login,
    register,
    logout,
  };

  return <AuthContext.Provider value={value}>{children}</AuthContext.Provider>;
}

export function useAuth() {
  const context = useContext(AuthContext);
  if (!context) {
    throw new Error("useAuth must be used within an AuthProvider");
  }
  return context;
}
