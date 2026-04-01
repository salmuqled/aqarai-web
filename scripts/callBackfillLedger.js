/**
 * استدعاء Callable: backfillLedgerForOldInvoices (يتطلب مستخدمًا بـ admin claim).
 *
 * يستخدم Admin SDK لإنشاء custom token مع { admin: true } ثم signInWithCustomToken
 * للحصول على ID token واستدعاء HTTPS callable.
 *
 * المتغيرات:
 *   FIREBASE_UID — UID مستخدم موجود في Firebase Auth (مطلوب)
 *   SERVICE_ACCOUNT_JSON — اختياري، مسار مفتاح الخدمة (افتراضي: serviceAccountKey.json)
 *   FIREBASE_WEB_API_KEY — اختياري (افتراضي: مفتاح Web من المشروع)
 *   FUNCTION_BASE — اختياري، مثال: https://us-central1-aqarai-caf5d.cloudfunctions.net
 *
 * الاستخدام:
 *   cd scripts && npm install
 *   export FIREBASE_UID="..."
 *   node callBackfillLedger.js --dry-run
 *   node callBackfillLedger.js --execute
 *
 * تمرير إضافي للدالة (JSON):
 *   node callBackfillLedger.js --dry-run --data '{"maxBatches":2}'
 */

const admin = require("firebase-admin");
const path = require("path");
const fs = require("fs");

const DEFAULT_WEB_API_KEY = "AIzaSyBIcHmRZlVZyfGlhlYKPUxuNo4jb9876gc";
const PROJECT_ID = "aqarai-caf5d";
const REGION = "us-central1";
const FUNCTION_NAME = "backfillLedgerForOldInvoices";

function resolveServiceAccountPath() {
  const fromEnv = process.env.SERVICE_ACCOUNT_JSON;
  if (fromEnv && fs.existsSync(fromEnv)) return path.resolve(fromEnv);

  const exact = path.join(__dirname, "serviceAccountKey.json");
  if (fs.existsSync(exact)) return exact;

  let entries = [];
  try {
    entries = fs.readdirSync(__dirname);
  } catch (_) {
    entries = [];
  }
  const adminSdk = entries.filter(
    (n) =>
      n.endsWith(".json") &&
      n.includes("firebase-adminsdk") &&
      !n.includes("package")
  );
  if (adminSdk.length === 1) return path.join(__dirname, adminSdk[0]);
  if (adminSdk.length > 1) {
    console.error("Multiple firebase-adminsdk json files in scripts/");
    process.exit(1);
  }
  console.error("Missing service account key (serviceAccountKey.json or SERVICE_ACCOUNT_JSON)");
  process.exit(1);
}

function parseArgs() {
  const argv = process.argv.slice(2);
  let dryRun = true;
  let dataExtra = {};
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === "--execute") dryRun = false;
    if (argv[i] === "--dry-run") dryRun = true;
    if (argv[i] === "--data" && argv[i + 1]) {
      try {
        dataExtra = JSON.parse(argv[i + 1]);
        i++;
      } catch (e) {
        console.error("Invalid --data JSON:", e.message);
        process.exit(1);
      }
    }
  }
  return { dryRun, dataExtra };
}

async function signInWithCustomToken(customToken, apiKey) {
  const url = `https://identitytoolkit.googleapis.com/v1/accounts:signInWithCustomToken?key=${encodeURIComponent(apiKey)}`;
  const res = await fetch(url, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      token: customToken,
      returnSecureToken: true,
    }),
  });
  const body = await res.json();
  if (!res.ok) {
    throw new Error(`signInWithCustomToken failed: ${JSON.stringify(body)}`);
  }
  return body.idToken;
}

async function callCallable(idToken, baseUrl, data) {
  const url = `${baseUrl.replace(/\/$/, "")}/${FUNCTION_NAME}`;
  const res = await fetch(url, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${idToken}`,
    },
    body: JSON.stringify({ data }),
  });
  const text = await res.text();
  let json;
  try {
    json = JSON.parse(text);
  } catch {
    throw new Error(`Non-JSON response (${res.status}): ${text.slice(0, 500)}`);
  }
  if (!res.ok) {
    throw new Error(`Callable HTTP ${res.status}: ${JSON.stringify(json)}`);
  }
  if (json.error) {
    throw new Error(`Callable error: ${JSON.stringify(json.error)}`);
  }
  return json.result !== undefined ? json.result : json;
}

async function main() {
  const { dryRun, dataExtra } = parseArgs();
  const uid = (process.env.FIREBASE_UID || "").trim();
  if (!uid) {
    console.error("Set FIREBASE_UID to a Firebase Auth user UID.");
    process.exit(1);
  }

  const keyPath = resolveServiceAccountPath();
  const serviceAccount = require(keyPath);
  if (!admin.apps.length) {
    admin.initializeApp({
      credential: admin.credential.cert(serviceAccount),
      projectId: serviceAccount.project_id || PROJECT_ID,
    });
  }

  const apiKey = process.env.FIREBASE_WEB_API_KEY || DEFAULT_WEB_API_KEY;
  const base =
    process.env.FUNCTION_BASE ||
    `https://${REGION}-${PROJECT_ID}.cloudfunctions.net`;

  const customToken = await admin.auth().createCustomToken(uid, { admin: true });
  const idToken = await signInWithCustomToken(customToken, apiKey);

  const payload = { dryRun, ...dataExtra };
  console.log("Calling", FUNCTION_NAME, "with:", JSON.stringify(payload));
  const result = await callCallable(idToken, base, payload);
  console.log("Result:", JSON.stringify(result, null, 2));
  return result;
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
