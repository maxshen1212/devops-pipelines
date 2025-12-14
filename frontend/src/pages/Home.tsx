import { useEffect, useState } from "react";
import { apiFetch } from "../api/client";

export default function Home() {
  const [status, setStatus] = useState("");

  useEffect(() => {
    apiFetch<{ db: string }>("/health").then((res) => {
      setStatus(res.db);
    });
  }, []);

  return <h1>Backend status: {status}</h1>;
}
