import { render, screen } from "@testing-library/react";
import App from "./App";

test("renders the bookstore heading on the home route", () => {
  render(<App />);
  const heading = screen.getByText(/Mindcircuit book Store/i);
  expect(heading).toBeInTheDocument();
});
