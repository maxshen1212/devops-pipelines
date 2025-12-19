import { useEffect, useState } from "react";
import { apiFetchText } from "../api/client";

type HealthStatus = "ok" | "error" | "unknown" | "loading";

export function useHealthCheck() {
  const [status, setStatus] = useState<HealthStatus>("loading");

  useEffect(() => {
    let isMounted = true;

    apiFetchText("/health")
      .then((text) => {
        if (isMounted) {
          setStatus(text === "ok" ? "ok" : "unknown");
        }
      })
      .catch(() => {
        if (isMounted) {
          setStatus("error");
        }
      });

    return () => {
      isMounted = false;
    };
  }, []);

  return { status };
}

