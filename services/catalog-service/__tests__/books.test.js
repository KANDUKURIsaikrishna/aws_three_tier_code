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
    expect(res.text).toContain('service="catalog-service"');
  });
});

describe("GET /books", () => {
  it("returns book list", async () => {
    const books = [{ id: 1, title: "Test", desc: "Desc", price: 9.99, cover: "url" }];
    mockQuery.mockImplementation((_q, cb) => cb(null, books));

    const res = await request(app).get("/books");
    expect(res.status).toBe(200);
    expect(res.body).toEqual(books);
  });

  it("returns empty array when no books", async () => {
    mockQuery.mockImplementation((_q, cb) => cb(null, []));
    const res = await request(app).get("/books");
    expect(res.body).toEqual([]);
  });
});

describe("GET /books/:id", () => {
  it("returns a single book by id", async () => {
    const book = { id: 1, title: "Test", desc: "Desc", price: 9.99, cover: "url" };
    mockQuery.mockImplementation((_q, _p, cb) => cb(null, [book]));

    const res = await request(app).get("/books/1");
    expect(res.status).toBe(200);
    expect(res.body).toEqual(book);
    expect(mockQuery).toHaveBeenCalledWith(
      "SELECT * FROM books WHERE id = ?",
      ["1"],
      expect.any(Function)
    );
  });

  it("returns 404 when the book does not exist", async () => {
    mockQuery.mockImplementation((_q, _p, cb) => cb(null, []));

    const res = await request(app).get("/books/999");
    expect(res.status).toBe(404);
    expect(res.body).toEqual({ error: "Book not found" });
  });
});

describe("POST /books", () => {
  it("allows a plain customer caller -- adding a book needs no admin role", async () => {
    const result = { insertId: 6, affectedRows: 1 };
    mockQuery.mockImplementation((_q, _v, cb) => cb(null, result));

    const res = await request(app)
      .post("/books")
      .set("x-user-role", "customer")
      .send({ title: "New", desc: "A book", price: 12.99, cover: "http://img" });
    expect(res.status).toBe(200);
    expect(res.body).toEqual(result);
  });

  it("inserts a book and returns insert result", async () => {
    const result = { insertId: 5, affectedRows: 1 };
    mockQuery.mockImplementation((_q, _v, cb) => cb(null, result));

    const res = await request(app)
      .post("/books")
      .set("x-user-role", "admin")
      .send({ title: "New", desc: "A book", price: 12.99, cover: "http://img" });
    expect(res.status).toBe(200);
    expect(res.body).toEqual(result);
    expect(mockQuery).toHaveBeenCalledWith(
      "INSERT INTO books(`title`, `desc`, `price`, `cover`) VALUES (?)",
      [["New", "A book", 12.99, "http://img"]],
      expect.any(Function)
    );
  });
});

describe("DELETE /books/:id", () => {
  it("rejects a non-admin caller", async () => {
    const res = await request(app).delete("/books/1").set("x-user-role", "customer");
    expect(res.status).toBe(403);
    expect(res.body).toEqual({ error: "admin role required" });
  });

  it("deletes a book by id", async () => {
    const result = { affectedRows: 1 };
    mockQuery.mockImplementation((_q, _p, cb) => cb(null, result));

    const res = await request(app).delete("/books/1").set("x-user-role", "admin");
    expect(res.status).toBe(200);
    expect(res.body).toEqual(result);
  });
});

describe("PUT /books/:id", () => {
  it("rejects a non-admin caller", async () => {
    const res = await request(app)
      .put("/books/1")
      .set("x-user-role", "customer")
      .send({ title: "Updated", desc: "Updated desc", price: 15.99, cover: "http://newimg" });
    expect(res.status).toBe(403);
    expect(res.body).toEqual({ error: "admin role required" });
  });

  it("updates a book by id", async () => {
    const result = { affectedRows: 1 };
    mockQuery.mockImplementation((_q, _p, cb) => cb(null, result));

    const res = await request(app)
      .put("/books/1")
      .set("x-user-role", "admin")
      .send({ title: "Updated", desc: "Updated desc", price: 15.99, cover: "http://newimg" });
    expect(res.status).toBe(200);
    expect(res.body).toEqual(result);
    expect(mockQuery).toHaveBeenCalledWith(
      "UPDATE books SET `title`= ?, `desc`= ?, `price`= ?, `cover`= ? WHERE id = ?",
      ["Updated", "Updated desc", 15.99, "http://newimg", "1"],
      expect.any(Function)
    );
  });
});
