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
  const { isAuthenticated, isAdmin } = useAuth();
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
    // The gateway now requires the admin role for /books writes; a
    // non-admin clicking this would just get a 403, so gate proactively
    // instead -- same pattern as handleAddToCart below.
    if (!isAdmin) {
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
      {books.length === 0 && !error && <p>No books in the catalog yet.</p>}
      <div className="books">
        {books.map((book) => (
          <div key={book.id} className="book">
            <img src={book.cover} alt={book.title || "Book cover"} />
            <h2>{book.title}</h2>
            <p>{book.desc}</p>
            <span>${book.price}</span>
            <button className="addToCart" aria-live="polite" onClick={() => handleAddToCart(book.id)}>
              {addedId === book.id ? "Added!" : "Add to Cart"}
            </button>
            {isAdmin && (
              <>
                <button className="delete" onClick={() => handleDelete(book.id)}>
                  Delete
                </button>
                <Link className="update" to={`/update/${book.id}`} style={{ textDecoration: "none" }}>
                  Update
                </Link>
              </>
            )}
          </div>
        ))}
      </div>

      {isAuthenticated && (
        <Link className="addHome" to="/add" style={{ textDecoration: "none" }}>
          Add new book
        </Link>
      )}
    </div>
  );
};

export default Books;
