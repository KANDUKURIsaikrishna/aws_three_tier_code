import { useEffect, useState } from "react";
import api from "../api/api";
import { joinWithBooks } from "../utils/joinWithBooks";

const Orders = () => {
  const [orders, setOrders] = useState([]);
  const [error, setError] = useState("");

  useEffect(() => {
    const loadOrders = async () => {
      try {
        const [ordersRes, booksRes] = await Promise.all([api.get("/orders"), api.get("/books")]);
        setOrders(joinWithBooks(ordersRes.data, booksRes.data));
      } catch (err) {
        console.log(err.message);
        setError("something went wrong, try again");
      }
    };
    loadOrders();
  }, []);

  return (
    <div>
      <h1>Your Orders</h1>
      {error && <p className="error">{error}</p>}
      {orders.length === 0 && !error && <p>You haven't placed any orders yet.</p>}
      <div className="books">
        {orders.map((order) => (
          <div key={order.id} className="book">
            {order.cover && <img src={order.cover} alt={order.title || "Book cover"} />}
            <h2>{order.title || `Book #${order.book_id}`}</h2>
            <span>
              ${order.price || "?"} x {order.quantity}
            </span>
            <span className="status">{order.status}</span>
          </div>
        ))}
      </div>
    </div>
  );
};

export default Orders;
