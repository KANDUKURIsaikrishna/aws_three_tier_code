import { describe, it, expect, vi, beforeEach } from "vitest";
import request from "supertest";
import { createApp } from "../app.js";

const mockQuery = vi.fn();
const app = createApp({ query: mockQuery });

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
    expect(res.text).toContain('service="notification-service"');
  });
});

describe("POST /notify", () => {
  it("logs a notification and returns 201", async () => {
    mockQuery.mockImplementation((_q, _p, cb) => cb(null, { insertId: 1, affectedRows: 1 }));

    const res = await request(app)
      .post("/notify")
      .send({ order_id: 42, channel: "email", message: "Your order shipped" });

    expect(res.status).toBe(201);
    expect(res.body).toEqual({ id: 1, order_id: 42, channel: "email", status: "sent" });
  });

  it("rejects a request missing order_id or channel", async () => {
    const res = await request(app).post("/notify").send({ message: "no order_id or channel" });
    expect(res.status).toBe(400);
    expect(res.body).toEqual({ error: "order_id and channel are required" });
  });
});
