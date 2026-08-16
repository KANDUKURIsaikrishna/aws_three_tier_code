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

const AUTH_ENDPOINTS = ["/auth/login", "/auth/register", "/auth/refresh"];

function isAuthEndpoint(url) {
  return AUTH_ENDPOINTS.some((endpoint) => url.includes(endpoint));
}

export function clearSession() {
  localStorage.removeItem("bookstore_token");
  localStorage.removeItem("bookstore_refresh_token");
  localStorage.removeItem("bookstore_email");
  localStorage.removeItem("bookstore_role");
}

// Dedupe concurrent refresh attempts. Several requests can 401 around the
// same moment (e.g. a burst of parallel calls right as the access token
// expires); without this, each one would independently call /auth/refresh.
// Since user-service rotates the refresh token on every use (the old one is
// revoked, a new one issued), a second concurrent call would revoke the
// first call's brand-new token before it was ever used -- resettable so
// tests can clear it between cases.
let refreshPromise = null;
export function resetRefreshState() {
  refreshPromise = null;
}

function refreshAccessToken() {
  if (!refreshPromise) {
    const storedRefreshToken = localStorage.getItem("bookstore_refresh_token");
    if (!storedRefreshToken) {
      return Promise.reject(new Error("no refresh token stored"));
    }
    refreshPromise = axios
      .post(`${API_BASE_URL}/auth/refresh`, { refreshToken: storedRefreshToken })
      .then((res) => {
        localStorage.setItem("bookstore_token", res.data.token);
        localStorage.setItem("bookstore_refresh_token", res.data.refreshToken);
        localStorage.setItem("bookstore_role", res.data.role);
        return res.data.token;
      })
      .finally(() => {
        refreshPromise = null;
      });
  }
  return refreshPromise;
}

// A 401 from /auth/login, /auth/register, or /auth/refresh itself means
// "wrong credentials" / "bad or expired refresh token" -- an expected,
// user-facing error the calling page needs to catch and display, not a
// session to silently recover from. A 401 from every OTHER endpoint means
// the access token expired -- that now gets exactly one silent retry via
// the refresh token before falling back to clearing the session and
// redirecting to /login. `_retriedAfterRefresh` guards against retrying
// forever if the newly-refreshed token somehow still gets rejected.
export function handleAuthError(error) {
  const originalRequest = error.config || {};
  const url = originalRequest.url || "";

  if (!error.response || error.response.status !== 401 || isAuthEndpoint(url)) {
    return Promise.reject(error);
  }

  if (originalRequest._retriedAfterRefresh) {
    clearSession();
    window.location.href = "/login";
    return Promise.reject(error);
  }

  return refreshAccessToken()
    .then((newAccessToken) => {
      originalRequest._retriedAfterRefresh = true;
      originalRequest.headers = originalRequest.headers || {};
      originalRequest.headers.Authorization = `Bearer ${newAccessToken}`;
      return api.request(originalRequest);
    })
    .catch((refreshError) => {
      clearSession();
      window.location.href = "/login";
      return Promise.reject(refreshError);
    });
}

const api = axios.create({ baseURL: API_BASE_URL });

api.interceptors.request.use(attachAuthHeader);
api.interceptors.response.use((response) => response, handleAuthError);

export default api;
