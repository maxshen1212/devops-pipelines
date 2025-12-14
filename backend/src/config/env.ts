import dotenv from "dotenv";

dotenv.config();

const toNumber = (value: string | undefined, fallback: number) => {
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : fallback;
};

export const env = {
  port: toNumber(process.env.PORT, 3000),
  nodeEnv: process.env.NODE_ENV || "development",
  db: {
    host: process.env.DB_HOST || "mysql",
    port: toNumber(process.env.DB_PORT, 3306),
    user: process.env.DB_USER || "app_user",
    password: process.env.DB_PASSWORD || "app_password",
    name: process.env.DB_NAME || "app_db",
  },
};
