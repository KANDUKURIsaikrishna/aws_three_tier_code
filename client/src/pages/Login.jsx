import { useState } from "react";
import { useNavigate, useLocation, Link } from "react-router-dom";
import { useAuth } from "../context/AuthContext";

const Login = () => {
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [error, setError] = useState("");
  const [submitting, setSubmitting] = useState(false);
  const { login } = useAuth();
  const navigate = useNavigate();
  const location = useLocation();
  const justRegistered = Boolean(location.state && location.state.registered);

  const handleSubmit = async (e) => {
    e.preventDefault();
    setError("");
    setSubmitting(true);
    try {
      await login(email, password);
      navigate("/");
    } catch (err) {
      if (err.response && err.response.status === 401) {
        setError("invalid email or password");
      } else {
        setError("something went wrong, try again");
      }
      setSubmitting(false);
    }
  };

  return (
    <div className="form">
      <h1>Login</h1>
      {justRegistered && <p className="success">registered — please log in</p>}
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
        {submitting ? "Logging in..." : "Login"}
      </button>
      {error && <p className="error">{error}</p>}
      <Link to="/register">Need an account? Register</Link>
    </div>
  );
};

export default Login;
