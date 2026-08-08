import { render, screen } from "@testing-library/react";
import App from "./App";

test("renders the bookstore heading on the home route", () => {
  render(<App />);
  const heading = screen.getByRole("heading", {
    name: /Mindcircuit book Store/i,
  });
  expect(heading).toBeInTheDocument();
});
