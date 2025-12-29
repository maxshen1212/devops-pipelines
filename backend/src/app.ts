import express from "express";
import cors from "cors";
import healthRouter from "./routes/health.route";

const app = express();

app.use(cors());
app.use(express.json());

app.get("/", (_req, res) => {
  res.send("Hello Express!");
});
app.use("/health", healthRouter);

export default app;
