import { createContext, useContext, useState } from "react";
import api from "../api/api";

const AuthContext = createContext(null);

export function AuthProvider({ children }) {
  const [token, setToken] = useState(() => localStorage.getItem("bookstore_token"));
  const [email, setEmail] = useState(() => localStorage.getItem("bookstore_email"));

  const login = async (loginEmail, password) => {
    const res = await api.post("/auth/login", { email: loginEmail, password });
    localStorage.setItem("bookstore_token", res.data.token);
    localStorage.setItem("bookstore_email", loginEmail);
    setToken(res.data.token);
    setEmail(loginEmail);
  };

  // /auth/register returns {id, email}, not a token -- the caller (Register
  // page) sends the user to /login afterwards, it does not log them in.
  const register = async (registerEmail, password) => {
    await api.post("/auth/register", { email: registerEmail, password });
  };

  const logout = () => {
    localStorage.removeItem("bookstore_token");
    localStorage.removeItem("bookstore_email");
    setToken(null);
    setEmail(null);
  };

  const value = {
    token,
    email,
    isAuthenticated: Boolean(token),
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
