import { describe, it, expect, vi, beforeEach } from "vitest";
import request from "supertest";
import jwt from "jsonwebtoken";
import { createApp } from "../app.js";

const JWT_SECRET = "test-secret";
const mockQuery = vi.fn();
const app = createApp({ query: mockQuery }, JWT_SECRET);

beforeEach(() => {
  mockQuery.mockReset();
});

describe("GET /health", () => {
  it("returns ok", async () => {
    const res = await request(app).get("/health");
    expect(res.status).toBe(200);
    expect(res.body).toEqual({ status: "ok" });
  });
});

describe("GET /metrics", () => {
  it("exposes service-labeled prometheus metrics", async () => {
    const res = await request(app).get("/metrics");
    expect(res.status).toBe(200);
    expect(res.text).toContain('service="user-service"');
  });
});

describe("POST /auth/register", () => {
  it("creates a user and returns 201 with no password fields", async () => {
    mockQuery.mockImplementationOnce((_q, _p, cb) => cb(null, [])); // SELECT id FROM users WHERE email
    mockQuery.mockImplementationOnce((_q, cb) => cb(null, [{ count: 3 }])); // SELECT COUNT(*) FROM users
    mockQuery.mockImplementationOnce((_q, _p, cb) => cb(null, { insertId: 1, affectedRows: 1 })); // INSERT

    const res = await request(app)
      .post("/auth/register")
      .send({ email: "new@example.com", password: "hunter22" });

    expect(res.status).toBe(201);
    expect(res.body).toEqual({ id: 1, email: "new@example.com", role: "customer" });
    expect(res.body.password).toBeUndefined();
    expect(res.body.password_hash).toBeUndefined();
  });

  it("makes the very first registered user an admin", async () => {
    mockQuery.mockImplementationOnce((_q, _p, cb) => cb(null, [])); // SELECT id FROM users WHERE email
    mockQuery.mockImplementationOnce((_q, cb) => cb(null, [{ count: 0 }])); // SELECT COUNT(*) FROM users
    mockQuery.mockImplementationOnce((_q, _p, cb) => cb(null, { insertId: 1, affectedRows: 1 })); // INSERT

    const res = await request(app)
      .post("/auth/register")
      .send({ email: "first@example.com", password: "hunter22" });

    expect(res.status).toBe(201);
    expect(res.body).toEqual({ id: 1, email: "first@example.com", role: "admin" });
  });

  it("rejects registration when the email is already taken", async () => {
    mockQuery.mockImplementationOnce((_q, _p, cb) =>
      cb(null, [{ id: 5, email: "taken@example.com" }])
    );

    const res = await request(app)
      .post("/auth/register")
      .send({ email: "taken@example.com", password: "hunter22" });

    expect(res.status).toBe(409);
    expect(res.body).toEqual({ error: "email already registered" });
  });

  it("rejects registration with a missing email or password", async () => {
    const res = await request(app).post("/auth/register").send({ email: "only@example.com" });
    expect(res.status).toBe(400);
    expect(res.body).toEqual({ error: "email and password are required" });
  });

  it("rejects registration when password is a non-string (object) instead of crashing", async () => {
    const res = await request(app)
      .post("/auth/register")
      .send({ email: "x@example.com", password: { weird: "object" } });

    expect(res.status).toBe(400);
    expect(res.body).toEqual({ error: "email and password are required" });
  });
});

describe("POST /auth/login", () => {
  it("returns a valid access token and a refresh token for correct credentials", async () => {
    const bcrypt = await import("bcryptjs");
    const hash = await bcrypt.hash("hunter22", 10);
    mockQuery.mockImplementationOnce((_q, _p, cb) =>
      cb(null, [{ id: 7, email: "user@example.com", password_hash: hash }])
    );
    // Second call: INSERT INTO refresh_tokens.
    mockQuery.mockImplementationOnce((_q, _p, cb) => cb(null, { insertId: 1, affectedRows: 1 }));

    const res = await request(app)
      .post("/auth/login")
      .send({ email: "user@example.com", password: "hunter22" });

    expect(res.status).toBe(200);
    expect(typeof res.body.token).toBe("string");
    expect(typeof res.body.refreshToken).toBe("string");
    // 48 random bytes, hex-encoded -- 96 hex characters.
    expect(res.body.refreshToken).toHaveLength(96);

    const decoded = jwt.verify(res.body.token, JWT_SECRET);
    expect(decoded.userId).toBe(7);
    expect(decoded.email).toBe("user@example.com");
    // Short-lived now, not the old 1h -- `exp - iat` should be 15 minutes.
    expect(decoded.exp - decoded.iat).toBe(15 * 60);
  });

  it("returns 401 for a wrong password", async () => {
    const bcrypt = await import("bcryptjs");
    const hash = await bcrypt.hash("correct-password", 10);
    mockQuery.mockImplementationOnce((_q, _p, cb) =>
      cb(null, [{ id: 7, email: "user@example.com", password_hash: hash }])
    );

    const res = await request(app)
      .post("/auth/login")
      .send({ email: "user@example.com", password: "wrong-password" });

    expect(res.status).toBe(401);
    expect(res.body).toEqual({ error: "invalid email or password" });
  });

  it("returns 401 when the email does not exist", async () => {
    mockQuery.mockImplementationOnce((_q, _p, cb) => cb(null, []));

    const res = await request(app)
      .post("/auth/login")
      .send({ email: "nobody@example.com", password: "anything" });

    expect(res.status).toBe(401);
    expect(res.body).toEqual({ error: "invalid email or password" });
  });
});

