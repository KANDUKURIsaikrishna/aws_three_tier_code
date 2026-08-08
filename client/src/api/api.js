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

export function handleAuthError(error) {
  if (error.response && error.response.status === 401) {
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
