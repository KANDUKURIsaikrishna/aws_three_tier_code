import { joinWithBooks } from "./joinWithBooks";

describe("joinWithBooks", () => {
  const books = [
    { id: 1, title: "Book One", price: "9.99", cover: "cover1.jpg" },
    { id: 2, title: "Book Two", price: "14.99", cover: "cover2.jpg" },
  ];

  test("joins matching items with their book's title/price/cover", () => {
    const items = [{ book_id: 1, quantity: 2 }];
    expect(joinWithBooks(items, books)).toEqual([
      { book_id: 1, quantity: 2, title: "Book One", price: "9.99", cover: "cover1.jpg" },
    ]);
  });

  test("preserves extra fields already on the item, e.g. order status", () => {
    const items = [{ book_id: 2, quantity: 1, status: "pending" }];
    const [result] = joinWithBooks(items, books);
    expect(result.status).toBe("pending");
    expect(result.title).toBe("Book Two");
  });

  test("fills in null title/price/cover when the book no longer exists", () => {
    const items = [{ book_id: 999, quantity: 1 }];
    const [result] = joinWithBooks(items, books);
    expect(result.book_id).toBe(999);
    expect(result.title).toBeNull();
    expect(result.price).toBeNull();
    expect(result.cover).toBeNull();
  });

  test("returns an empty array for an empty item list", () => {
    expect(joinWithBooks([], books)).toEqual([]);
  });
});
