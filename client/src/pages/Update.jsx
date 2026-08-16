import React, { useState, useEffect } from "react";
import { Link, useLocation, useNavigate } from "react-router-dom";
import api from "../api/api";

const Update = () => {
  const [book, setBook] = useState({
    title: "",
    desc: "",
    price: null,
    cover: "",
  });
  const [error, setError] = useState(false);
  const [loading, setLoading] = useState(true);
  const [submitting, setSubmitting] = useState(false);

  const location = useLocation();
  const navigate = useNavigate();

  const bookId = location.pathname.split("/")[2];

  useEffect(() => {
    let cancelled = false;
    api
      .get(`/books/${bookId}`)
      .then((res) => {
        if (!cancelled) setBook(res.data);
      })
      .catch((err) => {
        console.log(err.message);
        if (!cancelled) setError(true);
      })
      .finally(() => {
        if (!cancelled) setLoading(false);
      });
    return () => {
      cancelled = true;
    };
  }, [bookId]);

  const handleChange = (e) => {
    setBook((prev) => ({ ...prev, [e.target.name]: e.target.value }));
  };

  const handleClick = async (e) => {
    e.preventDefault();
    setSubmitting(true);
    try {
      await api.put(`/books/${bookId}`, book);
      navigate("/");
    } catch (err) {
      console.log(err.message);
      setError(true);
      setSubmitting(false);
    }
  };

  if (loading) {
    return (
      <div className="form">
        <h1>Update the Book</h1>
        <p>Loading...</p>
      </div>
    );
  }

  return (
    <div className="form">
      <h1>Update the Book</h1>
      <input
        type="text"
        placeholder="Book title"
        name="title"
        value={book.title ?? ""}
        onChange={handleChange}
      />
      <textarea
        rows={5}
        type="text"
        placeholder="Book desc"
        name="desc"
        value={book.desc ?? ""}
        onChange={handleChange}
      />
      <input
        type="number"
        placeholder="Book price"
        name="price"
        value={book.price ?? ""}
        onChange={handleChange}
      />
      <input
        type="text"
        placeholder="Book cover"
        name="cover"
        value={book.cover ?? ""}
        onChange={handleChange}
      />
      <button onClick={handleClick} disabled={submitting}>
        {submitting ? "Updating..." : "Update"}
      </button>
      {error && <p className="error">Something went wrong!</p>}
      <Link to="/">See all books</Link>
    </div>
  );
};

export default Update;
