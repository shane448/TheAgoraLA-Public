import { readFile } from "node:fs/promises";
import { Environment, SignedDataVerifier } from "@apple/app-store-server-library";
import type { AppConfig } from "./config.js";

export interface VerifiedPurchase {
  transactionID: string;
  originalTransactionID?: string;
  productID: string;
  environment: string;
  appAccountToken?: string;
  purchaseDate?: Date;
  rawPayload: Record<string, unknown>;
}

export interface VerifiedAppleNotification {
  notificationType: string;
  notificationUUID?: string;
  transactionID?: string;
  productID?: string;
}

export async function verifyApplePurchase(jws: string, config: AppConfig): Promise<VerifiedPurchase> {
  const verifiers = await createVerifiers(config);
  let payload: Awaited<ReturnType<SignedDataVerifier["verifyAndDecodeTransaction"]>> | undefined;
  let verificationError: unknown;
  for (const verifier of verifiers) {
    try {
      payload = await verifier.verifyAndDecodeTransaction(jws);
      break;
    } catch (error) {
      verificationError = error;
    }
  }
  if (!payload) throw verificationError ?? new Error("Apple could not verify this transaction.");
  if (!payload.transactionId || !payload.productId) {
    throw new Error("Apple returned an incomplete transaction.");
  }
  if (payload.revocationDate != null) {
    throw new Error("This purchase was revoked by Apple.");
  }
  return {
    transactionID: payload.transactionId,
    ...(payload.originalTransactionId ? { originalTransactionID: payload.originalTransactionId } : {}),
    productID: payload.productId,
    environment: String(payload.environment ?? config.appleEnvironment),
    ...(payload.appAccountToken ? { appAccountToken: payload.appAccountToken } : {}),
    ...(payload.purchaseDate ? { purchaseDate: new Date(payload.purchaseDate) } : {}),
    rawPayload: JSON.parse(JSON.stringify(payload)) as Record<string, unknown>,
  };
}

export async function verifyAppleNotification(
  signedPayload: string,
  config: AppConfig,
): Promise<VerifiedAppleNotification> {
  let verificationError: unknown;
  for (const verifier of await createVerifiers(config)) {
    try {
      const notification = await verifier.verifyAndDecodeNotification(signedPayload);
      const signedTransaction = notification.data?.signedTransactionInfo;
      const transaction = signedTransaction
        ? await verifier.verifyAndDecodeTransaction(signedTransaction)
        : undefined;
      return {
        notificationType: String(notification.notificationType ?? "UNKNOWN"),
        ...(notification.notificationUUID ? { notificationUUID: notification.notificationUUID } : {}),
        ...(transaction?.transactionId ? { transactionID: transaction.transactionId } : {}),
        ...(transaction?.productId ? { productID: transaction.productId } : {}),
      };
    } catch (error) {
      verificationError = error;
    }
  }
  throw verificationError ?? new Error("Apple could not verify this notification.");
}

async function createVerifiers(config: AppConfig): Promise<SignedDataVerifier[]> {
  if (config.appleRootCAPaths.length === 0) {
    throw new Error("Apple root certificates are not configured on the server.");
  }
  const roots = await Promise.all(config.appleRootCAPaths.map((path) => readFile(path)));
  const environments = config.appleEnvironment === "Production"
    ? [Environment.PRODUCTION, Environment.SANDBOX]
    : [Environment.SANDBOX];
  return environments.map((environment) => new SignedDataVerifier(
      roots,
      true,
      environment,
      config.appleBundleID,
      environment === Environment.PRODUCTION ? config.appleAppID : undefined,
    ));
}