describe("GET /users/me", () => {
  it("returns the caller's profile for a valid token", async () => {
    const token = jwt.sign({ userId: 3, email: "me@example.com" }, JWT_SECRET, { expiresIn: "1h" });
    mockQuery.mockImplementationOnce((_q, _p, cb) =>
      cb(null, [{ id: 3, email: "me@example.com", created_at: "2026-01-01T00:00:00.000Z" }])
    );

    const res = await request(app).get("/users/me").set("Authorization", `Bearer ${token}`);

    expect(res.status).toBe(200);
    expect(res.body).toEqual({ id: 3, email: "me@example.com", created_at: "2026-01-01T00:00:00.000Z" });
  });

  it("returns 401 with no Authorization header", async () => {
    const res = await request(app).get("/users/me");
    expect(res.status).toBe(401);
    expect(res.body).toEqual({ error: "missing or invalid Authorization header" });
  });

  it("returns 401 for an invalid token", async () => {
    const res = await request(app).get("/users/me").set("Authorization", "Bearer not-a-real-token");
    expect(res.status).toBe(401);
    expect(res.body).toEqual({ error: "invalid or expired token" });
  });
});

describe("POST /auth/refresh", () => {
  it("rejects a request with no refreshToken", async () => {
    const res = await request(app).post("/auth/refresh").send({});
    expect(res.status).toBe(400);
    expect(res.body).toEqual({ error: "refreshToken is required" });
  });

  it("returns 401 when the refresh token isn't found, is revoked, or is expired", async () => {
    mockQuery.mockImplementationOnce((_q, _p, cb) => cb(null, []));

    const res = await request(app).post("/auth/refresh").send({ refreshToken: "not-a-real-token" });

    expect(res.status).toBe(401);
    expect(res.body).toEqual({ error: "invalid or expired refresh token" });
  });

  it("returns 401 when the token is valid but its user no longer exists", async () => {
    mockQuery.mockImplementationOnce((_q, _p, cb) => cb(null, [{ id: 1, user_id: 7 }]));
    mockQuery.mockImplementationOnce((_q, _p, cb) => cb(null, []));

    const res = await request(app).post("/auth/refresh").send({ refreshToken: "some-refresh-token" });

    expect(res.status).toBe(401);
    expect(res.body).toEqual({ error: "invalid or expired refresh token" });
  });

  it("rotates the refresh token and issues a new access token on success", async () => {
    // 1: SELECT refresh_tokens, 2: SELECT users, 3: UPDATE revoke old row,
    // 4: INSERT new refresh_tokens row -- in that order.
    mockQuery.mockImplementationOnce((_q, _p, cb) => cb(null, [{ id: 1, user_id: 7 }]));
    mockQuery.mockImplementationOnce((_q, _p, cb) =>
      cb(null, [{ id: 7, email: "user@example.com" }])
    );
    mockQuery.mockImplementationOnce((_q, _p, cb) => cb(null, { affectedRows: 1 }));
    mockQuery.mockImplementationOnce((_q, _p, cb) => cb(null, { insertId: 2, affectedRows: 1 }));

    const res = await request(app)
      .post("/auth/refresh")
      .send({ refreshToken: "the-old-refresh-token" });

    expect(res.status).toBe(200);
    expect(typeof res.body.token).toBe("string");
    expect(typeof res.body.refreshToken).toBe("string");
    // A fresh token, not an echo of the one that was sent in.
    expect(res.body.refreshToken).not.toBe("the-old-refresh-token");

    const decoded = jwt.verify(res.body.token, JWT_SECRET);
    expect(decoded.userId).toBe(7);
    expect(decoded.email).toBe("user@example.com");

    // The 3rd call is the UPDATE that revokes the just-used row.
    expect(mockQuery.mock.calls[2][0]).toMatch(/UPDATE refresh_tokens SET revoked_at/);
    expect(mockQuery.mock.calls[2][1]).toEqual([1]);
  });
});

describe("POST /auth/logout", () => {
  it("returns success without touching the database when no refreshToken is given", async () => {
    const res = await request(app).post("/auth/logout").send({});
    expect(res.status).toBe(200);
    expect(res.body).toEqual({ success: true });
    expect(mockQuery).not.toHaveBeenCalled();
  });

  it("revokes the matching refresh token and returns success", async () => {
    mockQuery.mockImplementationOnce((_q, _p, cb) => cb(null, { affectedRows: 1 }));

    const res = await request(app).post("/auth/logout").send({ refreshToken: "a-real-token" });

    expect(res.status).toBe(200);
    expect(res.body).toEqual({ success: true });
    expect(mockQuery.mock.calls[0][0]).toMatch(/UPDATE refresh_tokens SET revoked_at/);
  });

  it("returns success even when the given refreshToken never existed", async () => {
    // affectedRows: 0 -- no row matched, still not an error to the caller.
    mockQuery.mockImplementationOnce((_q, _p, cb) => cb(null, { affectedRows: 0 }));

    const res = await request(app).post("/auth/logout").send({ refreshToken: "never-issued" });

    expect(res.status).toBe(200);
    expect(res.body).toEqual({ success: true });
  });
});
