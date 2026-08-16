import { describe, it, expect, beforeAll, afterAll } from "vitest";
import http from "node:http";
import jwt from "jsonwebtoken";
import request from "supertest";
import { createApp } from "../app.js";

const JWT_SECRET = "test-secret";

function startStubServer(handler) {
  return new Promise((resolve) => {
    const server = http.createServer(handler);
    server.listen(0, "127.0.0.1", () => {
      const { port } = server.address();
      resolve({ server, url: `http://127.0.0.1:${port}` });
    });
  });
}

let catalogStub, userStub, orderStub;
let app;

beforeAll(async () => {
  catalogStub = await startStubServer((req, res) => {
    let body = "";
    req.on("data", (chunk) => (body += chunk));
    req.on("end", () => {
      res.writeHead(200, {
        "Content-Type": "application/json",
        "X-Received-Path": req.url,
        "X-Received-User-Id": req.headers["x-user-id"] || "",
      });
      res.end(JSON.stringify({ from: "catalog-service", method: req.method, body }));
    });
  });

  userStub = await startStubServer((req, res) => {
    res.writeHead(200, {
      "Content-Type": "application/json",
      "X-Received-Path": req.url,
      "X-Received-User-Id": req.headers["x-user-id"] || "",
    });
    res.end(JSON.stringify({ from: "user-service" }));
  });

  orderStub = await startStubServer((req, res) => {
    res.writeHead(200, {
      "Content-Type": "application/json",
      "X-Received-Path": req.url,
      "X-Received-User-Id": req.headers["x-user-id"] || "",
    });
    res.end(JSON.stringify({ from: "order-service" }));
  });

  app = createApp(JWT_SECRET, {
    catalog: catalogStub.url,
    user: userStub.url,
    order: orderStub.url,
  });
});

afterAll(() => {
  catalogStub.server.close();
  userStub.server.close();
  orderStub.server.close();
});

function tokenFor(userId, role = "customer") {
  return jwt.sign({ userId, email: `user${userId}@example.com`, role }, JWT_SECRET, { expiresIn: "1h" });
}

describe("GET /health", () => {
  it("returns ok without proxying anywhere", async () => {
    const res = await request(app).get("/health");
    expect(res.status).toBe(200);
    expect(res.body).toEqual({ status: "ok" });
  });
});

describe("GET /metrics", () => {
  it("exposes service-labeled prometheus metrics", async () => {
    const res = await request(app).get("/metrics");
    expect(res.status).toBe(200);
    expect(res.text).toContain('service="api-gateway"');
  });
});

describe("GET /books (public)", () => {
  it("proxies to catalog-service with no auth required", async () => {
    const res = await request(app).get("/books");
    expect(res.status).toBe(200);
    expect(res.body.from).toBe("catalog-service");
    expect(res.headers["x-received-path"]).toBe("/books");
  });
});

describe("POST /books (any authenticated user)", () => {
  it("rejects with no token", async () => {
    const res = await request(app).post("/books").send({ title: "New" });
    expect(res.status).toBe(401);
  });

  it("proxies for a plain customer token -- adding a book needs no admin role", async () => {
    const res = await request(app)
      .post("/books")
      .set("Authorization", `Bearer ${tokenFor(9, "customer")}`)
      .send({ title: "New" });
    expect(res.status).toBe(200);
    expect(res.body.from).toBe("catalog-service");
    expect(res.headers["x-received-user-id"]).toBe("9");
  });

  it("proxies with a valid admin token and injects X-User-Id", async () => {
    const res = await request(app)
      .post("/books")
      .set("Authorization", `Bearer ${tokenFor(9, "admin")}`)
      .send({ title: "New" });
    expect(res.status).toBe(200);
    expect(res.body.from).toBe("catalog-service");
    expect(res.headers["x-received-user-id"]).toBe("9");
  });
});

