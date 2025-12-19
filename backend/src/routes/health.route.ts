import { Router } from "express";
import { verifyDbConnection } from "../config/db";

const router = Router();

// Simple health check for ALB (no external dependencies)
router.get("/", (_req, res) => {
  res.status(200).send("ok");
});

// Database health check endpoint
router.get("/db", async (_req, res) => {
  try {
    await verifyDbConnection();
    res.json({ status: "ok", db: "connected" });
  } catch (error) {
    console.error("Database health check failed", error);
    res.status(500).json({ status: "error", error: "Database unreachable" });
  }
});

export default router;
