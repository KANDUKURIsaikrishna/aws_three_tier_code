import { describe, it, expect, vi, beforeEach } from "vitest";
import request from "supertest";
import { createApp } from "../app.js";

const mockQuery = vi.fn();
const mockNotify = vi.fn().mockResolvedValue(undefined);
const app = createApp({ query: mockQuery }, mockNotify);

beforeEach(() => {
  mockQuery.mockReset();
  mockNotify.mockReset();
  mockNotify.mockResolvedValue(undefined);
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
    expect(res.text).toContain('service="order-service"');
  });
});

describe("auth guard (X-User-Id header)", () => {
  it("rejects requests with no X-User-Id header", async () => {
    const res = await request(app).get("/cart");
    expect(res.status).toBe(401);
    expect(res.body).toEqual({ error: "missing X-User-Id header" });
  });

  it("rejects a non-numeric X-User-Id header", async () => {
    const res = await request(app).get("/cart").set("X-User-Id", "not-a-number");
    expect(res.status).toBe(401);
    expect(res.body).toEqual({ error: "missing X-User-Id header" });
  });
});

describe("GET /cart", () => {
  it("returns the caller's cart items", async () => {
    const items = [{ id: 1, book_id: 10, quantity: 2 }];
    mockQuery.mockImplementation((_q, _p, cb) => cb(null, items));

    const res = await request(app).get("/cart").set("X-User-Id", "3");
    expect(res.status).toBe(200);
    expect(res.body).toEqual(items);
  });
});

describe("POST /cart", () => {
  it("adds a new item to the cart", async () => {
    mockQuery.mockImplementation((_q, _p, cb) => cb(null, { insertId: 1, affectedRows: 1 }));

    const res = await request(app)
      .post("/cart")
      .set("X-User-Id", "3")
      .send({ book_id: 10, quantity: 2 });

    expect(res.status).toBe(200);
    expect(res.body).toEqual({ book_id: 10, quantity: 2 });
  });

  it("rejects a missing book_id or quantity", async () => {
    const res = await request(app).post("/cart").set("X-User-Id", "3").send({ book_id: 10 });
    expect(res.status).toBe(400);
    expect(res.body).toEqual({ error: "book_id and quantity are required" });
  });
});

describe("DELETE /cart/:bookId", () => {
  it("removes an item from the cart", async () => {
    mockQuery.mockImplementation((_q, _p, cb) => cb(null, { affectedRows: 1 }));

    const res = await request(app).delete("/cart/10").set("X-User-Id", "3");
    expect(res.status).toBe(200);
    expect(res.body).toEqual({ affectedRows: 1 });
  });
});

describe("POST /orders/checkout", () => {
  it("converts cart items into orders, clears the cart, and notifies", async () => {
    const cartItems = [
      { id: 1, book_id: 10, quantity: 2 },
      { id: 2, book_id: 20, quantity: 1 },
    ];
    mockQuery
      .mockImplementationOnce((_q, _p, cb) => cb(null, cartItems))
      .mockImplementationOnce((_q, _p, cb) => cb(null, { insertId: 100, affectedRows: 1 }))
      .mockImplementationOnce((_q, _p, cb) => cb(null, { insertId: 101, affectedRows: 1 }))
      .mockImplementationOnce((_q, _p, cb) => cb(null, { affectedRows: 2 }));

    const res = await request(app).post("/orders/checkout").set("X-User-Id", "3");

    expect(res.status).toBe(201);
    expect(res.body).toEqual([
      { id: 100, book_id: 10, quantity: 2, status: "pending" },
      { id: 101, book_id: 20, quantity: 1, status: "pending" },
    ]);
    expect(mockNotify).toHaveBeenCalledTimes(2);
  });

  it("returns 400 when the cart is empty", async () => {
    mockQuery.mockImplementationOnce((_q, _p, cb) => cb(null, []));

    const res = await request(app).post("/orders/checkout").set("X-User-Id", "3");
    expect(res.status).toBe(400);
    expect(res.body).toEqual({ error: "cart is empty" });
  });

  it("still returns 201 to the caller even if the notify call fails", async () => {
    const cartItems = [{ id: 1, book_id: 10, quantity: 2 }];
    mockQuery
      .mockImplementationOnce((_q, _p, cb) => cb(null, cartItems))
      .mockImplementationOnce((_q, _p, cb) => cb(null, { insertId: 100, affectedRows: 1 }))
      .mockImplementationOnce((_q, _p, cb) => cb(null, { affectedRows: 1 }));
    mockNotify.mockRejectedValue(new Error("notification-service unreachable"));

    const res = await request(app).post("/orders/checkout").set("X-User-Id", "3");
    expect(res.status).toBe(201);
  });
});

describe("POST /orders (direct, no cart)", () => {
  it("creates a single order directly and notifies", async () => {
    mockQuery.mockImplementation((_q, _p, cb) => cb(null, { insertId: 55, affectedRows: 1 }));

    const res = await request(app)
      .post("/orders")
      .set("X-User-Id", "3")
      .send({ book_id: 99, quantity: 1 });

    expect(res.status).toBe(201);
    expect(res.body).toEqual({ id: 55, book_id: 99, quantity: 1, status: "pending" });
    expect(mockNotify).toHaveBeenCalledTimes(1);
  });

  it("rejects a missing book_id or quantity", async () => {
    const res = await request(app).post("/orders").set("X-User-Id", "3").send({ book_id: 99 });
    expect(res.status).toBe(400);
    expect(res.body).toEqual({ error: "book_id and quantity are required" });
  });
});

describe("GET /orders", () => {
  it("returns only the caller's orders", async () => {
    const orders = [{ id: 55, book_id: 99, quantity: 1, status: "pending" }];
    mockQuery.mockImplementation((_q, _p, cb) => cb(null, orders));

    const res = await request(app).get("/orders").set("X-User-Id", "3");
    expect(res.status).toBe(200);
    expect(res.body).toEqual(orders);
  });
});

describe("GET /orders/:id", () => {
  it("returns a single order belonging to the caller", async () => {
    const order = { id: 55, book_id: 99, quantity: 1, status: "pending" };
    mockQuery.mockImplementation((_q, _p, cb) => cb(null, [order]));

    const res = await request(app).get("/orders/55").set("X-User-Id", "3");
    expect(res.status).toBe(200);
    expect(res.body).toEqual(order);
  });

  it("returns 404 when the order does not exist or belongs to someone else", async () => {
    mockQuery.mockImplementation((_q, _p, cb) => cb(null, []));

    const res = await request(app).get("/orders/999").set("X-User-Id", "3");
    expect(res.status).toBe(404);
    expect(res.body).toEqual({ error: "order not found" });
  });
});
