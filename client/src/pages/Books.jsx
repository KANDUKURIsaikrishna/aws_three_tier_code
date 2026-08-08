import React from "react";
import { useEffect } from "react";
import { useState } from "react";
import { Link, useNavigate } from "react-router-dom";
import api from "../api/api";
import { useAuth } from "../context/AuthContext";

const Books = () => {
  const [books, setBooks] = useState([]);
  const [addedId, setAddedId] = useState(null);
  const [error, setError] = useState("");
  const { isAuthenticated } = useAuth();
  const navigate = useNavigate();

  useEffect(() => {
    const fetchAllBooks = async () => {
      try {
        const res = await api.get("/books");
        setBooks(res.data);
      } catch (err) {
        console.log(err.message);
        setError("something went wrong, try again");
      }
    };
    fetchAllBooks();
  }, []);

  const handleDelete = async (id) => {
    // The gateway now requires a JWT for /books writes; a logged-out user
    // clicking this would just get a 401 (and the interceptor bounces them
    // to /login mid-action), so gate proactively instead -- same pattern as
    // handleAddToCart below.
    if (!isAuthenticated) {
      navigate("/login");
      return;
    }
    try {
      await api.delete(`/books/${id}`);
      window.location.reload();
    } catch (err) {
      console.log(err.message);
      setError("something went wrong, try again");
    }
  };

  const handleAddToCart = async (id) => {
    if (!isAuthenticated) {
      navigate("/login");
      return;
    }
    try {
      await api.post("/cart", { book_id: id, quantity: 1 });
      setAddedId(id);
      setTimeout(() => setAddedId(null), 1500);
    } catch (err) {
      console.log(err.message);
      setError("something went wrong, try again");
    }
  };

  return (
    <div>
      <h1>Mindcircuit book Store</h1>
      {error && <p className="error">{error}</p>}
      <div className="books">
        {books.map((book) => (
          <div key={book.id} className="book">
            <img src={book.cover} alt="" />
            <h2>{book.title}</h2>
            <p>{book.desc}</p>
            <span>${book.price}</span>
            <button className="addToCart" onClick={() => handleAddToCart(book.id)}>
              {addedId === book.id ? "Added!" : "Add to Cart"}
            </button>
            {isAuthenticated && (
              <>
                <button className="delete" onClick={() => handleDelete(book.id)}>
                  Delete
                </button>
                <button className="update">
                  <Link to={`/update/${book.id}`} style={{ color: "inherit", textDecoration: "none" }}>
                    Update
                  </Link>
                </button>
              </>
            )}
          </div>
        ))}
      </div>

      {isAuthenticated && (
        <button className="addHome">
          <Link to="/add" style={{ color: "inherit", textDecoration: "none" }}>
            Add new book
          </Link>
        </button>
      )}
    </div>
  );
};

export default Books;
