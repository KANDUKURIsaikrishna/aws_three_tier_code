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
    mockQuery.mockImplementationOnce((_q, _p, cb) => cb(null, []));
    mockQuery.mockImplementationOnce((_q, _p, cb) => cb(null, { insertId: 1, affectedRows: 1 }));

    const res = await request(app)
      .post("/auth/register")
      .send({ email: "new@example.com", password: "hunter22" });

    expect(res.status).toBe(201);
    expect(res.body).toEqual({ id: 1, email: "new@example.com" });
    expect(res.body.password).toBeUndefined();
    expect(res.body.password_hash).toBeUndefined();
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
});

describe("POST /auth/login", () => {
  it("returns a valid JWT for correct credentials", async () => {
    const bcrypt = await import("bcryptjs");
    const hash = await bcrypt.hash("hunter22", 10);
    mockQuery.mockImplementationOnce((_q, _p, cb) =>
      cb(null, [{ id: 7, email: "user@example.com", password_hash: hash }])
    );

    const res = await request(app)
      .post("/auth/login")
      .send({ email: "user@example.com", password: "hunter22" });

    expect(res.status).toBe(200);
    expect(typeof res.body.token).toBe("string");

    const decoded = jwt.verify(res.body.token, JWT_SECRET);
    expect(decoded.userId).toBe(7);
    expect(decoded.email).toBe("user@example.com");
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
