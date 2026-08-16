import { useEffect, useState } from "react";
import { useNavigate } from "react-router-dom";
import api from "../api/api";
import { joinWithBooks } from "../utils/joinWithBooks";

const Cart = () => {
  const [items, setItems] = useState([]);
  const [error, setError] = useState("");
  // Draft quantities keyed by book_id, keyed separately from `items` so
  // typing a multi-digit value (e.g. "1" then "0" for "10") updates the
  // input instantly and locally instead of firing a POST per keystroke and
  // letting the server-derived `item.quantity` fight the user's cursor
  // mid-edit. Only committed (POST + reload) on blur.
  const [draftQuantities, setDraftQuantities] = useState({});
  const navigate = useNavigate();

  const loadCart = async () => {
    try {
      const [cartRes, booksRes] = await Promise.all([api.get("/cart"), api.get("/books")]);
      const joined = joinWithBooks(cartRes.data, booksRes.data);
      setItems(joined);
      setDraftQuantities(
        Object.fromEntries(joined.map((item) => [item.book_id, String(item.quantity)]))
      );
    } catch (err) {
      console.log(err.message);
      setError("something went wrong, try again");
    }
  };

  useEffect(() => {
    loadCart();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const handleDraftChange = (bookId, rawQuantity) => {
    setDraftQuantities((prev) => ({ ...prev, [bookId]: rawQuantity }));
  };

  const commitQuantity = async (bookId, rawQuantity) => {
    const quantity = parseInt(rawQuantity, 10);
    if (!Number.isInteger(quantity) || quantity <= 0) {
      // Invalid draft (empty, 0, negative) -- revert the input to the last
      // known-good server value instead of sending a bad request.
      const current = items.find((item) => item.book_id === bookId);
      if (current) {
        setDraftQuantities((prev) => ({ ...prev, [bookId]: String(current.quantity) }));
      }
      return;
    }
    try {
      await api.post("/cart", { book_id: bookId, quantity });
      loadCart();
    } catch (err) {
      console.log(err.message);
      setError("something went wrong, try again");
    }
  };

  const handleRemove = async (bookId) => {
    try {
      await api.delete(`/cart/${bookId}`);
      loadCart();
    } catch (err) {
      console.log(err.message);
      setError("something went wrong, try again");
    }
  };

  const total = items.reduce(
    (sum, item) => sum + (item.price ? parseFloat(item.price) * item.quantity : 0),
    0
  );

  return (
    <div>
      <h1>Your Cart</h1>
      {error && <p className="error">{error}</p>}
      {items.length === 0 && !error && <p>Your cart is empty.</p>}
      <div className="books">
        {items.map((item) => (
          <div key={item.book_id} className="book">
            {item.cover && <img src={item.cover} alt={item.title || "Book cover"} />}
            <h2>{item.title || `Book #${item.book_id}`}</h2>
            <span>${item.price || "?"}</span>
            <input
              type="number"
              min="1"
              value={draftQuantities[item.book_id] ?? item.quantity}
              onChange={(e) => handleDraftChange(item.book_id, e.target.value)}
              onBlur={(e) => commitQuantity(item.book_id, e.target.value)}
            />
            <button className="delete" onClick={() => handleRemove(item.book_id)}>
              Remove
            </button>
          </div>
        ))}
      </div>
      {items.length > 0 && (
        <>
          <h2>Total: ${total.toFixed(2)}</h2>
          <button className="addHome" onClick={() => navigate("/checkout")}>
            Proceed to Checkout
          </button>
        </>
      )}
    </div>
  );
};

export default Cart;
