import { useEffect, useState } from "react";
import { apiFetch } from "../api/client";

export default function Home() {
  const [status, setStatus] = useState("");

  useEffect(() => {
    // Check simple health endpoint
    fetch(`${import.meta.env.VITE_API_BASE_URL}/health`)
      .then((res) => res.text())
      .then((text) => {
        if (text === "ok") {
          setStatus("ok");
        } else {
          setStatus("unknown");
        }
      })
      .catch(() => setStatus("error"));
  }, []);

  return <h1>Backend status: {status}</h1>;
}
