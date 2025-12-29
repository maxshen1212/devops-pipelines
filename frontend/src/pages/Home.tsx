import { useHealthCheck } from "../hooks/useHealthCheck";

export default function Home() {
  const { status } = useHealthCheck();

  return (
    <h1>
      Backend status: {status} at {new Date().toISOString()}
    </h1>
  );
}
