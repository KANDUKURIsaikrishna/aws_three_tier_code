import { useEffect, useState } from "react";
import { useNavigate } from "react-router-dom";
import api from "../api/api";
import { joinWithBooks } from "../utils/joinWithBooks";

const Cart = () => {
  const [items, setItems] = useState([]);
  const [error, setError] = useState("");
  const navigate = useNavigate();

  const loadCart = async () => {
    try {
      const [cartRes, booksRes] = await Promise.all([api.get("/cart"), api.get("/books")]);
      setItems(joinWithBooks(cartRes.data, booksRes.data));
    } catch (err) {
      console.log(err);
      setError("something went wrong, try again");
    }
  };

  useEffect(() => {
    loadCart();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const handleQuantityChange = async (bookId, rawQuantity) => {
    const quantity = parseInt(rawQuantity, 10);
    if (!Number.isInteger(quantity) || quantity <= 0) return;
    try {
      await api.post("/cart", { book_id: bookId, quantity });
      loadCart();
    } catch (err) {
      console.log(err);
      setError("something went wrong, try again");
    }
  };

  const handleRemove = async (bookId) => {
    try {
      await api.delete(`/cart/${bookId}`);
      loadCart();
    } catch (err) {
      console.log(err);
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
            {item.cover && <img src={item.cover} alt="" />}
            <h2>{item.title || `Book #${item.book_id}`}</h2>
            <span>${item.price || "?"}</span>
            <input
              type="number"
              min="1"
              value={item.quantity}
              onChange={(e) => handleQuantityChange(item.book_id, e.target.value)}
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
