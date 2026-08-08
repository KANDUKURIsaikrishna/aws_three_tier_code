// order-service's /cart and /orders responses only carry book_id/quantity
// (+status for orders) -- no title/price/cover. This joins them against a
// /books response (catalog-service, via the gateway) client-side, since
// order-service deliberately doesn't denormalize catalog data.
export function joinWithBooks(items, books) {
  const bookById = new Map(books.map((book) => [book.id, book]));
  return items.map((item) => {
    const book = bookById.get(item.book_id);
    return {
      ...item,
      title: book ? book.title : null,
      price: book ? book.price : null,
      cover: book ? book.cover : null,
    };
  });
}
