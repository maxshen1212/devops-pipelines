import { createPool } from "mysql2/promise";
import { env } from "./env";

export const dbPool = createPool({
  host: env.db.host,
  port: env.db.port,
  user: env.db.user,
  password: env.db.password,
  database: env.db.name,
  waitForConnections: true,
  connectionLimit: 10,
  queueLimit: 0,
});

export async function verifyDbConnection() {
  await dbPool.query("SELECT 1");
}
