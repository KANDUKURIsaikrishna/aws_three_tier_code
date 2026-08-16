import { Navigate } from "react-router-dom";
import { useAuth } from "../context/AuthContext";

// Stricter than ProtectedRoute: catalog-mutating pages (Add/Update) require
// the admin role, not just being logged in -- api-gateway enforces the same
// boundary server-side (requireAdminForMutation), this just avoids sending a
// non-admin, logged-in user to a page that would only 403 on submit.
const AdminRoute = ({ children }) => {
  const { isAuthenticated, isAdmin } = useAuth();
  if (!isAuthenticated) {
    return <Navigate to="/login" replace />;
  }
  if (!isAdmin) {
    return <Navigate to="/" replace />;
  }
  return children;
};

export default AdminRoute;
