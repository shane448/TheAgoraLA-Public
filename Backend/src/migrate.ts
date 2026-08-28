import { readFile, readdir } from "node:fs/promises";
import { loadConfig } from "./config.js";
import { createDatabase } from "./database.js";

const config = loadConfig();
const database = createDatabase(config);
const migrationDirectory = new URL("../migrations/", import.meta.url);

try {
  const migrations = (await readdir(migrationDirectory)).filter((name) => name.endsWith(".sql")).sort();
  for (const migration of migrations) {
    await database.query(await readFile(new URL(migration, migrationDirectory), "utf8"));
  }
  console.log("Database migration complete.");
} finally {
  await database.end();
}
