import { useState } from "react";
import { useNavigate, Link } from "react-router-dom";
import { useAuth } from "../context/AuthContext";

const Register = () => {
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [error, setError] = useState("");
  const [submitting, setSubmitting] = useState(false);
  const { register } = useAuth();
  const navigate = useNavigate();

  const handleSubmit = async (e) => {
    e.preventDefault();
    setError("");
    setSubmitting(true);
    try {
      await register(email, password);
      navigate("/login", { state: { registered: true } });
    } catch (err) {
      if (err.response && err.response.status === 409) {
        setError("email already registered");
      } else if (err.response && err.response.status === 400) {
        setError("email and password are required");
      } else {
        setError("something went wrong, try again");
      }
      setSubmitting(false);
    }
  };

  return (
    <div className="form">
      <h1>Register</h1>
      <input
        type="email"
        placeholder="Email"
        value={email}
        onChange={(e) => setEmail(e.target.value)}
      />
      <input
        type="password"
        placeholder="Password"
        value={password}
        onChange={(e) => setPassword(e.target.value)}
      />
      <button onClick={handleSubmit} disabled={submitting}>
        {submitting ? "Registering..." : "Register"}
      </button>
      {error && <p className="error">{error}</p>}
      <Link to="/login">Already have an account? Login</Link>
    </div>
  );
};

export default Register;
