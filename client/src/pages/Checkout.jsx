import { useEffect, useState } from "react";
import { useNavigate, Link } from "react-router-dom";
import api from "../api/api";
import { joinWithBooks } from "../utils/joinWithBooks";

const Checkout = () => {
  const [items, setItems] = useState([]);
  const [error, setError] = useState("");
  const [placing, setPlacing] = useState(false);
  const [loading, setLoading] = useState(true);
  const navigate = useNavigate();

  useEffect(() => {
    const loadCart = async () => {
      try {
        const [cartRes, booksRes] = await Promise.all([api.get("/cart"), api.get("/books")]);
        setItems(joinWithBooks(cartRes.data, booksRes.data));
      } catch (err) {
        console.log(err.message);
        setError("something went wrong, try again");
      } finally {
        setLoading(false);
      }
    };
    loadCart();
  }, []);

  const total = items.reduce(
    (sum, item) => sum + (item.price ? parseFloat(item.price) * item.quantity : 0),
    0
  );

  const handlePlaceOrder = async () => {
    setError("");
    setPlacing(true);
    try {
      await api.post("/orders/checkout");
      navigate("/orders");
    } catch (err) {
      if (err.response && err.response.status === 400) {
        setError("your cart is empty");
      } else {
        setError("something went wrong, try again");
      }
      setPlacing(false);
    }
  };

  const showEmptyMessage = !loading && items.length === 0 && !error;

  return (
    <div>
      <h1>Checkout</h1>
      {loading && <p>Loading your cart...</p>}
      {error && (
        <p className="error">
          {error}
          {error === "your cart is empty" && (
            <>
              {" "}
              <Link to="/cart">Back to cart</Link>
            </>
          )}
        </p>
      )}
      {showEmptyMessage && (
        <p>
          Your cart is empty. <Link to="/cart">Back to cart</Link>
        </p>
      )}
      <div className="books">
        {items.map((item) => (
          <div key={item.book_id} className="book">
            {item.cover && <img src={item.cover} alt={item.title || "Book cover"} />}
            <h2>{item.title || `Book #${item.book_id}`}</h2>
            <span>
              ${item.price || "?"} x {item.quantity}
            </span>
          </div>
        ))}
      </div>
      {items.length > 0 && <h2>Total: ${total.toFixed(2)}</h2>}
      {!loading && (
        <button className="addHome" onClick={handlePlaceOrder} disabled={placing || items.length === 0}>
          {placing ? "Placing order..." : "Place Order"}
        </button>
      )}
    </div>
  );
};

export default Checkout;
