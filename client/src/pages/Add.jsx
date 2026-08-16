import React from "react";
import { useState } from "react";
import { Link, useNavigate } from "react-router-dom";
import api from "../api/api";

const Add = () => {
  const [book, setBook] = useState({
    title: "",
    desc: "",
    price: null,
    cover: "",
  });
  const [error,setError] = useState(false)
  const [submitting, setSubmitting] = useState(false);

  const navigate = useNavigate();

  const handleChange = (e) => {
    setBook((prev) => ({ ...prev, [e.target.name]: e.target.value }));
  };

  const handleClick = async (e) => {
    e.preventDefault();
    setSubmitting(true);
    try {
      await api.post("/books", book);
      navigate("/");
    } catch (err) {
      console.log(err.message);
      setError(true)
      setSubmitting(false);
    }
  };

  return (
    <div className="form">
      <h1>Add New Book</h1>
      <input
        type="text"
        placeholder="Book title"
        name="title"
        onChange={handleChange}
      />
      <textarea
        rows={5}
        type="text"
        placeholder="Book desc"
        name="desc"
        onChange={handleChange}
      />
      <input
        type="number"
        placeholder="Book price"
        name="price"
        onChange={handleChange}
      />
      <input
        type="text"
        placeholder="Book cover"
        name="cover"
        onChange={handleChange}
      />
      <button onClick={handleClick} disabled={submitting}>
        {submitting ? "Adding..." : "Add"}
      </button>
      {error && <p className="error">Something went wrong!</p>}
      <Link to="/">See all books</Link>
    </div>
  );
};

export default Add;
