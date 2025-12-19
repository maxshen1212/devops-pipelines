const VITE_API_BASE_URL = import.meta.env.VITE_API_BASE_URL;

/**
 * Base fetch function with common error handling
 */
async function baseFetch(
  path: string,
  options?: RequestInit
): Promise<Response> {
  const res = await fetch(`${VITE_API_BASE_URL}${path}`, options);
  if (!res.ok) {
    throw new Error("API error");
  }
  return res;
}

/**
 * Fetch JSON response from API
 */
export async function apiFetch<T>(
  path: string,
  options?: RequestInit
): Promise<T> {
  const res = await baseFetch(path, {
    headers: { "Content-Type": "application/json" },
    ...options,
  });
  return res.json();
}

/**
 * Fetch text response from API (for endpoints like /health that return plain text)
 */
export async function apiFetchText(
  path: string,
  options?: RequestInit
): Promise<string> {
  const res = await baseFetch(path, options);
  return res.text();
}
