import pg from "pg";
import type { AppConfig } from "./config.js";

const { Pool } = pg;

export type Database = pg.Pool;

export function createDatabase(config: AppConfig): Database {
  const ssl = config.databaseSSLMode === "disable"
    ? undefined
    : { rejectUnauthorized: config.databaseSSLMode === "verify-full" };
  return new Pool({
    connectionString: config.databaseURL,
    max: 12,
    idleTimeoutMillis: 30_000,
    connectionTimeoutMillis: 10_000,
    ssl,
  });
}

export async function withTransaction<T>(database: Database, work: (client: pg.PoolClient) => Promise<T>): Promise<T> {
  const client = await database.connect();
  try {
    await client.query("BEGIN");
    const result = await work(client);
    await client.query("COMMIT");
    return result;
  } catch (error) {
    await client.query("ROLLBACK");
    throw error;
  } finally {
    client.release();
  }
}

export async function creditBalance(database: Database, userID: string): Promise<number> {
  const result = await database.query<{ balance: string }>(
    "SELECT COALESCE(SUM(delta), 0)::text AS balance FROM credit_ledger WHERE user_id = $1",
    [userID],
  );
  return Number(result.rows[0]?.balance ?? 0);
}
