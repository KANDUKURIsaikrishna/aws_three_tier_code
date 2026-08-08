import axios from "axios";
import API_BASE_URL from "../pages/config";

// Exported separately from the axios instance so each can be unit-tested
// directly without needing a real HTTP call.
export function attachAuthHeader(config) {
  const token = localStorage.getItem("bookstore_token");
  if (token) {
    config.headers = config.headers || {};
    config.headers.Authorization = `Bearer ${token}`;
  }
  return config;
}

// A 401 from /auth/login or /auth/register means "wrong credentials" /
// "bad input" -- an expected, user-facing error the calling page (Login.jsx,
// via AuthContext's login()) needs to catch and display. Only a 401 from
// every OTHER endpoint means "the stored session expired," which is what
// should trigger the clear-and-redirect. Without this check, a failed login
// attempt would bounce straight to /login before the page's own catch block
// ever got to show "invalid email or password."
export function handleAuthError(error) {
  const url = (error.config && error.config.url) || "";
  const isAuthEndpoint = url.includes("/auth/login") || url.includes("/auth/register");
  if (error.response && error.response.status === 401 && !isAuthEndpoint) {
    localStorage.removeItem("bookstore_token");
    localStorage.removeItem("bookstore_email");
    window.location.href = "/login";
  }
  return Promise.reject(error);
}

const api = axios.create({ baseURL: API_BASE_URL });

api.interceptors.request.use(attachAuthHeader);
api.interceptors.response.use((response) => response, handleAuthError);

export default api;
