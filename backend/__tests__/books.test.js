import { describe, it, expect, vi, beforeEach } from "vitest";
import request from "supertest";
import { createApp } from "../app.js";

const mockQuery = vi.fn();
const app = createApp({ query: mockQuery });

beforeEach(() => {
  mockQuery.mockReset();
});

describe("GET /", () => {
  it("returns hello", async () => {
    const res = await request(app).get("/");
    expect(res.status).toBe(200);
    expect(res.body).toBe("hello");
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

describe("POST /books", () => {
  it("inserts a book and returns insert result", async () => {
    const result = { insertId: 5, affectedRows: 1 };
    mockQuery.mockImplementation((_q, _v, cb) => cb(null, result));

    const res = await request(app)
      .post("/books")
      .send({ title: "New", desc: "A book", price: 12.99, cover: "http://img" });
    expect(res.status).toBe(200);
    expect(res.body).toEqual(result);
  });
});

describe("DELETE /books/:id", () => {
  it("deletes a book by id", async () => {
    const result = { affectedRows: 1 };
    mockQuery.mockImplementation((_q, _p, cb) => cb(null, result));

    const res = await request(app).delete("/books/1");
    expect(res.status).toBe(200);
    expect(res.body).toEqual(result);
  });
});

describe("PUT /books/:id", () => {
  it("updates a book by id", async () => {
    const result = { affectedRows: 1 };
    mockQuery.mockImplementation((_q, _p, cb) => cb(null, result));

    const res = await request(app)
      .put("/books/1")
      .send({ title: "Updated", desc: "Updated desc", price: 15.99, cover: "http://newimg" });
    expect(res.status).toBe(200);
    expect(res.body).toEqual(result);
  });
});
