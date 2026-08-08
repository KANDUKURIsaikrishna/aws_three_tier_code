import React from "react";
import { useEffect } from "react";
import { useState } from "react";
import { Link, useNavigate } from "react-router-dom";
import api from "../api/api";
import { useAuth } from "../context/AuthContext";

const Books = () => {
  const [books, setBooks] = useState([]);
  const [addedId, setAddedId] = useState(null);
  const { isAuthenticated } = useAuth();
  const navigate = useNavigate();

  useEffect(() => {
    const fetchAllBooks = async () => {
      try {
        const res = await api.get("/books");
        setBooks(res.data);
      } catch (err) {
        console.log(err);
      }
    };
    fetchAllBooks();
  }, []);

  const handleDelete = async (id) => {
    try {
      await api.delete(`/books/${id}`);
      window.location.reload();
    } catch (err) {
      console.log(err);
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
      console.log(err);
    }
  };

  return (
    <div>
      <h1>Mindcircuit book Store</h1>
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
            <button className="delete" onClick={() => handleDelete(book.id)}>
              Delete
            </button>
            <button className="update">
              <Link to={`/update/${book.id}`} style={{ color: "inherit", textDecoration: "none" }}>
                Update
              </Link>
            </button>
          </div>
        ))}
      </div>

      <button className="addHome">
        <Link to="/add" style={{ color: "inherit", textDecoration: "none" }}>
          Add new book
        </Link>
      </button>
    </div>
  );
};

export default Books;