describe("PUT/DELETE /books (admin only)", () => {
  it("rejects PUT with no token", async () => {
    const res = await request(app).put("/books/1").send({ title: "Edited" });
    expect(res.status).toBe(401);
  });

  it("rejects PUT from a plain customer token", async () => {
    const res = await request(app)
      .put("/books/1")
      .set("Authorization", `Bearer ${tokenFor(9, "customer")}`)
      .send({ title: "Edited" });
    expect(res.status).toBe(403);
    expect(res.body).toEqual({ error: "admin role required" });
  });

  it("proxies PUT with a valid admin token", async () => {
    const res = await request(app)
      .put("/books/1")
      .set("Authorization", `Bearer ${tokenFor(9, "admin")}`)
      .send({ title: "Edited" });
    expect(res.status).toBe(200);
    expect(res.body.from).toBe("catalog-service");
  });

  it("rejects DELETE from a plain customer token", async () => {
    const res = await request(app)
      .delete("/books/1")
      .set("Authorization", `Bearer ${tokenFor(9, "customer")}`);
    expect(res.status).toBe(403);
    expect(res.body).toEqual({ error: "admin role required" });
  });

  it("proxies DELETE with a valid admin token", async () => {
    const res = await request(app)
      .delete("/books/1")
      .set("Authorization", `Bearer ${tokenFor(9, "admin")}`);
    expect(res.status).toBe(200);
    expect(res.body.from).toBe("catalog-service");
  });
});

describe("POST /auth/register and /auth/login (public)", () => {
  it("proxies /auth/register to user-service with no auth required", async () => {
    const res = await request(app).post("/auth/register").send({ email: "a@b.com", password: "x" });
    expect(res.status).toBe(200);
    expect(res.body.from).toBe("user-service");
  });

  it("proxies /auth/login to user-service with no auth required", async () => {
    const res = await request(app).post("/auth/login").send({ email: "a@b.com", password: "x" });
    expect(res.status).toBe(200);
    expect(res.body.from).toBe("user-service");
  });
});

describe("GET /users/me (protected)", () => {
  it("rejects with no token", async () => {
    const res = await request(app).get("/users/me");
    expect(res.status).toBe(401);
  });

  it("proxies with a valid token and injects X-User-Id", async () => {
    const res = await request(app).get("/users/me").set("Authorization", `Bearer ${tokenFor(4)}`);
    expect(res.status).toBe(200);
    expect(res.body.from).toBe("user-service");
    expect(res.headers["x-received-user-id"]).toBe("4");
  });
});

describe("/orders and /cart (protected)", () => {
  it("rejects GET /orders with no token", async () => {
    const res = await request(app).get("/orders");
    expect(res.status).toBe(401);
  });

  it("proxies GET /orders with a valid token and injects X-User-Id", async () => {
    const res = await request(app).get("/orders").set("Authorization", `Bearer ${tokenFor(6)}`);
    expect(res.status).toBe(200);
    expect(res.body.from).toBe("order-service");
    expect(res.headers["x-received-user-id"]).toBe("6");
  });

  it("rejects POST /cart with no token", async () => {
    const res = await request(app).post("/cart").send({ book_id: 1, quantity: 1 });
    expect(res.status).toBe(401);
  });

  it("proxies POST /cart with a valid token and injects X-User-Id", async () => {
    const res = await request(app)
      .post("/cart")
      .set("Authorization", `Bearer ${tokenFor(6)}`)
      .send({ book_id: 1, quantity: 1 });
    expect(res.status).toBe(200);
    expect(res.body.from).toBe("order-service");
    expect(res.headers["x-received-user-id"]).toBe("6");
  });
});

describe("invalid token handling", () => {
  it("rejects a malformed token on a protected route", async () => {
    const res = await request(app).get("/users/me").set("Authorization", "Bearer not-a-real-token");
    expect(res.status).toBe(401);
  });
});

describe("GET /metrics label cardinality", () => {
  it("collapses a parameterized path to its known route prefix instead of a raw label", async () => {
    await request(app).get("/books/123");
    const res = await request(app).get("/metrics");
    expect(res.status).toBe(200);
    expect(res.text).not.toContain('route="/books/123"');
    expect(res.text).toContain('route="/books"');
  });
});
