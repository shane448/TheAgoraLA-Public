import { loadConfig } from "./config.js";
import { createDatabase } from "./database.js";
import { AgoraOpenAI } from "./openAIClient.js";
import { buildApp } from "./app.js";
import { startAnalysisWorker } from "./worker.js";

const config = loadConfig();
const database = createDatabase(config);
const openAI = new AgoraOpenAI(config);
const app = buildApp({ config, database, openAI });
const stopWorker = startAnalysisWorker(database, config);

const shutdown = async () => {
  await stopWorker();
  await app.close();
  await database.end();
};

process.on("SIGINT", () => void shutdown().finally(() => process.exit(0)));
process.on("SIGTERM", () => void shutdown().finally(() => process.exit(0)));

await app.listen({ port: config.port, host: "0.0.0.0" });
